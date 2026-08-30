import Foundation
import SwiftData

/// Owns the note database.
///
/// This exists because notes no longer only arrive while a view is on screen: a clip
/// from the watch can land in an app that iOS launched into the background, where
/// `ContentView` never appears and there is no view lifecycle for SwiftData's autosave
/// to ride on. So the container is created at app launch and every write goes through
/// here with an explicit `save()`.
@MainActor
final class NoteStore {
    struct WatchInsert {
        let note: Note
        let inserted: Bool
    }

    let container: ModelContainer

    init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: Note.self, configurations: configuration)
    }

    @discardableResult
    func add(text: String, createdAt: Date = .now) throws -> Note {
        let note = Note(text: text, createdAt: createdAt)
        container.mainContext.insert(note)
        try container.mainContext.save()
        return note
    }

    func note(forWatchClipID clipID: String) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in note.watchClipID == clipID })
        return try container.mainContext.fetch(descriptor).first
    }

    /// Returns the existing note when WatchConnectivity retries a clip that was already
    /// saved. Only the first delivery changes the library.
    func addWatchNote(text: String, createdAt: Date, clipID: String) throws -> WatchInsert {
        if let note = try note(forWatchClipID: clipID) {
            return WatchInsert(note: note, inserted: false)
        }
        let note = Note(text: text, createdAt: createdAt, watchClipID: clipID)
        container.mainContext.insert(note)
        try container.mainContext.save()
        return WatchInsert(note: note, inserted: true)
    }
}
