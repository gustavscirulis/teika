import Foundation
import Observation
import WatchConnectivity
import WatchKit
import os

nonisolated private let log = Logger(
    subsystem: "com.gustavscirulis.teika", category: "watch-link")

/// The Watch capture state machine. Reachability affects only the confirmation copy;
/// after prior phone setup, recordings are accepted into a persistent local outbox.
@MainActor
@Observable
final class WatchLink: NSObject {
    enum Phase: Equatable {
        case connecting
        case blocked(String)
        case idle
        case recording
        case sent
        case queued
        case notice(String)
    }

    private(set) var phase: Phase = .connecting
    let recorder = WatchRecorder()

    private var modelReady: Bool {
        get { UserDefaults.standard.bool(forKey: Self.modelReadyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.modelReadyKey) }
    }
    private static let modelReadyKey = "teika.modelReady"

    private var outstanding: Set<String> = []
    private var enqueuedTransfers: Set<String> = []
    private var resetToIdle: Task<Void, Never>?
    private var isActive = true
    private var armedStart: Date?
    private static let armedStartWindow: TimeInterval = 10
    private var hasActivated = false

    var isRecording: Bool { phase == .recording }

    var canRecord: Bool {
        switch phase {
        case .idle, .recording, .notice, .sent, .queued: true
        case .connecting, .blocked: false
        }
    }

    var orbPresence: Double {
        switch phase {
        case .connecting, .blocked: 0
        case .idle, .recording, .notice, .sent, .queued: 1
        }
    }

    func activate() {
        guard !hasActivated else {
            reconcileOutbox()
            refreshGate()
            return
        }
        hasActivated = true
        WatchRecorder.sweepStaleClips()
        guard WCSession.isSupported() else {
            phase = .blocked("This watch can't connect to your iPhone.")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if let ready = session.receivedApplicationContext[ClipTransfer.Keys.modelReady] as? Bool {
            modelReady = ready
        }
        refreshGate()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        log.info("scene active: \(active)")
        guard active else { return }
        reconcileOutbox()
        refreshGate()
    }

    // MARK: - Gate

    /// Reachability is intentionally absent. An activated local session can enqueue a
    /// background file transfer whether or not the phone can answer right now.
    private var closedGate: Phase? {
        guard WCSession.isSupported() else {
            return .blocked("This watch can't connect to your iPhone.")
        }
        let session = WCSession.default
        if Self.recordingGateIsOpen(
            permissionDenied: recorder.permissionDenied,
            sessionActivated: session.activationState == .activated,
            companionInstalled: session.isCompanionAppInstalled,
            modelReady: modelReady)
        {
            return nil
        }
        if recorder.permissionDenied {
            return .blocked("Microphone is off. Turn it on in the Watch app.")
        }
        if session.activationState != .activated { return .connecting }
        if !session.isCompanionAppInstalled {
            return .blocked("Install Teika on your iPhone")
        }
        return .blocked("Finish setup on your iPhone")
    }

    static func recordingGateIsOpen(
        permissionDenied: Bool, sessionActivated: Bool, companionInstalled: Bool,
        modelReady: Bool
    ) -> Bool {
        !permissionDenied && sessionActivated && companionInstalled && modelReady
    }

    private func refreshGate() {
        guard isActive else { return }
        switch phase {
        case .recording, .sent, .queued: return
        case .connecting, .blocked, .idle, .notice: break
        }
        if let closed = closedGate {
            phase = closed
            return
        }
        switch phase {
        case .connecting, .blocked: phase = .idle
        case .idle, .notice, .recording, .sent, .queued: break
        }
        fireArmedStart()
    }

    // MARK: - Recording

    func requestRecording() {
        guard !isRecording else { return }
        log.info("recording requested from outside the app")
        if closedGate == nil {
            beginRecording()
        } else {
            armedStart = .now
        }
    }

    private func fireArmedStart() {
        guard let madeAt = armedStart else { return }
        armedStart = nil
        guard Date.now.timeIntervalSince(madeAt) < Self.armedStartWindow else {
            log.info("armed start expired before the gate opened")
            return
        }
        beginRecording()
    }

    func toggleRecording() {
        switch phase {
        case .recording: stopAndQueue()
        case .idle, .notice, .sent, .queued: beginRecording()
        case .connecting, .blocked: break
        }
    }

    private func beginRecording() {
        guard closedGate == nil else {
            refreshGate()
            return
        }
        resetToIdle?.cancel()
        Task {
            guard await recorder.requestPermission() else {
                phase = .blocked("Microphone is off. Turn it on in the Watch app.")
                return
            }
            guard closedGate == nil else {
                refreshGate()
                return
            }
            do {
                try recorder.start()
                phase = .recording
                WatchHaptics.recordingStarted()
            } catch {
                phase = .notice("Couldn't start recording. Try again.")
                scheduleNoticeClear()
            }
        }
    }

    private func stopAndQueue() {
        guard let recording = recorder.stop() else {
            WatchHaptics.recordingEnded()
            refreshGateFromRest()
            return
        }

        let wasReachable = WCSession.default.isReachable
        do {
            let clip = try WatchOutboxClip.adopt(recording)
            submit(clip)
            log.info(
                "queued clip \(clip.clipID, privacy: .public), \(clip.duration, format: .fixed(precision: 1))s, reachable \(wasReachable)"
            )
            WatchHaptics.recordingEnded()
            phase = wasReachable ? .sent : .queued
            scheduleConfirmationClear()
        } catch {
            try? FileManager.default.removeItem(at: recording.url)
            WatchHaptics.recordingEnded()
            phase = .notice("Couldn't queue that recording. Try again.")
            scheduleNoticeClear()
        }
    }

    // MARK: - Persistent transfer

    private func submit(_ clip: WatchOutboxClip) {
        let session = WCSession.default
        guard session.activationState == .activated,
              !enqueuedTransfers.contains(clip.clipID)
        else { return }
        session.transferFile(clip.audioURL, metadata: clip.metadata)
        enqueuedTransfers.insert(clip.clipID)
        outstanding.insert(clip.clipID)
    }

    /// Reconciles app-owned files against WatchConnectivity's system-owned queue. Any
    /// file not represented there is safe to submit again; duplicate delivery is harmless
    /// because the phone saves by clip ID.
    private func reconcileOutbox() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let systemIDs = Set(
            session.outstandingFileTransfers.compactMap {
                $0.file.metadata?[ClipTransfer.Keys.clipID] as? String
            })
        enqueuedTransfers = systemIDs
        outstanding.formUnion(systemIDs)
        for clip in WatchOutboxClip.needingTransfer(
            WatchOutboxClip.restoreAll(), outstandingIDs: systemIDs)
        {
            submit(clip)
        }
    }

