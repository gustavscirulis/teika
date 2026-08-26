import Foundation
import Observation
import WatchConnectivity
import WatchKit
import os

/// File-level rather than a static on `WatchLink`, so the `nonisolated` delegate methods
/// can log without hopping to the main actor first.
private let log = Logger(subsystem: "com.gustavscirulis.teika", category: "watch-link")

/// The watch app's whole state machine: the connection gate, the recording, the
/// handover to the phone, and the result coming back.
///
/// The watch is deliberately useless on its own. It cannot run the speech model, so
/// rather than accepting a recording and queueing it for whenever the phone next turns
/// up — `transferFile` would happily do that — recording is refused unless a phone is
/// connected *and* has its model ready. Everything that can go wrong is then visible
/// before the user speaks, and this class needs no disk queue.
///
/// What it deliberately does *not* do is wait. Handing the clip to `transferFile` is the
/// end of the watch's job: the file is queued by the system and the phone turns it into a
/// note on its own schedule, which can be minutes later — a clip usually lands in a phone
/// iOS has just launched behind the lock screen, where loading the speech model outlasts
/// the background window it was given, and the note is finished next time the phone is
/// opened. Blocking the button on a confirmation that far away would make the watch feel
/// broken while nothing was actually wrong.
///
/// So the button is live again the moment a clip is sent, several notes can be dictated
/// back to back, and the only thing that interrupts afterwards is a genuine failure.
@MainActor
@Observable
final class WatchLink: NSObject {
    enum Phase: Equatable {
        /// Waiting on the link to come up or come back. Shut like `.blocked`, but with
        /// nothing to say: a word that appears for a second and then leaves reads as a
        /// problem the user half-missed, so the ring around the button carries it instead.
        case connecting
        /// The gate is shut. Button disabled, orb settles to `OrbConfig.quiet`.
        case blocked(String)
        case idle
        case recording
        /// Toast acknowledging a clip handed to the phone. Clears itself, and unlike
        /// every other post-recording state it leaves the button untouched and live —
        /// the message is the whole confirmation.
        case sent
        /// Something to say after a recording. Clears itself.
        case notice(String)
    }

    private(set) var phase: Phase = .connecting
    let recorder = WatchRecorder()

    /// The phone's readiness, cached across launches so a cold start shows the truth
    /// immediately instead of flashing "not ready" until the first context arrives.
    private var modelReady: Bool {
        get { UserDefaults.standard.bool(forKey: Self.modelReadyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.modelReadyKey) }
    }
    private static let modelReadyKey = "teika.modelReady"

    /// Clips handed over and not yet answered for. Nothing waits on these — they exist so
    /// a result can be recognised whenever it turns up, and to dedupe: the phone answers
    /// on two channels, and a result for anything else is stale.
    private var outstanding: Set<String> = []
    private var resetToIdle: Task<Void, Never>?

    /// Whether the app is frontmost.
    ///
    /// watchOS reports `isReachable == false` whenever the watch app is not — dimming the
    /// screen or dropping your wrist is enough. That says nothing about the phone, so the
    /// gate is frozen while we are away rather than reacting to it, and re-checked on the
    /// way back.
    private var isActive = true

    /// Set while a fresh look at the connection is still settling.
    ///
    /// `isReachable` is false for a moment after the session activates and again after
    /// coming back to the foreground, before the link re-establishes. Calling that
    /// "iPhone not connected" turns an ordinary handshake into an error message, which is
    /// the wrong end of the story to tell someone whose phone is in their pocket.
    private var settling = true
    private var settleTask: Task<Void, Never>?

    /// How long reachability is given to come back before it is treated as real. Long
    /// enough to cover a foreground handshake, short enough that a genuinely absent phone
    /// is not misrepresented for long.
    private static let settleWindow: TimeInterval = 3

