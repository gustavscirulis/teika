import XCTest
@testable import TeikaWatch

final class WatchOutboxTests: XCTestCase {
    func testAdoptionSurvivesRestorationUntilExplicitSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.m4a")
        try Data([1, 2, 3]).write(to: source)

        let adopted = try WatchOutboxClip.adopt(
            WatchRecorder.Recording(
                url: source, duration: 2,
                recordedAt: Date(timeIntervalSince1970: 123)),
            in: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(WatchOutboxClip.restoreAll(in: directory), [adopted])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: adopted.audioURL(in: directory).path))

        adopted.discard(from: directory)
        XCTAssertTrue(WatchOutboxClip.restoreAll(in: directory).isEmpty)
    }

    func testReconciliationKeepsFIFOAndSkipsSystemTransfers() {
        let clips = [
            clip("one", at: 1), clip("two", at: 2), clip("three", at: 3),
        ]
        let result = WatchOutboxClip.needingTransfer(
            clips, outstandingIDs: ["two"])
        XCTAssertEqual(result.map(\.clipID), ["one", "three"])
    }

    func testFailedOrNeverEnqueuedClipBecomesEligibleAgain() {
        let clip = clip("retry", at: 1)
        XCTAssertEqual(
            WatchOutboxClip.needingTransfer([clip], outstandingIDs: []).map(\.clipID),
            ["retry"])
    }

    private func clip(_ id: String, at time: TimeInterval) -> WatchOutboxClip {
        WatchOutboxClip(
            clipID: id, duration: 1,
            recordedAt: Date(timeIntervalSince1970: time))
    }
}
