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
    let defaults: UserDefaults
    var onNoteSaved: (() -> Void)?
    /// Separate from `onNoteSaved`, which the task exporter owns.
    var onVaultNoteSaved: (() -> Void)?

    init(inMemory: Bool = false, defaults: UserDefaults = .standard, storeURL: URL? = nil) throws {
        self.defaults = defaults
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(url: storeURL)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        }
        container = try ModelContainer(for: Note.self, configurations: configuration)
    }

    @discardableResult
    func add(text: String, createdAt: Date = .now) throws -> Note {
        let note = Note(text: text, createdAt: createdAt)
        prepareTaskExport(note)
        container.mainContext.insert(note)
        try container.mainContext.save()
        onNoteSaved?()
        onVaultNoteSaved?()
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
        prepareTaskExport(note)
        container.mainContext.insert(note)
        try container.mainContext.save()
        onNoteSaved?()
        onVaultNoteSaved?()
        return WatchInsert(note: note, inserted: true)
    }

    private func prepareTaskExport(_ note: Note) {
        if ObsidianExporter.isActive(in: defaults) { note.vaultState = .pending }
        let app = TaskExportApp.selected(in: defaults)
        guard app != .off else { return }
        note.taskExportAppRaw = app.rawValue
        note.thingsExportID = UUID().uuidString
        note.exportState = .pending
    }
}