    /// A start asked for from outside the app — the Control Center control — held until
    /// the gate opens.
    ///
    /// Launching from the control lands here well before the session has finished shaking
    /// hands with the phone, so the gate is almost always still shut. Dropping the request
    /// for that would make the control fail exactly when it is meant to be fastest: you
    /// would tap it, watch the ring spin, and have to tap again.
    private var armedStart: Date?

    /// How long an armed start stays worth firing. Past this the moment has gone — an arm
    /// left over from a phone that took a minute to turn up would start recording an empty
    /// room long after the wrist came down.
    private static let armedStartWindow: TimeInterval = 10

    var isRecording: Bool { phase == .recording }

    /// Note that `.sent` is in here: acknowledging the last clip must not stand between
    /// someone and the next one.
    var canRecord: Bool {
        switch phase {
        case .idle, .recording, .notice, .sent: true
        case .connecting, .blocked: false
        }
    }

    /// How much of the orb to show. Matches the phone's language: a dim, sparse field
    /// means "not ready yet".
    var orbPresence: Double {
        switch phase {
        case .connecting, .blocked: 0
        case .idle, .recording, .notice, .sent: 1
        }
    }

    private var hasActivated = false

    /// Called from `onAppear`, which fires again every time the app comes back to the
    /// foreground — so this runs exactly once. The sweep in particular must not repeat:
    /// WatchConnectivity reads the original file while a transfer is in flight, and
    /// deleting it out from under a pending transfer would silently lose the clip.
    func activate() {
        guard !hasActivated else {
            refreshGate()
            return
        }
        hasActivated = true

        WatchRecorder.sweepStaleClips()
        guard WCSession.isSupported() else {
            phase = .blocked("This watch can't reach your iPhone.")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // `didReceiveApplicationContext` only fires for a context the watch has not seen,
        // and `updateApplicationContext` coalesces a repeat of the same payload — so a
        // reinstalled watch app would otherwise never learn a readiness the phone
        // published before it existed, and sit on "Finish setup on your iPhone" forever.
        if let ready = session.receivedApplicationContext[ClipTransfer.Keys.modelReady] as? Bool {
            modelReady = ready
        }
        beginSettling()
        refreshGate()
    }

    /// Driven by the scene phase. Coming back to the foreground is a fresh handshake, not
    /// a continuation of what was true when the screen went dark, so the connection is
    /// given the same grace it gets at launch.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        log.info("scene active: \(active)")
        guard active else { return }
        beginSettling()
        refreshGate()
    }

    // MARK: - The gate

