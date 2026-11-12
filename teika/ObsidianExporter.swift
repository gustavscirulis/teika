import Foundation
import Observation
import SwiftData

/// Writes each new note into an Obsidian vault as its own Markdown file, named and
/// filled the way the vault's Unique note creator would, and keeps that file in step
/// with later edits in Teika until it is changed in Obsidian.
///
/// Independent of the task exporter: a note can go to Things and to the vault.
@MainActor
@Observable
final class ObsidianExporter {
    static let enabledKey = "obsidianExportEnabled"
    static let bookmarkKey = "obsidianVaultBookmark"
    static let vaultNameKey = "obsidianVaultName"
    static let folderKey = "obsidianFolderOverride"
    static let filenameKey = "obsidianFilenameOverride"
    static let templateKey = "obsidianTemplateOverride"

    static func isActive(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey) && defaults.data(forKey: bookmarkKey) != nil
    }

    private(set) var isEnabled: Bool
    private(set) var vaultName: String?
    /// The vault's own settings, before Teika's overrides. Nil until read.
    private(set) var vaultSettings: VaultNoteSettings?
    private(set) var effectiveSettings: VaultNoteSettings?
    private(set) var setupError: String?
    private(set) var lastError: String?
    /// Bumped for each newly created file, for a confirmation on screen.
    private(set) var createdSerial = 0
    private(set) var lastCreatedPath: String?

    var overrides: VaultNoteSettings.Overrides {
        didSet {
            guard overrides != oldValue else { return }
            store.defaults.set(overrides.folder, forKey: Self.folderKey)
            store.defaults.set(overrides.filenameFormat, forKey: Self.filenameKey)
            store.defaults.set(overrides.templatePath, forKey: Self.templateKey)
            recomputeEffective()
        }
    }

    var hasVault: Bool { store.defaults.data(forKey: Self.bookmarkKey) != nil }

    private let store: NoteStore
    private let makeWriter: (@MainActor () -> VaultWriter?)?
    private let now: () -> Date
    private var dirty: [PersistentIdentifier] = []
    private var worker: Task<Void, Never>?
    private var debounces: [PersistentIdentifier: Task<Void, Never>] = [:]

    /// `writer` replaces the bookmarked vault, for tests.
    init(
        store: NoteStore, now: @escaping () -> Date = Date.init,
        writer: (@MainActor () -> VaultWriter?)? = nil
    ) {
        self.store = store
        self.makeWriter = writer
        self.now = now
        let defaults = store.defaults
        isEnabled = Self.isActive(in: defaults) || (writer != nil && defaults.bool(forKey: Self.enabledKey))
        vaultName = defaults.string(forKey: Self.vaultNameKey)
        overrides = .init(
            filenameFormat: defaults.string(forKey: Self.filenameKey) ?? "",
            folder: defaults.string(forKey: Self.folderKey) ?? "",
            templatePath: defaults.string(forKey: Self.templateKey) ?? "")
        store.onVaultNoteSaved = { [weak self] in self?.syncAllPending() }
    }

    // MARK: Setup

    /// Takes a folder from the document picker. The picker's URL is security-scoped
    /// for this launch only; the bookmark keeps access across launches.
    func chooseVault(_ url: URL) {
        setupError = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            store.defaults.set(bookmark, forKey: Self.bookmarkKey)
            store.defaults.set(url.lastPathComponent, forKey: Self.vaultNameKey)
            vaultName = url.lastPathComponent
            setEnabled(true)
            Task { await refreshSettings() }
        } catch {
            setupError = "Couldn’t keep access to that folder. Choose it again."
        }
    }

    func removeVault() {
        store.defaults.removeObject(forKey: Self.bookmarkKey)
        store.defaults.removeObject(forKey: Self.vaultNameKey)
        vaultName = nil
        vaultSettings = nil
        effectiveSettings = nil
        setEnabled(false)
    }

    func setEnabled(_ enabled: Bool) {
        store.defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled && (hasVault || makeWriter != nil)
    }

    /// Reads the vault's Unique note and Templates settings, for display.
    func refreshSettings() async {
        guard let writer = writer() else { return }
        let result = await Task.detached { Result { try writer.settings(overrides: .init()) } }.value
        switch result {
        case .success(let settings):
            vaultSettings = settings
            setupError = nil
        case .failure:
            vaultSettings = nil
            setupError = "Couldn’t read the vault. Open Obsidian once, or choose the folder again."
        }
        recomputeEffective()
    }

    private func recomputeEffective() {
        guard let vaultSettings else { effectiveSettings = nil; return }
        var settings = vaultSettings
        if !overrides.filenameFormat.trimmed.isEmpty { settings.filenameFormat = overrides.filenameFormat }
        if !overrides.folder.trimmed.isEmpty { settings.folder = overrides.folder }
        if !overrides.templatePath.trimmed.isEmpty { settings.templatePath = overrides.templatePath }
        effectiveSettings = settings
    }

    /// An example file path for the current settings.
    var examplePath: String? {
        guard let effectiveSettings else { return nil }
        let date = now()
        let folder = effectiveSettings.resolvedFolder(for: date)
        let name = effectiveSettings.baseName(for: date) + ".md"
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }

    private func writer() -> VaultWriter? {
        if let makeWriter { return makeWriter() }
        guard let bookmark = store.defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            setupError = "Teika lost access to the vault. Choose the folder again."
            return nil
        }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                store.defaults.set(fresh, forKey: Self.bookmarkKey)
            }
        }
        return VaultWriter(root: url)
    }

    // MARK: Syncing

    /// Queues every note whose file is missing or behind. Cheap when nothing is.
    func syncAllPending() {
        guard isEnabled else { return }
        let notes = (try? store.container.mainContext.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.vaultStateRaw != nil },
            sortBy: [SortDescriptor(\Note.createdAt)]))) ?? []
        for note in notes where note.needsVaultSync { enqueue(note.persistentModelID) }
    }

    /// For edits: waits for a pause in typing before touching the file.
    func noteEdited(_ note: Note, delay: Duration = .seconds(2)) {
        guard isEnabled, note.vaultState != nil else { return }
        let id = note.persistentModelID
        debounces[id]?.cancel()
        debounces[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.debounces[id] = nil
            self?.enqueue(id)
        }
    }

    /// Writes everything outstanding now, e.g. when leaving a note or the app.
    func flush() async {
        for (id, task) in debounces {
            task.cancel()
            enqueue(id)
        }
        debounces.removeAll()
        syncAllPending()
        await worker?.value
    }

    /// Detaches a note from a file that was edited or removed in Obsidian, and saves
    /// it as a new note there instead.
    func saveAsNewNote(_ note: Note) {
        note.vaultRecord = nil
        note.vaultSyncedText = nil
        note.vaultState = .pending
        try? store.container.mainContext.save()
        enqueue(note.persistentModelID)
    }

    /// Sends one existing note to the vault, e.g. one saved before the vault was set up.
    func send(_ note: Note) {
        guard note.vaultState == nil else { return }
        note.vaultState = .pending
        try? store.container.mainContext.save()
        enqueue(note.persistentModelID)
    }

    private func enqueue(_ id: PersistentIdentifier) {
        if !dirty.contains(id) { dirty.append(id) }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.dirty.isEmpty {
                let next = self.dirty.removeFirst()
                await self.sync(next)
            }
            self?.worker = nil
        }
    }

    private func sync(_ id: PersistentIdentifier) async {
        let context = store.container.mainContext
        guard isEnabled, let note = context.model(for: id) as? Note,
              !note.isDeleted, note.modelContext != nil, note.needsVaultSync
        else { return }
        let text = note.text
        let record = note.vaultRecord
        // An empty note has nothing to file yet; it is written once it has text.
        if record == nil, text.trimmed.isEmpty { return }
        guard let writer = writer() else {
            note.vaultState = .failed
            try? context.save()
            return
        }
        let createdAt = note.createdAt
        let overrides = overrides
        let result = await Task.detached { () -> Result<VaultWriteResult, Error> in
            Result {
                if let record { return try writer.update(record, text: text) }
                return .saved(try writer.create(text: text, date: createdAt, overrides: overrides))
            }
        }.value

        // The note may have been deleted, or edited again, while the file was written.
        guard let note = context.model(for: id) as? Note, !note.isDeleted, note.modelContext != nil
        else { return }
        switch result {
        case .success(.saved(let saved)):
            note.vaultRecord = saved
            note.vaultSyncedText = text
            note.vaultState = .saved
            lastError = nil
            if record == nil {
                lastCreatedPath = saved.path
                createdSerial += 1
            }
        case .success(.editedElsewhere):
            note.vaultState = .editedElsewhere
        case .success(.missing):
            note.vaultState = .missing
        case .failure:
            note.vaultState = .failed
            lastError = "Couldn’t save to Obsidian. Teika will try again."
        }
        try? context.save()
        if note.needsVaultSync, note.vaultState == .saved { enqueue(id) }
    }
}
