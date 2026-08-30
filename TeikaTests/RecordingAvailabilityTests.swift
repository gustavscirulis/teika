import XCTest
@testable import Teika

final class RecordingAvailabilityTests: XCTestCase {
    func testCachedPreparationAndReadyPermitIdleCapture() async {
        await MainActor.run {
            XCTAssertTrue(
                SpeechTranscriber.recordingIsAvailable(
                    modelState: .cachedPreparation, activityState: .idle))
            XCTAssertTrue(
                SpeechTranscriber.recordingIsAvailable(
                    modelState: .ready, activityState: .idle))
        }
    }

    func testFirstSetupAndKnownFailureBlockNewCapture() async {
        await MainActor.run {
            XCTAssertFalse(
                SpeechTranscriber.recordingIsAvailable(
                    modelState: .needsDownload, activityState: .idle))
            XCTAssertFalse(
                SpeechTranscriber.recordingIsAvailable(
                    modelState: .initialDownload(0.5), activityState: .idle))
            XCTAssertFalse(
                SpeechTranscriber.recordingIsAvailable(
                    modelState: .failed("failure"), activityState: .idle))
        }
    }

    func testActivityStateIsIndependentFromModelReadiness() async {
        await MainActor.run {
            for activity in [
                SpeechTranscriber.ActivityState.recording,
                .waitingForModel,
                .transcribing,
            ] {
                XCTAssertFalse(
                    SpeechTranscriber.recordingIsAvailable(
                        modelState: .ready, activityState: activity))
            }
        }
    }
}
