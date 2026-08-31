import XCTest
@testable import Teika

final class PendingClipPersistenceTests: XCTestCase {
    func testReceivedClipRestoresAfterProcessTermination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let clip = PendingClip(
            clipID: "watch-1", recordedAt: Date(timeIntervalSince1970: 123))
        try Data([1, 2, 3]).write(to: clip.audioURL(in: directory))
        try JSONEncoder().encode(clip).write(to: clip.sidecarURL(in: directory))

        XCTAssertEqual(PendingClip.restoreAll(in: directory), [clip])
    }

    func testSidecarWithoutAudioIsNotRestored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let clip = PendingClip(
            clipID: "missing", recordedAt: Date(timeIntervalSince1970: 123))
        try JSONEncoder().encode(clip).write(to: clip.sidecarURL(in: directory))

        XCTAssertTrue(PendingClip.restoreAll(in: directory).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: clip.sidecarURL(in: directory).path))
    }
}
