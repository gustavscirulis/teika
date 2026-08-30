import Foundation

/// The contract between the watch app and the phone app.
///
/// The watch records and hands the clip over; the phone transcribes it, saves the note
/// and reports back. Nothing here knows about WatchConnectivity — these are just the
/// keys and payloads that travel over it, kept in one place so the two sides cannot
/// disagree about a spelling.
nonisolated enum ClipTransfer {
    /// Keys for `transferFile` metadata and `updateApplicationContext`.
    enum Keys {
        /// Ties a clip to its result, so a late or duplicated reply can be ignored.
        static let clipID = "clipID"
        static let duration = "duration"
        /// When the user actually spoke, as `timeIntervalSince1970`. Used for the
        /// note's `createdAt` so a clip that transfers late still sorts correctly.
        static let recordedAt = "recordedAt"
        /// Application context: whether phone setup has completed and deferred clips
        /// are accepted. It does not mean the model is currently resident in memory.
        static let modelReady = "modelReady"
        /// Message payload key carrying an encoded `ClipResult`.
        static let result = "result"
    }

    // No timeout lives here on purpose. The watch does not wait for a result: it confirms
    // the hand-off and moves on, because there is no honest upper bound to wait for. A
    // clip usually arrives in a phone iOS has just launched behind the lock screen, which
    // gets about 30 seconds, and a cold load of the speech model can eat most of that —
    // the note is then finished whenever the phone is next opened, which may be hours.
    // Nothing is lost in the meantime; the clip is on disk on the phone.
}

/// What the phone reports back once it has dealt with a clip.
nonisolated struct ClipResult: Codable, Equatable {
    enum Outcome: String, Codable {
        case saved
        /// The phone has safely retained the file and will process it when model setup
        /// or cached preparation recovers.
        case deferred
        /// The phone has not downloaded the speech model yet. The watch cannot fix
        /// this — the download is consent-gated on the phone by design.
        case modelNotDownloaded
        case failed
    }

    let clipID: String
    let outcome: Outcome
    /// Length of the saved transcript. Not shown as text — the watch deliberately does
    /// not display the transcript — but it makes the confirmation legible to VoiceOver.
    let characters: Int
    let message: String?

    // Encoded rather than sent as a raw dictionary so both transports (`sendMessage`
    // and `transferUserInfo`, which only carry property-list types) can move the same
    // payload without a second hand-rolled serialisation.
    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> ClipResult? {
        try? JSONDecoder().decode(ClipResult.self, from: data)
    }
}
