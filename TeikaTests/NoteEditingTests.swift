import SwiftData
import XCTest
@testable import Teika

@MainActor
final class NoteEditingTests: XCTestCase {
    func testEditedWatchNotePersistsWithoutChangingIdentityOrTransferMetadata() throws {
        let store = try NoteStore(inMemory: true)
        let timestamp = Date(timeIntervalSince1970: 123)
        let original = try store.addWatchNote(
            text: "Original transcript", createdAt: timestamp, clipID: "edited-clip")
        let noteID = original.note.persistentModelID
        let editedText = "Corrected thought\nA second line with café and 日本語."

        original.note.text = editedText
        try store.container.mainContext.save()

        let freshContext = ModelContext(store.container)
        let saved = try XCTUnwrap(freshContext.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(saved.text, editedText)
        XCTAssertEqual(saved.title, "Corrected thought")
        XCTAssertTrue(saved.text.localizedStandardContains("café"))
        XCTAssertEqual(saved.persistentModelID, noteID)
        XCTAssertEqual(saved.createdAt, timestamp)
        XCTAssertEqual(saved.watchClipID, "edited-clip")

        let redelivery = try store.addWatchNote(
            text: "Original transcript", createdAt: timestamp, clipID: "edited-clip")
        XCTAssertFalse(redelivery.inserted)
        XCTAssertEqual(redelivery.note.text, editedText)
        XCTAssertEqual(try freshContext.fetchCount(FetchDescriptor<Note>()), 1)
    }

    func testClearingNotePersistsAnUntitledNote() throws {
        let store = try NoteStore(inMemory: true)
        let note = try store.add(text: "A thought to clear")

        note.text = ""
        try store.container.mainContext.save()

        let freshContext = ModelContext(store.container)
        let saved = try XCTUnwrap(freshContext.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(saved.text, "")
        XCTAssertEqual(saved.title, "Untitled note")
        XCTAssertEqual(saved.persistentModelID, note.persistentModelID)
        XCTAssertEqual(try freshContext.fetchCount(FetchDescriptor<Note>()), 1)
    }
}
