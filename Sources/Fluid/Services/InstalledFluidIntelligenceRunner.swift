import Darwin
import Foundation

/// A deliberately small adapter for experimenting with the Fluid Intelligence
/// helper shipped inside an installed FluidVoice.app.
///
/// The helper is never copied into this app or repository. Each invocation is a
/// short-lived child process so a broken private runtime can only fail a request,
/// not take down FluidVoice Live. Inference is opt-in because this API is an
/// interoperability spike, not part of the default dictation path.
nonisolated struct InstalledFluidIntelligenceRunner {
    nonisolated struct Configuration {
        var installedAppURL: URL
        var helperURL: URL?
        var modelDirectoryURL: URL
        var mtpDrafterDirectoryURL: URL?
        var draftBlockSize: Int
        var timeout: TimeInterval
        var allowsInference: Bool

        init(
            installedAppURL: URL = URL(fileURLWithPath: "/Applications/FluidVoice.app"),
            helperURL: URL? = nil,
            modelDirectoryURL: URL = Configuration.defaultModelDirectoryURL,
            mtpDrafterDirectoryURL: URL? = Configuration.defaultMTPDrafterDirectoryURL,
            draftBlockSize: Int = 6,
            timeout: TimeInterval = 3,
            allowsInference: Bool = false
        ) {
            self.installedAppURL = installedAppURL
            self.helperURL = helperURL
            self.modelDirectoryURL = modelDirectoryURL
            self.mtpDrafterDirectoryURL = mtpDrafterDirectoryURL
            self.draftBlockSize = draftBlockSize
            self.timeout = max(0.1, timeout)
            self.allowsInference = allowsInference
        }

        static var defaultModelDirectoryURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidIntelligence/Models/fluid-1-nvfp4-mlx", isDirectory: true)
        }

        static var defaultMTPDrafterDirectoryURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidIntelligence/Models/gemma-4-E2B-it-qat-assistant-bf16-mlx-mtp", isDirectory: true)
        }
    }

    nonisolated enum Command: String {
        case status
        case serveJSON = "serve-json"
    }

    nonisolated enum RunnerError: Error, LocalizedError, Equatable {
        case helperNotFound
        case invalidTimeout
        case inferenceDisabled
        case invalidRequestJSON
        case invalidResponseJSON
        case launchFailed(String)
        case timedOut(TimeInterval)
        case crashed(signal: Int32)
        case nonZeroExit(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .helperNotFound:
                return "The installed Fluid Intelligence helper could not be found."
            case .invalidTimeout:
                return "The Fluid Intelligence helper timeout is invalid."
            case .inferenceDisabled:
                return "Fluid Intelligence inference is disabled for this build."
            case .invalidRequestJSON:
                return "The Fluid Intelligence request is not valid JSON."
            case .invalidResponseJSON:
                return "The Fluid Intelligence helper returned invalid JSON."
            case let .launchFailed(message):
                return "Could not launch the Fluid Intelligence helper: \(message)"
            case let .timedOut(timeout):
                return "The Fluid Intelligence helper timed out after \(timeout)s."
            case let .crashed(signal):
                return "The Fluid Intelligence helper terminated with signal \(signal)."
            case let .nonZeroExit(status, stderr):
                let detail = stderr.isEmpty ? "" : " \(stderr)"
                return "The Fluid Intelligence helper exited with status \(status).\(detail)"
            }
        }
    }

    let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns the helper's status document without enabling inference. The
    /// installed helper currently emits newline-delimited `key=value` fields;
    /// older builds may emit a JSON object, so both formats are accepted.
    func status() async throws -> Data {
        let response = try await self.execute(.status)
        guard Self.isJSON(response) || Self.isKeyValueStatus(response) else {
            throw RunnerError.invalidResponseJSON
        }
        return response
    }

    /// Sends one JSON request to the private helper's `serve-json` command.
    ///
    /// The default configuration rejects this method. Pass
    /// `allowsInference: true` explicitly for a local experiment.
    func serveJSON(_ request: Data) async throws -> Data {
        guard self.configuration.allowsInference else {
            throw RunnerError.inferenceDisabled
        }
        guard Self.isJSON(request) else {
            throw RunnerError.invalidRequestJSON
        }

        let response = try await self.execute(.serveJSON, input: request)
        guard Self.isJSON(response) else {
            throw RunnerError.invalidResponseJSON
        }
        return response
    }

    /// Low-level command hook for experiments and deterministic integration tests.
    /// `serve-json` still requires `allowsInference` and JSON input through the
    /// higher-level API; status is always safe to call.
    func run(_ command: Command, input: Data? = nil) async throws -> Data {
        if command == .serveJSON {
            guard self.configuration.allowsInference else {
                throw RunnerError.inferenceDisabled
            }
            guard let input, Self.isJSON(input) else {
                throw RunnerError.invalidRequestJSON
            }
        }
        return try await self.execute(command, input: input)
    }

    private func execute(_ command: Command, input: Data? = nil) async throws -> Data {
        guard self.configuration.timeout.isFinite, self.configuration.timeout > 0 else {
            throw RunnerError.invalidTimeout
        }
        guard let executableURL = self.resolveHelperURL(),
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw RunnerError.helperNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = input == nil ? nil : Pipe()
            let completion = CompletionGate(continuation: continuation)

            process.executableURL = executableURL
            process.arguments = self.arguments(for: command)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe
            process.terminationHandler = { terminatedProcess in
                let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if terminatedProcess.terminationReason == .uncaughtSignal {
                    completion.finish(.failure(RunnerError.crashed(signal: terminatedProcess.terminationStatus)))
                } else if terminatedProcess.terminationStatus != 0 {
                    completion.finish(.failure(
                        RunnerError.nonZeroExit(
                            status: terminatedProcess.terminationStatus,
                            stderr: stderr
                        )
                    ))
                } else {
                    completion.finish(.success(output))
                }
            }

            do {
                try process.run()
            } catch {
                completion.finish(.failure(RunnerError.launchFailed(error.localizedDescription)))
                return
            }

            let processID = process.processIdentifier
            let ownsProcessGroup = setpgid(processID, processID) == 0
            let timeout = self.configuration.timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                if ownsProcessGroup {
                    kill(-processID, SIGTERM)
                } else {
                    process.terminate()
                }
                completion.finish(.failure(RunnerError.timedOut(timeout)))

                // A helper that ignores SIGTERM must not survive the watchdog.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                    guard process.isRunning else { return }
                    if ownsProcessGroup {
                        kill(-processID, SIGKILL)
                    } else {
                        kill(processID, SIGKILL)
                    }
                }
            }

            if let input, let stdinPipe {
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: input)
                    try stdinPipe.fileHandleForWriting.close()
                } catch {
                    if process.isRunning { process.terminate() }
                    completion.finish(.failure(RunnerError.launchFailed(error.localizedDescription)))
                    return
                }
            }
        }
    }

    private func resolveHelperURL() -> URL? {
        if let helperURL = self.configuration.helperURL {
            return helperURL
        }

        if let configuredPath = ProcessInfo.processInfo.environment["FLUIDVOICE_FI_HELPER_PATH"],
           !configuredPath.isEmpty
        {
            return URL(fileURLWithPath: configuredPath)
        }

        let relativeCandidates = [
            "Contents/Helpers/fluid-intelligence-mlx",
            "Contents/Helpers/FluidIntelligence",
            "Contents/Helpers/fluid-intelligence",
            "Contents/MacOS/FluidIntelligence",
            "Contents/MacOS/fluid-intelligence",
            "Contents/Resources/FluidIntelligence",
            "Contents/Resources/fluid-intelligence",
        ]
        return relativeCandidates
            .map { self.configuration.installedAppURL.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func arguments(for command: Command) -> [String] {
        switch command {
        case .status:
            return [command.rawValue]
        case .serveJSON:
            var arguments = ["--serve-json", "--model-dir", self.configuration.modelDirectoryURL.path, "--local-only"]
            if let drafterDirectory = self.configuration.mtpDrafterDirectoryURL,
               (try? drafterDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               self.configuration.draftBlockSize > 0
            {
                arguments.append(contentsOf: [
                    "--mtp-drafter-dir", drafterDirectory.path,
                    "--draft-block-size", String(self.configuration.draftBlockSize),
                ])
            }
            return arguments
        }
    }

    private static func isJSON(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func isKeyValueStatus(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.split(whereSeparator: { $0.isNewline })
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            return !parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Serializes the process termination and watchdog races before resuming the
/// async caller. Process callbacks are dispatched on implementation-defined
/// queues, hence the explicit lock and unchecked Sendable wrapper.
private final nonisolated class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let continuation: CheckedContinuation<Data, Error>

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Data, Error>) {
        self.lock.lock()
        guard !self.didFinish else {
            self.lock.unlock()
            return
        }
        self.didFinish = true
        self.lock.unlock()
        self.continuation.resume(with: result)
    }
}
