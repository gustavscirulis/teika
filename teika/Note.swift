import Foundation
import SwiftData

@Model
final class Note {
    var text: String
    var createdAt: Date
    /// Present only for notes originating on Apple Watch. The stable transfer ID makes
    /// a retried persistent delivery idempotent on the phone.
    var watchClipID: String?

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
}
