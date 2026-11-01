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

    var exportApp: TaskExportApp {
        // Eligible notes from before provider selection always belong to Things.
        taskExportAppRaw.flatMap(TaskExportApp.init(rawValue:)) ?? .things
    }

    var exportState: TaskExportState? {
        get { thingsExportStateRaw.flatMap(TaskExportState.init(rawValue:)) }
        set { thingsExportStateRaw = newValue?.rawValue }
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
