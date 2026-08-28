@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class InlineDictationCoordinatorTests: XCTestCase {
    func testApplyUsesUTF16OffsetsForEmojiAndJapaneseText() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "😀ab", selection: CFRange(location: 2, length: 0))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)

        let result = coordinator.apply(ASRPartialUpdate(
            sessionID: sessionID,
            sequence: 1,
            text: "日本",
            sampleCount: 16_000,
            scope: .cumulative
        ))

        XCTAssertEqual(result, .applied(provisionalText: "日本"))
        XCTAssertEqual(fake.value, "😀日本ab")
        self.assertRange(fake.selection, location: 4, length: 0)
    }

    func testApplyReplacesSelectedTextAndFinishReplacesOnlyProvisionalRange() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "prefix old suffix", selection: CFRange(location: 7, length: 3))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)

        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(sessionID: sessionID, sequence: 1, text: "暫定", sampleCount: 100, scope: .cumulative)),
            .applied(provisionalText: "暫定")
        )
        XCTAssertEqual(fake.value, "prefix 暫定 suffix")
        self.assertRange(fake.selection, location: 9, length: 0)

        XCTAssertEqual(coordinator.finish(finalText: "確定した文章"), .finished(finalText: "確定した文章"))
        XCTAssertEqual(fake.value, "prefix 確定した文章 suffix")
        self.assertRange(fake.selection, location: 13, length: 0)
        XCTAssertFalse(coordinator.isActive)
    }

    func testOldSequenceAndWrongSessionAreIgnoredWithoutMutation() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "", selection: CFRange(location: 0, length: 0))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)
        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(sessionID: sessionID, sequence: 2, text: "new", sampleCount: 20, scope: .cumulative)),
            .applied(provisionalText: "new")
        )
        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(sessionID: sessionID, sequence: 1, text: "old", sampleCount: 10, scope: .cumulative)),
            .ignoredStale
        )
        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(sessionID: UUID(), sequence: 3, text: "wrong", sampleCount: 30, scope: .cumulative)),
            .ignoredStale
        )
        XCTAssertEqual(fake.value, "new")
    }

    func testRollingWindowFreezesAtTwelveSecondsButFinishStillWorks() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "", selection: CFRange(location: 0, length: 0))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)
        let scope: StreamingHypothesisScope = .rollingWindow(maxSeconds: 12)

        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(
                sessionID: sessionID, sequence: 1, text: "途中", sampleCount: 191_999, scope: scope
            )),
            .applied(provisionalText: "途中")
        )
        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(
                sessionID: sessionID, sequence: 2, text: "凍結直前", sampleCount: 192_000, scope: scope
            )),
            .frozen
        )
        XCTAssertEqual(fake.value, "途中")
        XCTAssertEqual(coordinator.finish(finalText: "最終結果"), .finished(finalText: "最終結果"))
        XCTAssertEqual(fake.value, "最終結果")
    }

    func testValueChangeInterruptsAndDoesNotRestoreUserEdit() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "before", selection: CFRange(location: 6, length: 0))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)
        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(sessionID: sessionID, sequence: 1, text: " provisional", sampleCount: 10, scope: .cumulative)),
            .applied(provisionalText: " provisional")
        )

        fake.value = "before user edit"
        fake.selection = CFRange(location: (fake.value as NSString).length, length: 0)
        XCTAssertEqual(
            coordinator.finish(finalText: "final"),
            .interrupted(.valueChanged, finalText: "final")
        )
        XCTAssertEqual(fake.value, "before user edit")
    }

    func testCancelRestoresOriginalValueAndSelection() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "hello", selection: CFRange(location: 5, length: 0))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)
        _ = coordinator.apply(ASRPartialUpdate(sessionID: sessionID, sequence: 1, text: " world", sampleCount: 10, scope: .cumulative))

        XCTAssertEqual(coordinator.cancel(), .restored)
        XCTAssertEqual(fake.value, "hello")
        self.assertRange(fake.selection, location: 5, length: 0)
    }

    func testFailedCaretWriteSafelyRestoresPreviousState() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "hello", selection: CFRange(location: 5, length: 0))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)
        fake.failNextSelectionWrite = true

        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(sessionID: sessionID, sequence: 1, text: " world", sampleCount: 10, scope: .cumulative)),
            .interrupted(.writeFailed)
        )
        XCTAssertEqual(fake.value, "hello")
        self.assertRange(fake.selection, location: 5, length: 0)
    }

    func testValueWriteThatMutatesThenFailsSafelyRestoresPreviousState() throws {
        let fake = FakeInlineAccessibilityAdapter(value: "hello", selection: CFRange(location: 5, length: 0))
        let coordinator = InlineDictationCoordinator(adapter: fake)
        let sessionID = try self.start(coordinator)
        fake.mutateThenFailNextValueWrite = true

        XCTAssertEqual(
            coordinator.apply(ASRPartialUpdate(sessionID: sessionID, sequence: 1, text: " world", sampleCount: 10, scope: .cumulative)),
            .interrupted(.writeFailed)
        )
        XCTAssertEqual(fake.value, "hello")
        self.assertRange(fake.selection, location: 5, length: 0)
    }

    func testSecureFieldsAndTerminalsAreRejected() {
        let secure = FakeInlineAccessibilityAdapter(value: "", selection: CFRange(location: 0, length: 0), subrole: kAXSecureTextFieldSubrole as String)
        XCTAssertEqual(InlineDictationCoordinator(adapter: secure).begin(), .rejected(.secureTextField))

        let terminal = FakeInlineAccessibilityAdapter(value: "", selection: CFRange(location: 0, length: 0), bundleIdentifier: "com.mitchellh.ghostty")
        XCTAssertEqual(InlineDictationCoordinator(adapter: terminal).begin(), .rejected(.terminal))

        for bundleIdentifier in [
            "com.apple.Terminal",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "com.github.wez.WezTerm",
        ] {
            let terminal = FakeInlineAccessibilityAdapter(
                value: "",
                selection: CFRange(location: 0, length: 0),
                bundleIdentifier: bundleIdentifier
            )
            XCTAssertEqual(InlineDictationCoordinator(adapter: terminal).begin(), .rejected(.terminal))
        }

        let unknown = FakeInlineAccessibilityAdapter(
            value: "",
            selection: CFRange(location: 0, length: 0),
            bundleIdentifier: "com.example.UnknownEditor"
        )
        XCTAssertEqual(InlineDictationCoordinator(adapter: unknown).begin(), .rejected(.unsupportedTarget))
    }

    private func start(_ coordinator: InlineDictationCoordinator) throws -> UUID {
        guard case let .started(sessionID) = coordinator.begin() else {
            XCTFail("coordinator did not start")
            throw StartError.failed
        }
        return sessionID
    }

    private func assertRange(_ range: CFRange, location: Int, length: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(range.location, location, file: file, line: line)
        XCTAssertEqual(range.length, length, file: file, line: line)
    }

    private enum StartError: Error { case failed }
}

