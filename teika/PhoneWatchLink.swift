import Foundation
import Observation
import UIKit
import WatchConnectivity
import os

/// File-level so the `nonisolated` delegate methods can log without hopping actors. Same
/// subsystem and category as the watch's, so `Console.app` shows both ends of a handover
/// as one timeline.
private let log = Logger(subsystem: "com.gustavscirulis.teika", category: "watch-link")

/// The phone half of the watch companion: receives recordings, transcribes them with
/// the model that is already loaded here, saves the note, and reports back.
///
/// Owned by `TeikaApp` and activated at launch rather than from a view. Most clips
/// arrive in an app that iOS launched into the background specifically to deliver them,
/// where no view has ever appeared — a session activated from `ContentView` would miss
/// them entirely.
@MainActor
final class PhoneWatchLink: NSObject {
    private let transcriber: SpeechTranscriber
    private let store: NoteStore
    private let inbox: WatchNoteInbox

    private var queue: [PendingClip] = []
    private var drain: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(transcriber: SpeechTranscriber, store: NoteStore, inbox: WatchNoteInbox) {
        self.transcriber = transcriber
        self.store = store
        self.inbox = inbox
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // A clip that outlived a previous launch — the background window expired
        // mid-transcription, or the app was killed. Nothing is lost, it just finishes now.
        queue.append(contentsOf: PendingClip.restoreAll())
        kickDrain()
        observeReadiness()
    }

    // MARK: - Readiness

    /// Tells the watch whether recording is worth offering at all. Without this the
    /// watch would let someone record, transfer, wait, and only then learn that the
    /// phone never downloaded the model.
    ///
    /// `canTranscribeClips` rather than `canRecord`: the question the watch is asking is
    /// whether the model exists, not whether it happens to be loaded right now. Most
    /// clips arrive in a background launch where it is not.
    private func pushReadiness() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled
        else { return }
        let ready = transcriber.canTranscribeClips
        log.info("pushing readiness \(ready), reachable \(session.isReachable)")
        try? session.updateApplicationContext([ClipTransfer.Keys.modelReady: ready])
    }

    /// `withObservationTracking` fires once per change, so it re-arms itself. Used in
    /// preference to a callback on `SpeechTranscriber` because `onTranscription` has
    /// already shown that a single closure slot is a landmine with two subscribers.
    private func observeReadiness() {
        withObservationTracking {
            _ = transcriber.canTranscribeClips
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pushReadiness()
                self.observeReadiness()
            }
        }
    }

    // MARK: - Queue

    private func enqueue(_ clip: PendingClip) {
        queue.append(clip)
        kickDrain()
    }

    /// One clip at a time, so two recordings in quick succession cannot both be holding
    /// half a gigabyte of decoded audio and a decoder state at once.
    private func kickDrain() {
        guard drain == nil, !queue.isEmpty else { return }
        beginBackgroundTask()
        drain = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let clip = self.queue.removeFirst()
                await self.process(clip)
            }
            guard let self else { return }
            self.endBackgroundTask()
            self.drain = nil
            // Clearing the handle and re-kicking has to happen with no suspension in
            // between: a clip that arrived while the last one was finishing would
            // otherwise find `drain` still set, decline to start, and then sit in the
            // queue until the next launch.
            self.kickDrain()
        }
    }

    private func process(_ clip: PendingClip) async {
        let result: ClipResult
        do {
            let samples = try ClipDecoder.decodeMono16k(clip.audioURL)
            let text = try await transcriber.transcribeClip(samples)
            try store.add(text: text, createdAt: clip.recordedAt)
            // Left for the screen to pick up, so a dictation started on the wrist ends
            // the same way as one started here: transcript on screen, text on the
            // clipboard. Almost always that happens in some later launch.
            inbox.deliver(text)
            result = ClipResult(
                clipID: clip.clipID, outcome: .saved, characters: text.count, message: nil)
        } catch SpeechTranscriber.ClipError.modelNotDownloaded {
            result = ClipResult(
                clipID: clip.clipID, outcome: .modelNotDownloaded, characters: 0,
                message: "Finish setup on your iPhone")
        } catch SpeechTranscriber.ClipError.empty {
            // Silence, or too short to be speech. The watch already applied its own
            // duration guard, so this is a clip of nothing rather than a mistake.
            result = ClipResult(
                clipID: clip.clipID, outcome: .failed, characters: 0,
                message: "Didn't catch that. Try again.")
        } catch {
            result = ClipResult(
                clipID: clip.clipID, outcome: .failed, characters: 0,
                message: "Couldn't transcribe that. Try again.")
        }
        reply(result)
        clip.discard()
    }

    /// Both channels, because they fail in opposite conditions: `sendMessage` is
    /// immediate but only while reachable, `transferUserInfo` survives the link dropping
    /// mid-transcription. The watch drops whichever arrives second by clip id.
    private func reply(_ result: ClipResult) {
        guard WCSession.isSupported(), let data = result.encoded() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = [ClipTransfer.Keys.result: data]
        log.info(
            "replying for clip \(result.clipID, privacy: .public): \(result.outcome.rawValue, privacy: .public), reachable \(session.isReachable)"
        )
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        session.transferUserInfo(payload)
    }

    // MARK: - Background window

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transcribe watch clip") {
            [weak self] in
            // Out of time. The clip stays on disk with its sidecar, so the next launch
            // picks it up rather than losing what someone said.
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - WCSessionDelegate

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.pushReadiness() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required on iOS: the session deactivates when the user switches to a different
    /// watch, and has to be reactivated to talk to the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushReadiness() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushReadiness() }
    }

    /// The inbox URL is deleted the moment this returns, so the file is moved out
    /// *synchronously* here — before any hop to the main actor.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let clip = PendingClip.adopt(file) else {
            log.error("could not adopt an incoming clip; it is lost")
            return
        }
        log.info("received clip \(clip.clipID, privacy: .public)")
        Task { @MainActor in self.enqueue(clip) }
    }
}

// MARK: - Pending clips

/// A received recording, held on disk until it has been transcribed.
///
/// On disk rather than in memory because the background window that delivered it is
/// about 30 seconds and loading the model can eat most of that. If time runs out the
/// clip is still here next launch.
private struct PendingClip: Codable {
    let clipID: String
    let recordedAt: Date

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PendingClips", isDirectory: true)
    }()

    var audioURL: URL { Self.directory.appendingPathComponent("\(clipID).m4a") }
    var sidecarURL: URL { Self.directory.appendingPathComponent("\(clipID).json") }

    static func adopt(_ file: WCSessionFile) -> PendingClip? {
        let metadata = file.metadata ?? [:]
        let clipID = metadata[ClipTransfer.Keys.clipID] as? String ?? UUID().uuidString
        let recordedAt = (metadata[ClipTransfer.Keys.recordedAt] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:)) ?? .now
        let clip = PendingClip(clipID: clipID, recordedAt: recordedAt)

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: clip.audioURL.path) {
                try fm.removeItem(at: clip.audioURL)
            }
            try fm.moveItem(at: file.fileURL, to: clip.audioURL)
            try JSONEncoder().encode(clip).write(to: clip.sidecarURL)
        } catch {
            return nil
        }
        return clip
    }

    static func restoreAll() -> [PendingClip] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let clip = try? JSONDecoder().decode(PendingClip.self, from: data),
                      fm.fileExists(atPath: clip.audioURL.path)
                else {
                    try? fm.removeItem(at: url)
                    return nil
                }
                return clip
            }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    func discard() {
        let fm = FileManager.default
        try? fm.removeItem(at: audioURL)
        try? fm.removeItem(at: sidecarURL)
    }
}
