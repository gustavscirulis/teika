import Foundation
import Observation

/// A small hand-off point for system launch surfaces that can arrive before the
/// main view — and therefore its transcription coordinator — is available.
@MainActor
@Observable
final class RecordingLauncher {
    struct Request: Equatable {
        let id = UUID()
        let madeAt = Date()
    }

    static let shared = RecordingLauncher()

    private(set) var pending: Request?

    private init() {}

    /// Requests deliberately replace rather than queue: repeated taps still mean
    /// "start a recording", not a sequence of future recordings.
    func request() {
        pending = Request()
    }

    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}
