@testable import FluidVoice_Debug
import Foundation
import XCTest

final class InstalledFluidIntelligenceRunnerTests: XCTestCase {
    private var helperDirectories: [URL] = []

    override func tearDown() {
        for directory in self.helperDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        self.helperDirectories.removeAll()
        super.tearDown()
    }

    func testInferenceIsDisabledByDefault() async throws {
        let helper = try self.makeHelper(statusJSON: "{\"state\":\"ready\"}")
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: helper)
        )

        do {
            _ = try await runner.serveJSON(Data(#"{"text":"hello"}"#.utf8))
            XCTFail("Inference should be opt-in")
        } catch let error as InstalledFluidIntelligenceRunner.RunnerError {
            XCTAssertEqual(error, .inferenceDisabled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStatusReturnsInstalledHelperJSON() async throws {
        let helper = try self.makeHelper(statusJSON: "{\"state\":\"ready\",\"version\":\"1\"}")
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: helper)
        )

        let data = try await runner.status()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["state"], "ready")
        XCTAssertEqual(object["version"], "1")
    }

    func testStatusAcceptsInstalledHelperKeyValueOutput() async throws {
        let helper = try self.makeHelper(statusJSON: "state=configured\nbackend=mlxSwift\n")
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: helper)
        )

        let data = try await runner.status()
        let statusText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(statusText, "state=configured\nbackend=mlxSwift\n")
    }

    func testMissingHelperIsReportedWithoutLaunchingAnything() async {
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: URL(fileURLWithPath: "/definitely/missing/fluid-intelligence"))
        )

        do {
            _ = try await runner.status()
            XCTFail("A missing helper should fail cleanly")
        } catch let error as InstalledFluidIntelligenceRunner.RunnerError {
            XCTAssertEqual(error, .helperNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testServeJSONRoundTripsValidJSONWhenExplicitlyEnabled() async throws {
        let helper = try self.makeHelper(statusJSON: "{\"state\":\"ready\"}")
        let drafterDirectory = helper.deletingLastPathComponent().appendingPathComponent("drafter", isDirectory: true)
        try FileManager.default.createDirectory(at: drafterDirectory, withIntermediateDirectories: true)
        let modelDirectory = helper.deletingLastPathComponent().appendingPathComponent("model", isDirectory: true)
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(
                helperURL: helper,
                modelDirectoryURL: modelDirectory,
                mtpDrafterDirectoryURL: drafterDirectory,
                draftBlockSize: 6,
                allowsInference: true
            )
        )
        let request = Data(#"{"text":"こんにちは"}"#.utf8)

        let response = try await runner.serveJSON(request)
        XCTAssertEqual(response, request)
    }

    func testServeJSONRejectsInvalidRequest() async throws {
        let helper = try self.makeHelper(statusJSON: "{\"state\":\"ready\"}")
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: helper, allowsInference: true)
        )

        do {
            _ = try await runner.serveJSON(Data("not-json".utf8))
            XCTFail("Invalid request should not reach the helper")
        } catch let error as InstalledFluidIntelligenceRunner.RunnerError {
            XCTAssertEqual(error, .invalidRequestJSON)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidJSONResponseFailsWithoutCrashingTheCaller() async throws {
        let helper = try self.makeHelper(statusJSON: "not-json")
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: helper)
        )

        do {
            _ = try await runner.status()
            XCTFail("Invalid JSON should fail")
        } catch let error as InstalledFluidIntelligenceRunner.RunnerError {
            XCTAssertEqual(error, .invalidResponseJSON)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWatchdogReturnsTimeout() async throws {
        let helper = try self.makeHelper(statusJSON: "{\"state\":\"ready\"}", statusBody: "sleep 5")
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: helper, timeout: 0.1)
        )

        do {
            _ = try await runner.status()
            XCTFail("A hanging helper should be stopped by the watchdog")
        } catch let error as InstalledFluidIntelligenceRunner.RunnerError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected runner error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNonZeroExitIsReturnedAsFailure() async throws {
        let helper = try self.makeHelper(statusJSON: "{\"state\":\"ready\"}", statusBody: "exit 23")
        let runner = InstalledFluidIntelligenceRunner(
            configuration: .init(helperURL: helper)
        )

        do {
            _ = try await runner.status()
            XCTFail("A failing helper should not produce a successful response")
        } catch let error as InstalledFluidIntelligenceRunner.RunnerError {
            guard case let .nonZeroExit(status, _) = error else {
                return XCTFail("Unexpected runner error: \(error)")
            }
            XCTAssertEqual(status, 23)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeHelper(statusJSON: String, statusBody: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-fi-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.helperDirectories.append(directory)

        let script = directory.appendingPathComponent("helper.sh")
        let statusCommand = statusBody ?? "printf '%s' '\(statusJSON)'"
        let contents = """
        #!/bin/sh
        case "$1" in
        status)
            \(statusCommand)
            ;;
        --serve-json)
            if [ "$2" != "--model-dir" ] || [ "$4" != "--local-only" ]; then
                exit 41
            fi
            if [ -n "$5" ] && { [ "$5" != "--mtp-drafter-dir" ] || [ "$7" != "--draft-block-size" ] || [ "$8" != "6" ]; }; then
                exit 42
            fi
            cat
            ;;
        esac
        """
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: script.path
        )
        return script
    }
}
