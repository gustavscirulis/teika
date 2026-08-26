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
    let container: ModelContainer

    init() throws {
        container = try ModelContainer(for: Note.self)
    }

    @discardableResult
    func add(text: String, createdAt: Date = .now) throws -> Note {
        let note = Note(text: text, createdAt: createdAt)
        container.mainContext.insert(note)
        try container.mainContext.save()
        return note
    }
}
