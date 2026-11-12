import CryptoKit
import Foundation

/// What Teika remembers about the file it wrote for a note, so later edits can be
/// written back to the same file, and only while nobody else has changed it.
nonisolated struct VaultRecord: Equatable, Sendable {
    /// Vault-relative path, e.g. `Inbox/2026-11-05 1432.md`.
    var path: String
    var prefix: String
    var suffix: String
    /// SHA-256 of the file exactly as Teika last wrote it.
    var hash: String
    var byteCount: Int
}

nonisolated enum VaultWriteResult: Equatable, Sendable {
    /// Written (or already identical). Carries the record for the file as it is now.
    case saved(VaultRecord)
    /// The file changed outside Teika since Teika last wrote it. Left untouched.
    case editedElsewhere
    /// The file is gone and no renamed copy was found next to it.
    case missing
}

nonisolated enum VaultWriteError: Error, Equatable {
    case noAccess
    case couldNotCreate
}

/// Reads and writes notes in a vault folder. All file access is coordinated, so it is
/// safe against iCloud Drive and Obsidian touching the same files, and it is meant to
/// run off the main thread: a coordinated read of a file iCloud has not downloaded yet
/// waits for the download.
nonisolated struct VaultWriter: Sendable {
    static let uniqueNoteSettingsPath = ".obsidian/zk-prefixer.json"
    static let templatesSettingsPath = ".obsidian/templates.json"

    let root: URL
    /// Called around each operation; a security-scoped URL needs it, a plain one does not.
    var scoped: Bool = true

    // MARK: Settings

    func settings(overrides: VaultNoteSettings.Overrides) throws -> VaultNoteSettings {
        try access {
            VaultNoteSettings.fromVault(
                uniqueNoteJSON: try read(Self.uniqueNoteSettingsPath),
                templatesJSON: try read(Self.templatesSettingsPath),
                overrides: overrides)
        }
    }

    // MARK: Notes

    /// Creates a new, uniquely named note. Never replaces an existing file: a clash
    /// gets ` 2`, ` 3`, … appended, which Obsidian itself does not do.
    func create(
        text: String, date: Date, overrides: VaultNoteSettings.Overrides,
        timeZone: TimeZone = .current
    ) throws -> VaultRecord {
        try access {
            let settings = VaultNoteSettings.fromVault(
                uniqueNoteJSON: try read(Self.uniqueNoteSettingsPath),
                templatesJSON: try read(Self.templatesSettingsPath),
                overrides: overrides)
            let template = try settings.resolvedTemplatePath
                .flatMap { try read($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            let folder = settings.resolvedFolder(for: date, timeZone: timeZone)
            let base = settings.baseName(for: date, timeZone: timeZone)

            for attempt in 1...500 {
                let name = attempt == 1 ? base : "\(base) \(attempt)"
                let path = folder.isEmpty ? "\(name).md" : "\(folder)/\(name).md"
                guard !exists(path) else { continue }
                // `{{title}}` is the note's name, as in Obsidian, so render per attempt.
                let rendered = VaultNoteTemplate.render(
                    template: template, title: name, date: date, settings: settings,
                    timeZone: timeZone)
                let data = Data(rendered.content(with: text).utf8)
                if try createNew(path, data: data) {
                    return VaultRecord(
                        path: path, prefix: rendered.prefix, suffix: rendered.suffix,
                        hash: Self.hash(data), byteCount: data.count)
                }
            }
            throw VaultWriteError.couldNotCreate
        }
    }

    /// Rewrites the transcript in a file Teika created, unless it was changed elsewhere.
    /// A file renamed in place (same folder, same content) is followed to its new name.
    func update(_ record: VaultRecord, text: String) throws -> VaultWriteResult {
        try access {
            var record = record
            if try read(record.path) == nil {
                guard let renamed = try findRenamed(record) else { return .missing }
                record.path = renamed
            }
            guard let current = try read(record.path) else { return .missing }
            let data = Data((record.prefix + text + record.suffix).utf8)
            let currentHash = Self.hash(current)
            if currentHash == Self.hash(data) {
                record.hash = currentHash
                record.byteCount = current.count
                return .saved(record)
            }
            guard currentHash == record.hash else { return .editedElsewhere }
            try replace(record.path, data: data)
            record.hash = Self.hash(data)
            record.byteCount = data.count
            return .saved(record)
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: File access

    private func access<T>(_ body: () throws -> T) throws -> T {
        if scoped {
            guard root.startAccessingSecurityScopedResource() else { throw VaultWriteError.noAccess }
        }
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func url(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    /// Nil when the file does not exist.
    private func read(_ path: String) throws -> Data? {
        let url = url(path)
        guard exists(path) else { return nil }
        var coordinationError: NSError?
        var result: Result<Data?, Error> = .success(nil)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do { result = .success(try Data(contentsOf: url)) }
            catch CocoaError.fileReadNoSuchFile { result = .success(nil) }
            catch { result = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// iCloud Drive can stand a file in for a `.Name.md.icloud` placeholder until it
    /// downloads; either one means the name is taken.
    private func exists(_ path: String) -> Bool {
        let url = url(path)
        let placeholder = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).icloud", directoryHint: .notDirectory)
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path(percentEncoded: false))
            || fm.fileExists(atPath: placeholder.path(percentEncoded: false))
    }

    /// False when something already exists at the path.
    private func createNew(_ path: String, data: Data) throws -> Bool {
        let url = url(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Bool, Error> = .success(false)
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
            do {
                try data.write(to: url, options: .withoutOverwriting)
                result = .success(true)
            } catch CocoaError.fileWriteFileExists {
                result = .success(false)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func replace(_ path: String, data: Data) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(
            writingItemAt: url(path), options: .forReplacing, error: &coordinationError
        ) { url in
            result = Result { try data.write(to: url, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Obsidian renames a note in place. Look for a Markdown file in the same folder with
    /// exactly the content Teika last wrote.
    private func findRenamed(_ record: VaultRecord) throws -> String? {
        let folderPath = (record.path as NSString).deletingLastPathComponent
        let folder = folderPath.isEmpty ? root : root.appending(path: folderPath, directoryHint: .isDirectory)
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for candidate in candidates where candidate.pathExtension.lowercased() == "md" {
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard size == record.byteCount else { continue }
            let path = folderPath.isEmpty
                ? candidate.lastPathComponent : "\(folderPath)/\(candidate.lastPathComponent)"
            if let data = try read(path), Self.hash(data) == record.hash { return path }
        }
        return nil
    }
}
