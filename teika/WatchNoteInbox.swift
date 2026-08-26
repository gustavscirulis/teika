import Foundation
import Observation

/// The last transcript that came from a watch clip, held until the phone has shown it.
///
/// Persisted rather than kept in memory because of when the work happens: a clip is
/// usually transcribed in a launch iOS made in the background, and that process is
/// suspended — often killed — long before anyone picks the phone up. The point of the
/// handover is that the transcript is waiting on screen when they do, so it has to
/// survive the app dying in between.
@MainActor
@Observable
final class WatchNoteInbox {
    private static let key = "watchNoteInbox.pendingText"
    private let defaults: UserDefaults

    /// Nil once `take()` has handed it to the screen. Observable so an app that is
    /// already open picks up a clip that lands while someone is looking at it.
    private(set) var pendingText: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pendingText = defaults.string(forKey: Self.key)
    }

    /// Only the most recent clip is kept. Two recordings in a row with no phone in
    /// between means the earlier one is already in the library, and only one transcript
    /// can be on screen anyway.
    func deliver(_ text: String) {
        pendingText = text
        persist()
    }

    func take() -> String? {
        defer {
            pendingText = nil
            persist()
        }
        return pendingText
    }

    private func persist() {
        if let pendingText {
            defaults.set(pendingText, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
