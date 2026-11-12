import Foundation
import SwiftData

@Model
final class Note {
    var text: String
    var createdAt: Date
    /// Present only for notes originating on Apple Watch. The stable transfer ID makes
    /// a retried persistent delivery idempotent on the phone.
    var watchClipID: String?

    // Optional additions keep pre-integration notes ineligible during migration.
    var thingsExportID: String?
    var thingsExportStateRaw: String?
    var thingsOperationID: String?
    var thingsTaskID: String?
    // Keep the original Things column names for lightweight migration. The queue
    // uses those delivery fields for both apps; the receipt IDs remain separate.
    var taskExportAppRaw: String?
    var reminderID: String?
    var taskExportFailureRaw: String?

    // Obsidian vault export. Optional for lightweight migration; a nil state means the
    // note was never meant for the vault (it predates the setting, or it was off).
    var vaultStateRaw: String?
    var vaultPath: String?
    var vaultPrefix: String?
    var vaultSuffix: String?
    var vaultHash: String?
    var vaultByteCount: Int?
    /// The transcript as last written, so only real changes touch the file.
    var vaultSyncedText: String?

    var exportApp: TaskExportApp {
        // Eligible notes from before provider selection always belong to Things.
        taskExportAppRaw.flatMap(TaskExportApp.init(rawValue:)) ?? .things
    }

    var exportState: TaskExportState? {
        get { thingsExportStateRaw.flatMap(TaskExportState.init(rawValue:)) }
        set { thingsExportStateRaw = newValue?.rawValue }
    }

    var vaultState: VaultState? {
        get { vaultStateRaw.flatMap(VaultState.init(rawValue:)) }
        set { vaultStateRaw = newValue?.rawValue }
    }

    var vaultRecord: VaultRecord? {
        get {
            guard let vaultPath, let vaultHash else { return nil }
            return VaultRecord(
                path: vaultPath, prefix: vaultPrefix ?? "", suffix: vaultSuffix ?? "",
                hash: vaultHash, byteCount: vaultByteCount ?? 0)
        }
        set {
            vaultPath = newValue?.path
            vaultPrefix = newValue?.prefix
            vaultSuffix = newValue?.suffix
            vaultHash = newValue?.hash
            vaultByteCount = newValue?.byteCount
        }
    }

    /// True when the vault file is behind the note, or the note has no file yet.
    var needsVaultSync: Bool {
        switch vaultState {
        case .pending?, .failed?: true
        case .saved?: text != vaultSyncedText
        default: false
        }
    }

    init(text: String, createdAt: Date = .now, watchClipID: String? = nil) {
        self.text = text
        self.createdAt = createdAt
        self.watchClipID = watchClipID
    }

    var title: String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled note" : String(trimmed.prefix(60))
    }

    var taskNotes: String {
        guard let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              firstLine.trimmingCharacters(in: .whitespaces) == title
        else { return text }
        // The title already contains this entire line. Keep any further detail,
        // or leave the task's notes empty for a short, single-line transcript.
        return String(text[firstLine.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TaskExportState: String {
    case pending, inFlight, exported, failed, cancelled, unconfirmed, skipped
}

enum VaultState: String {
    /// Waiting for its first or next write.
    case pending
    case saved
    /// Changed in Obsidian since Teika wrote it; Teika stops writing to that file.
    case editedElsewhere
    /// Deleted or moved out of its folder in Obsidian.
    case missing
    /// The last write failed; retried on the next change or launch.
    case failed
}
