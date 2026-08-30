import SwiftData
import XCTest
@testable import Teika

@MainActor
final class WatchNoteIdempotencyTests: XCTestCase {
    func testDuplicateClipIDCreatesExactlyOneNote() throws {
        let store = try NoteStore(inMemory: true)
        let timestamp = Date(timeIntervalSince1970: 123)

        let first = try store.addWatchNote(
            text: "First transcript", createdAt: timestamp, clipID: "clip-1")
        let duplicate = try store.addWatchNote(
            text: "Duplicate transcript", createdAt: timestamp, clipID: "clip-1")

        XCTAssertTrue(first.inserted)
        XCTAssertFalse(duplicate.inserted)
        XCTAssertEqual(duplicate.note.text, "First transcript")
        XCTAssertEqual(
            try store.container.mainContext.fetchCount(FetchDescriptor<Note>()), 1)
    }
}
