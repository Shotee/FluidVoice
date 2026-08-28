@testable import FluidVoice_Debug
import XCTest

final class ASRPartialUpdateTests: XCTestCase {
    func testPartialUpdatePreservesSessionOrderingAndEmptyText() {
        let sessionID = UUID()
        let first = ASRPartialUpdate(
            sessionID: sessionID,
            sequence: 1,
            text: "",
            sampleCount: 16_000,
            scope: .cumulative
        )
        let second = ASRPartialUpdate(
            sessionID: sessionID,
            sequence: 2,
            text: "こんにちは",
            sampleCount: 32_000,
            scope: .cumulative
        )

        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(first.sequence + 1, second.sequence)
        XCTAssertTrue(first.text.isEmpty)
        XCTAssertEqual(second.sampleCount, 32_000)
    }

    func testRollingWindowCarriesItsMaximumDuration() {
        let scope = StreamingHypothesisScope.rollingWindow(maxSeconds: 12)

        XCTAssertEqual(scope.maxSeconds, 12)
        XCTAssertNotEqual(scope, .cumulative)
    }

    func testSpeechModelsExposeExpectedHypothesisScope() {
        XCTAssertEqual(
            SettingsStore.SpeechModel.cohereTranscribeSixBit.streamingHypothesisScope,
            .rollingWindow(maxSeconds: 12)
        )
        XCTAssertEqual(
            SettingsStore.SpeechModel.parakeetTDT.streamingHypothesisScope,
            .cumulative
        )
    }

    func testInlineLiveTypingPersists() {
        let settings = SettingsStore.shared
        let original = settings.inlineLiveTypingEnabled
        defer { settings.inlineLiveTypingEnabled = original }

        settings.inlineLiveTypingEnabled = false
        XCTAssertFalse(settings.inlineLiveTypingEnabled)
        settings.inlineLiveTypingEnabled = true
        XCTAssertTrue(settings.inlineLiveTypingEnabled)
    }
}