    /// Holds the gate open on "Connecting…" for a moment, then re-checks. Cancelled and
    /// restarted by every fresh look, so overlapping ones cannot end each other's window.
    private func beginSettling() {
        settling = true
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleWindow))
            guard !Task.isCancelled, let self else { return }
            self.settling = false
            self.refreshGate()
        }
    }

    /// The shut-gate phase to show, or nil if recording is available. Returns the phase
    /// rather than a string so that waiting on the link — which has no message, only the
    /// ring — is a different answer from a problem that needs explaining.
    ///
    /// Microphone first: it is the one failure the user can fix without leaving the
    /// watch, and it survives every connection state.
    private var closedGate: Phase? {
        if recorder.permissionDenied {
            return .blocked("Microphone is off. Turn it on in the Watch app.")
        }
        guard WCSession.isSupported() else {
            return .blocked("This watch can't reach your iPhone.")
        }
        let session = WCSession.default
        if session.activationState != .activated { return .connecting }
        if !session.isCompanionAppInstalled { return .blocked("Install Teika on your iPhone") }
        if !session.isReachable {
            // Only once the link has had its moment to come back. Before that this is a
            // handshake in progress, not a missing phone.
            return settling ? .connecting : .blocked("iPhone not connected.")
        }
        if !modelReady { return .blocked("Finish setup on your iPhone") }
        return nil
    }

    /// Recomputed on every delegate callback, so the button and the orb track the
    /// connection live rather than only at launch. Only ever moves the app between
    /// resting states — it must not interrupt a recording or a confirmation.
    private func refreshGate() {
        // Nothing read here is trustworthy while the app is away, and nobody is looking
        // at the result. Whatever was on screen stays until we are back and have checked.
        guard isActive else { return }
        switch phase {
        case .recording, .sent: return
        case .connecting, .blocked, .idle, .notice: break
        }
        if let closed = closedGate {
            phase = closed
            return
        }
        // Opening the gate must not clear a notice that is still being read, or reset a
        // phase that was already open.
        switch phase {
        case .connecting, .blocked: phase = .idle
        case .idle, .notice, .recording, .sent: break
        }
        fireArmedStart()
    }

    // MARK: - Recording

    /// A recording asked for by something other than the button — currently the Control
    /// Center control, which opens the app for exactly this.
    ///
    /// Unlike `toggleRecording` this never *stops* one: arriving back in an app that is
    /// already recording means the control was tapped twice, and the second tap should
    /// not throw away what the first one started.
    func requestRecording() {
        guard !isRecording else { return }
        log.info("recording requested from outside the app")
        if closedGate == nil {
            beginRecording()
        } else {
            armedStart = .now
        }
    }

    /// Fired the moment the gate opens, so a control tap that arrived mid-handshake turns
    /// into a recording rather than being forgotten.
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
        case .recording: stopAndSend()
        // `.sent` included so the last clip's confirmation can be talked over by the
        // next note — dictating a few in a row should not mean waiting out a message.
        case .idle, .notice, .sent: beginRecording()
        case .connecting, .blocked: break
        }
    }

    private func beginRecording() {
        // The button is already disabled when the gate is shut; this catches a tap that
        // raced a reachability change.
        guard closedGate == nil else {
            refreshGate()
            return
        }
        // The message being tapped through is still holding a timer that would drop the
        // app back to idle. Left running, it would fire part-way into the recording that
        // just started and strand a live recorder behind an idle button.
        resetToIdle?.cancel()
        Task {
            guard await recorder.requestPermission() else {
                phase = .blocked(
                    "Microphone is off. Turn it on in the Watch app.")
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

    private func stopAndSend(disconnected: Bool = false) {
        guard let clip = recorder.stop() else {
            // Too short to be speech. Acknowledge it and forget it, exactly as the
            // phone does with a stray tap.
            WatchHaptics.recordingEnded()
            refreshGateFromRest()
            return
        }

        let clipID = UUID().uuidString
        WCSession.default.transferFile(
            clip.url,
            metadata: [
                ClipTransfer.Keys.clipID: clipID,
                ClipTransfer.Keys.duration: clip.duration,
                ClipTransfer.Keys.recordedAt: Date.now.timeIntervalSince1970,
            ])
        outstanding.insert(clipID)
        log.info(
            "handed over clip \(clipID, privacy: .public), \(clip.duration, format: .fixed(precision: 1))s, disconnected \(disconnected)"
        )

        if disconnected {
            // The gate was open when they started talking; losing the link halfway is
            // not a reason to delete what they said. The transfer is queued and will
            // deliver when the phone comes back — worth saying, since the delay here is
            // the one the user can actually see the cause of.
            WatchHaptics.recordingEnded()
            phase = .notice("iPhone not connected. This will save when it's back.")
            scheduleNoticeClear()
            return
        }

        // The recording has ended regardless of what happens to the queued transfer.
        // Use the matching stop haptic here as well as on the early-exit paths, so the
        // wrist always gets the same tactile boundary around captured audio.
        WatchHaptics.recordingEnded()
        phase = .sent
        resetToIdle?.cancel()
        resetToIdle = Task { [weak self] in
            // Longer than the 1.4s the checkmark used to get: this is now a line to read
            // rather than a shape to glance at, and it is the only confirmation there is.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refreshGateFromRest()
        }
    }

    // MARK: - Results

    /// The phone reporting back, whenever it gets round to it — seconds later if it was
    /// awake, minutes if the note had to wait for the app to be opened.
    ///
    /// Only bad news reaches the screen. The hand-off was already confirmed when the clip
    /// was sent, so repeating it later would be noise arriving long after the moment it
    /// belonged to; a failure is the one thing the user does not otherwise know.
    private func handle(_ result: ClipResult) {
        // Two channels answer; whichever arrives second is for a clip we have already
        // finished with.
        guard outstanding.remove(result.clipID) != nil else { return }
        log.info(
            "result for clip \(result.clipID, privacy: .public): \(result.outcome.rawValue, privacy: .public)"
        )

        switch result.outcome {
        case .saved:
            break
        case .modelNotDownloaded, .failed:
            // Never over a live recording: interrupting one thought to report on an
            // older one loses the thought, and the message would clear before it could
            // be read anyway.
            guard !isRecording else { return }
            phase = .notice(result.message ?? "Couldn't transcribe that. Try again.")
            scheduleNoticeClear()
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

    /// Drops to a resting state and immediately re-applies the gate, so a notice that
    /// times out while the phone is away lands on `.blocked` rather than a live button.
    ///
    /// Every caller is a timer, and any of them can land after a tap has already started
    /// the next recording — the second guard against the same race `beginRecording`
    /// cancels for, since a cancellation can lose to a task already past its sleep.
    private func refreshGateFromRest() {
        guard !isRecording else { return }
        phase = .idle
        refreshGate()
    }
}

// MARK: - WCSessionDelegate

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        log.info(
            "activated: state \(activationState.rawValue), companion \(session.isCompanionAppInstalled), reachable \(session.isReachable), error \(error?.localizedDescription ?? "none", privacy: .public)"
        )
        Task { @MainActor in
            // Restart the window from here rather than from the `activate()` that asked
            // for it: reachability only starts resolving once the session is up, so
            // measuring from the request spends part of the grace on the handshake.
            self.beginSettling()
            self.refreshGate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        log.info("reachability changed: \(reachable)")
        Task { @MainActor in
            // Only cut a recording short for a phone that actually went away. While the
            // app is in the background this fires because *we* went away — the screen
            // dimmed or a wrist dropped — and ending someone's sentence for that would
            // be the app misreading its own lifecycle as a lost connection.
            if !reachable, self.isActive, self.isRecording {
                self.stopAndSend(disconnected: true)
            }
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
        let url = fileTransfer.file.fileURL
        let clipID = fileTransfer.file.metadata?[ClipTransfer.Keys.clipID] as? String
        // `Error` is not Sendable, and only the text is wanted on the other side.
        let failure = error?.localizedDescription
        Task { @MainActor in
            // WatchConnectivity keeps its own copy until the transfer resolves, so the
            // original is ours to clean up either way.
            try? FileManager.default.removeItem(at: url)
            guard let clipID else { return }

            guard let failure else {
                log.info("transfer landed for clip \(clipID, privacy: .public)")
                return
            }

            // The one path where the clip really is gone, and so the only one that asks
            // for it to be recorded again. Everything else the phone can still recover.
            log.error("transfer failed for clip \(clipID, privacy: .public): \(failure)")
            self.outstanding.remove(clipID)
            guard !self.isRecording else { return }
            self.phase = .notice("Couldn't send that to your iPhone. Try again.")
            self.scheduleNoticeClear()
        }
    }
}

/// Tactile boundaries around capture. These run only after the recorder has actually
/// entered or left its recording state, rather than optimistically on the button tap.
@MainActor
enum WatchHaptics {
    static func recordingStarted() {
        WKInterfaceDevice.current().play(.start)
    }

    static func recordingEnded() {
        WKInterfaceDevice.current().play(.stop)
    }
}