private final class FakeInlineAccessibilityAdapter: InlineAccessibilityAdapter {
    let target: InlineAccessibilityTarget
    var value: String
    var selection: CFRange
    var focused = true
    var supportsEditing = true
    var failNextSelectionWrite = false
    var mutateThenFailNextValueWrite = false

    init(
        value: String,
        selection: CFRange,
        bundleIdentifier: String? = "com.openai.codex",
        subrole: String? = nil
    ) {
        self.value = value
        self.selection = selection
        self.target = InlineAccessibilityTarget(
            processID: 123,
            bundleIdentifier: bundleIdentifier,
            role: "AXTextArea",
            subrole: subrole,
            element: InlineAXElementHandle(identifier: "fake-editor")
        )
    }

    func focusedTarget() -> InlineAccessibilityTarget? {
        self.focused ? self.target : nil
    }

    func supportsInlineEditing(_ target: InlineAccessibilityTarget) -> Bool {
        self.supportsEditing
    }

    func isFocused(_ target: InlineAccessibilityTarget) -> Bool {
        self.focused && target == self.target
    }

    func value(of target: InlineAccessibilityTarget) -> String? {
        self.value
    }

    func selectedRange(of target: InlineAccessibilityTarget) -> CFRange? {
        self.selection
    }

    func setValue(_ value: String, on target: InlineAccessibilityTarget) -> Bool {
        self.value = value
        if self.mutateThenFailNextValueWrite {
            self.mutateThenFailNextValueWrite = false
            return false
        }
        return true
    }

    func setSelectedRange(_ range: CFRange, on target: InlineAccessibilityTarget) -> Bool {
        if self.failNextSelectionWrite {
            self.failNextSelectionWrite = false
            return false
        }
        self.selection = range
        return true
    }

    func restoreFocus(to target: InlineAccessibilityTarget) -> Bool {
        self.focused = true
        return true
    }
}
