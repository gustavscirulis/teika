import Foundation
import Observation
import UIKit
import WatchConnectivity
import os

nonisolated private let log = Logger(
    subsystem: "com.gustavscirulis.teika", category: "watch-link")

/// Receives persistent Watch transfers, keeps them on disk, and drains them through the
/// same one-at-a-time inference scheduler as foreground iPhone recordings.
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
        queue = PendingClip.restoreAll()
        observeTranscriber()
        kickDrain()
        // A background delivery does not necessarily create a visible SwiftUI task.
        // Loading an already-approved cache here ensures deferred clips still progress.
        Task { await transcriber.prepareIfNeeded() }
    }

    // MARK: - Readiness

    private func pushReadiness() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled
        else { return }
        let ready = transcriber.canAcceptDeferredClips
        log.info("pushing setup readiness \(ready), reachable \(session.isReachable)")
        try? session.updateApplicationContext([ClipTransfer.Keys.modelReady: ready])
    }

    private func observeTranscriber() {
        withObservationTracking {
            _ = transcriber.modelState
            _ = transcriber.canAcceptDeferredClips
        } onChange: { @Sendable [weak self] in
            guard let self else { return }
            Task { @MainActor [self] in
                self.pushReadiness()
                self.kickDrain()
                self.observeTranscriber()
            }
        }
    }

    // MARK: - Queue

    private func enqueue(_ clip: PendingClip) {
        if let existing = try? store.note(forWatchClipID: clip.clipID) {
            clip.discard()
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .saved, characters: existing.text.count,
                    message: nil))
            return
        }
        guard !queue.contains(where: { $0.clipID == clip.clipID }) else { return }
        queue.append(clip)
        queue.sort { $0.recordedAt < $1.recordedAt }

        guard transcriber.modelState == .ready else {
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .deferred, characters: 0,
                    message: "Queued on iPhone"))
            return
        }
        kickDrain()
    }

    /// Pauses without removing anything whenever the model is not ready. The scheduler
    /// itself provides local-next priority and serialises all AsrManager access.
    private func kickDrain() {
        guard drain == nil, !queue.isEmpty, transcriber.modelState == .ready else { return }
        beginBackgroundTask()
        drain = Task { [weak self] in
            guard let self else { return }
            var paused = false
            while !self.queue.isEmpty, self.transcriber.modelState == .ready {
                let clip = self.queue[0]
                guard await self.process(clip) else {
                    paused = true
                    break
                }
                if self.queue.first?.clipID == clip.clipID {
                    self.queue.removeFirst()
                } else {
                    self.queue.removeAll { $0.clipID == clip.clipID }
                }
            }
            self.endBackgroundTask()
            self.drain = nil
            if !paused { self.kickDrain() }
        }
    }

    /// Returns false only for a dependency failure that should pause the persistent drain.
    private func process(_ clip: PendingClip) async -> Bool {
        let samples: [Float]
        do {
            samples = try ClipDecoder.decodeMono16k(clip.audioURL)
        } catch {
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .failed, characters: 0,
                    message: "Couldn't read that recording. Try again."))
            clip.discard()
            return true
        }

        let text: String
        do {
            text = try await transcriber.transcribeClip(samples)
        } catch SpeechTranscriber.ClipError.modelNotDownloaded,
                SpeechTranscriber.ClipError.modelUnavailable {
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .deferred, characters: 0,
                    message: "Queued on iPhone"))
            return false
        } catch SpeechTranscriber.ClipError.empty {
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .failed, characters: 0,
                    message: "Didn't catch that. Try again."))
            clip.discard()
            return true
        } catch {
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .failed, characters: 0,
                    message: "Couldn't transcribe that. Try again."))
            clip.discard()
            return true
        }

        do {
            let insertion = try store.addWatchNote(
                text: text, createdAt: clip.recordedAt, clipID: clip.clipID)
            if insertion.inserted { inbox.deliver(text) }
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .saved, characters: text.count,
                    message: nil))
            clip.discard()
            return true
        } catch {
            // A database write can recover after relaunch. The audio remains on disk and
            // the stable clip ID makes another attempt safe.
            reply(
                ClipResult(
                    clipID: clip.clipID, outcome: .deferred, characters: 0,
                    message: "Queued on iPhone"))
            return false
        }
    }

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
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Transcribe watch clip"
        ) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.pushReadiness() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushReadiness() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushReadiness() }
    }

    /// The inbox URL disappears when this callback returns, so adoption is synchronous.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let clip = PendingClip.adopt(file) else {
            log.error("could not adopt an incoming clip; it is lost")
            return
        }
        log.info("received clip \(clip.clipID, privacy: .public)")
        Task { @MainActor in self.enqueue(clip) }
    }
}

/// A received recording held on disk until local processing has definitively finished.
nonisolated struct PendingClip: Codable, Equatable {
    let clipID: String
    let recordedAt: Date

    static let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PendingClips", isDirectory: true)
    }()

    var audioURL: URL { audioURL(in: Self.directory) }
    var sidecarURL: URL { sidecarURL(in: Self.directory) }

    func audioURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(clipID).m4a")
    }

    func sidecarURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(clipID).json")
    }

    static func adopt(_ file: WCSessionFile) -> PendingClip? {
        let metadata = file.metadata ?? [:]
        let clipID = metadata[ClipTransfer.Keys.clipID] as? String ?? UUID().uuidString
        let recordedAt = (metadata[ClipTransfer.Keys.recordedAt] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:)) ?? .now
        let clip = PendingClip(clipID: clipID, recordedAt: recordedAt)

        let fm = FileManager.default
        do {
            try prepareDirectory(at: directory)
            // An outstanding persistent transfer can be retried. Keep the first adopted
            // copy until its processing outcome is known and discard only the duplicate.
            if fm.fileExists(atPath: clip.audioURL.path),
               fm.fileExists(atPath: clip.sidecarURL.path)
            {
                try? fm.removeItem(at: file.fileURL)
                if let data = try? Data(contentsOf: clip.sidecarURL),
                   let existing = try? JSONDecoder().decode(PendingClip.self, from: data)
                {
                    return existing
                }
                return clip
            }
            try fm.moveItem(at: file.fileURL, to: clip.audioURL)
            try JSONEncoder().encode(clip).write(to: clip.sidecarURL, options: .atomic)
        } catch {
            return nil
        }
        return clip
    }

    static func restoreAll(in directory: URL = Self.directory) -> [PendingClip] {
        let fm = FileManager.default
        try? prepareDirectory(at: directory)
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let clip = try? JSONDecoder().decode(PendingClip.self, from: data),
                      fm.fileExists(atPath: clip.audioURL(in: directory).path)
                else {
                    try? fm.removeItem(at: url)
                    return nil
                }
                return clip
            }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    func discard(from directory: URL = Self.directory) {
        let fm = FileManager.default
        try? fm.removeItem(at: audioURL(in: directory))
        try? fm.removeItem(at: sidecarURL(in: directory))
    }

    private static func prepareDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)
    }
}