    // MARK: - Results and messages

    private func handle(_ result: ClipResult) {
        guard outstanding.remove(result.clipID) != nil else { return }
        log.info(
            "result for clip \(result.clipID, privacy: .public): \(result.outcome.rawValue, privacy: .public)"
        )
        switch result.outcome {
        case .saved, .deferred:
            break
        case .modelNotDownloaded, .failed:
            guard !isRecording else { return }
            phase = .notice(result.message ?? "Couldn't transcribe that. Try again.")
            scheduleNoticeClear()
        }
    }

    private func scheduleConfirmationClear() {
        resetToIdle?.cancel()
        resetToIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refreshGateFromRest()
        }
    }

    private func scheduleNoticeClear() {
        resetToIdle?.cancel()
        resetToIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.refreshGateFromRest()
        }
    }

    private func refreshGateFromRest() {
        guard !isRecording else { return }
        phase = .idle
        refreshGate()
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        log.info(
            "activated: state \(activationState.rawValue), companion \(session.isCompanionAppInstalled), reachable \(session.isReachable), error \(error?.localizedDescription ?? "none", privacy: .public)"
        )
        Task { @MainActor in
            self.reconcileOutbox()
            self.refreshGate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("reachability changed: \(session.isReachable)")
        Task { @MainActor in
            // A connectivity change never interrupts capture. It only creates another
            // opportunity to reconcile transfers after the recording is stopped.
            self.reconcileOutbox()
            self.refreshGate()
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshGate() }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let ready = applicationContext[ClipTransfer.Keys.modelReady] as? Bool
        Task { @MainActor in
            if let ready { self.modelReady = ready }
            self.refreshGate()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[ClipTransfer.Keys.result] as? Data,
              let result = ClipResult.decode(from: data)
        else { return }
        Task { @MainActor in self.handle(result) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[ClipTransfer.Keys.result] as? Data,
              let result = ClipResult.decode(from: data)
        else { return }
        Task { @MainActor in self.handle(result) }
    }

    nonisolated func session(
        _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?
    ) {
        let clipID = fileTransfer.file.metadata?[ClipTransfer.Keys.clipID] as? String
        let failure = error?.localizedDescription
        Task { @MainActor in
            guard let clipID else { return }
            self.enqueuedTransfers.remove(clipID)
            if let failure {
                // Keep the app-owned file. A later activation, foreground return, or
                // reachability change will submit it again.
                log.error("transfer failed for clip \(clipID, privacy: .public): \(failure)")
                self.outstanding.remove(clipID)
                return
            }
            log.info("transfer landed for clip \(clipID, privacy: .public)")
            WatchOutboxClip.restoreAll().first { $0.clipID == clipID }?.discard()
        }
    }
}

@MainActor
enum WatchHaptics {
    static func recordingStarted() {
        WKInterfaceDevice.current().play(.start)
    }

    static func recordingEnded() {
        WKInterfaceDevice.current().play(.stop)
    }
}
