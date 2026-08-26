import AVFoundation
import FluidAudio
import Observation
import UIKit

@MainActor
@Observable
final class SpeechTranscriber {
    enum State: Equatable {
        /// First launch with no model on disk. Nothing is fetched until the user
        /// approves the ~0.5 GB download, so the app never spends someone's data
        /// plan on its own initiative.
        case needsDownload
        case preparing
        case loadingModel(Double)
        case ready
        case recording
        case transcribing
        /// Model-load failure only. Invariant: `.failed` implies `asrManager == nil`,
        /// which is what makes "Try again" meaningful and lets the reset paths know
        /// it is safe to force `.ready` whenever a manager exists.
        case failed(String)
    }

    private(set) var state: State = .needsDownload
    private(set) var didDownload = false
    /// A recoverable problem shown next to the record button. Never blocks recording;
    /// cleared on the next attempt.
    private(set) var notice: String?
    private(set) var noticeOffersSettings = false
    var onTranscription: ((String) -> Void)?

    let levelMeter = AudioLevelMeter()

    private var asrManager: AsrManager?
    /// An audio-engine graph retains route-specific input-node and format state.
    /// Keeping one across a headset disconnect can leave the next tap on a stale node.
    /// Build a fresh graph for every capture after the session has selected its route.
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private let samples = SampleStore()
    /// True from the moment a capture is claimed until it is stopped or cancelled, so
    /// it covers the pre-`engine.start()` window too — it is *not* "the engine is
    /// running". It exists to make `installTap(onBus: 0)` single-entry.
    private var sessionActive = false
    /// Monotonic epoch. Bumped by every start/stop/cancel; an async continuation
    /// captured before a bump must abort without touching shared state.
    private var generation = 0
    private var transcribeTask: Task<Void, Never>?
    /// The in-flight model load, if any. Concurrent callers await this one rather than
    /// starting a second: the view's `.task` can re-fire, the download button can be
    /// double-tapped, and a watch clip can arrive mid-load and needs to *wait* for the
    /// manager rather than see `nil` and give up.
    private var loadTask: Task<Void, Never>?

    var canRecord: Bool {
        switch state {
        case .ready, .recording, .transcribing: return true
        case .needsDownload, .preparing, .loadingModel, .failed: return false
        }
    }

    /// Whether a clip handed over from the watch can be transcribed: the model is on
    /// disk, even if it is not loaded into memory yet.
    ///
    /// Deliberately not `canRecord`, which is about this device's own record button and
    /// is false for the whole of a background launch while the model loads — which is
    /// exactly when watch clips arrive. Reporting that to the watch would tell someone to
    /// "finish setup" on a phone that is at that moment transcribing what they just said.
    /// Mirrors the check `transcribeClip` makes for itself, so readiness and outcome
    /// cannot disagree. Reads `state` so observers re-fire when a download completes.
    var canTranscribeClips: Bool {
        if case .failed = state { return false }
        if asrManager != nil { return true }
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    init() {
        // Resolved on frame one from a file-existence check, so neither the consent gate
        // nor the loading path ever flashes the other's UI, and the orb's ramp starts
        // from the right floor instead of diving from a transient `.needsDownload`.
        state = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            ? .preparing : .needsDownload

        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            MainActor.assumeIsolated {
                self?.scheduleAbandonSession(
                    "Recording stopped because another app took over the audio.")
            }
        }

        // Only `.oldDeviceUnavailable` matters: unplugging the mic we are taping.
        // Every other reason (a new device appearing, a category change) is benign.
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            MainActor.assumeIsolated {
                self?.scheduleAbandonSession(
                    "Recording stopped because the microphone was disconnected.")
            }
        }

        center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let changedEngine = note.object as? AVAudioEngine else { return }
            MainActor.assumeIsolated {
                guard let self, changedEngine === self.engine else { return }
                self.scheduleAbandonSession(
                    "Recording stopped because the audio setup changed.")
            }
        }

        #if DEBUG
        center.addObserver(
            forName: .teikaDeleteModel, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.resetModel() }
        }
        #endif
    }

    /// Gated on `.recording` rather than `sessionActive` on purpose: the engine emits a
    /// configuration change as part of its own start-up, and reacting to that would
    /// tear down the session we are in the middle of building.
    private func abandonSession(_ message: String) {
        guard case .recording = state else { return }
        failSession(message)
    }

    /// Notification delivery is deferred by a turn so Core Audio can finish its own
    /// callback. The epoch prevents an event from an old route killing a newer capture.
    private func scheduleAbandonSession(_ message: String) {
        guard case .recording = state else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self, token == self.generation else { return }
            self.abandonSession(message)
        }
    }

    /// Called when the main view appears. Loads silently if the model is already on
    /// disk; otherwise parks in `.needsDownload` and waits for an explicit tap, so the
    /// first ~0.5 GB fetch is never something the app decides on its own.
    func prepareIfNeeded() async {
        guard asrManager == nil, loadTask == nil else { return }
        // A previous attempt already reported a failure, and a half-finished download
        // would read as "no model". Leave the message and its "Try again" standing
        // rather than silently dropping back to the consent gate.
        if case .failed = state { return }
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
        else {
            state = .needsDownload
            return
        }
        await loadModel()
    }

    func loadModel() async {
        if asrManager != nil {
            // "Try again" after a recoverable failure: the model is fine, only the
            // message needs clearing. Never clobber a live session.
            notice = nil
            switch state {
            case .recording, .transcribing: break
            case .needsDownload, .preparing, .loadingModel, .ready, .failed: state = .ready
            }
            return
        }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        let alreadyDownloaded = AsrModels.modelsExist(at: cacheDir, version: .v3)
        state = alreadyDownloaded ? .preparing : .loadingModel(0)
        notice = nil
        do {
            let models: AsrModels
            if alreadyDownloaded {
                models = try await AsrModels.loadFromCache(version: .v3)
            } else {
                didDownload = true
                models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    progressHandler: { [weak self] progress in
                        guard let self else { return }
                        Task { @MainActor in self.updateDownloadProgress(progress) }
                    }
                )
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            excludeFromBackup(cacheDir)
            state = .ready
        } catch {
            state = .failed(
                "Couldn't load the speech model. The first launch needs a network connection to download it (~0.5 GB); after that it works offline.\n\n\(error.localizedDescription)"
            )
        }
    }

    /// FluidAudio caches models under Application Support, which iCloud and Finder back
    /// up by default. Half a gigabyte of re-downloadable weights has no business in a
    /// user's backup, and Apple's data-storage guidelines say so explicitly.
    private func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func toggleRecording() {
        if case .transcribing = state {
            // Escape hatch out of a slow or hung transcription.
            cancelRecording()
            return
        }
        if sessionActive {
            stopAndTranscribe()
        } else {
            beginRecording()
        }
    }

    /// Starts a capture if, and only if, the transcriber is fully idle. Unlike
    /// `toggleRecording()`, this never turns a system shortcut into a stop or
    /// cancellation request.
    func startRecordingIfIdle() {
        guard case .ready = state else { return }
        beginRecording()
    }

    #if DEBUG
    private func resetModel() async {
        guard !sessionActive else { return }
        // loadModel() early-returns while a manager exists, so clear it first.
        asrManager = nil
        didDownload = false
        state = .needsDownload
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: .v3))
        // Back to the consent gate rather than straight to a download, so the dial can
        // re-exercise the first-launch path.
        await prepareIfNeeded()
    }
    #endif

    // FluidAudio keeps reporting through the CoreML compile that follows the
    // download, so the fraction alone would pin a meter at 100% for the whole
    // compile. The phase, not the fraction, ends the determinate ring.
    private static let downloadPhaseWeight = 0.5

    private func updateDownloadProgress(_ progress: DownloadProgress) {
        guard case .loadingModel = state else { return }
        switch progress.phase {
        case .listing:
            break
        case .downloading:
            state = .loadingModel(min(progress.fractionCompleted / Self.downloadPhaseWeight, 1))
        case .compiling:
            state = .preparing
        }
    }

    /// Claims the capture session *synchronously*, so a second tap in the same
    /// run-loop turn sees `sessionActive` and routes to `stopAndTranscribe()` instead
    /// of spawning a second start. Claiming inside the task would be too late.
    private func beginRecording() {
        guard asrManager != nil, !sessionActive else { return }
        sessionActive = true
        generation += 1
        let token = generation
        notice = nil
        Task { await startRecording(token: token) }
    }

    /// Always entered through `beginRecording()`, which has already claimed the
    /// session and issued `token`. Every suspension point below is followed by a
    /// token check: a superseded start must abort without touching the engine, since
    /// a newer session may already own the tap on bus 0.
    private func startRecording(token: Int) async {
        guard await requestMicPermission() else {
            guard token == generation else { return }
            failSession(
                "Microphone access is off. Enable it in Settings to dictate.",
                offersSettings: true)
            return
        }
        guard token == generation else { return }

        do {
            try ensureSessionActive()
            samples.reset()

            Haptics.recordingStarted()
            try await Task.sleep(for: .milliseconds(150))

            // Activating a session can itself finish an asynchronous route change.
            // Wait through that settle before asking the input node for its format,
            // then discard the graph that may still refer to the previous headset.
            guard token == generation else { return }
            rebuildEngine()

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard
                inputFormat.sampleRate > 0,
                inputFormat.channelCount > 0,
                let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                    interleaved: false),
                let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            else {
                failSession("Couldn't configure audio input.")
                return
            }

            let store = samples
            let meter = levelMeter
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
                else { return }

                var conversionError: NSError?
                var provided = false
                converter.convert(to: out, error: &conversionError) { _, status in
                    if provided {
                        status.pointee = .noDataNow
                        return nil
                    }
                    provided = true
                    status.pointee = .haveData
                    return buffer
                }

                if conversionError == nil, let channel = out.floatChannelData {
                    let frames = Int(out.frameLength)
                    store.append(UnsafeBufferPointer(start: channel[0], count: frames))

                    if frames > 0 {
                        var sumSquares: Float = 0
                        let samples = channel[0]
                        for i in 0..<frames { sumSquares += samples[i] * samples[i] }
                        let rms = (sumSquares / Float(frames)).squareRoot()
                        let db = 20 * log10(max(rms, 1e-7))
                        let level = min(max((db + 55) / 35, 0), 1)
                        meter.report(level)
                    }
                }
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            UIApplication.shared.isIdleTimerDisabled = true
            state = .recording
        } catch {
            guard token == generation else { return }
            failSession("Couldn't start recording.\n\n\(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() {
        guard sessionActive else { return }
        endSession()
        // Read the epoch *after* the bump: this transcription belongs to the epoch the
        // stop opened, so only a later cancel/start can invalidate it.
        let token = generation
        Haptics.recordingEnded()

        let captured = samples.drain()
        // FluidAudio throws ASRError.invalidAudioData below 300 ms. A clip that short
        // is a stray tap, not speech — acknowledge it with the haptic and forget it.
        guard captured.count >= ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        else {
            state = .ready
            return
        }
        state = .transcribing
        transcribeTask = Task { [weak self] in await self?.transcribe(captured, token: token) }
    }

    /// Universal reset. Deliberately not gated on `sessionActive`: it must also work
    /// from `.transcribing` and from the pre-start window.
    private func cancelRecording() {
        endSession()
        transcribeTask?.cancel()
        transcribeTask = nil
        _ = samples.drain()
        notice = nil
        // Never clobber .preparing/.loadingModel/.failed — all imply no manager yet.
        if asrManager != nil { state = .ready }
    }

    /// Ends the current capture session. Bumps the epoch (invalidating any in-flight
    /// startup or transcription continuation), unhooks the tap, releases the claim.
    private func endSession() {
        generation += 1
        teardownEngine()
        sessionActive = false
    }

    /// Single exit for every recoverable failure: drop the session, surface a message,
    /// and re-arm the button.
    private func failSession(_ message: String, offersSettings: Bool = false) {
        endSession()
        transcribeTask = nil
        _ = samples.drain()
        notice = message
        noticeOffersSettings = offersSettings
        if asrManager != nil { state = .ready }
    }

    enum ClipError: Error {
        /// Nothing on disk to load. The watch cannot resolve this — the ~0.5 GB fetch
        /// is consent-gated on the phone by design.
        case modelNotDownloaded
        case modelUnavailable
        case empty
    }

    /// Transcribes audio that did not come from this device's microphone — currently
    /// only clips recorded on the watch.
    ///
    /// Deliberately outside the `state` machine: the phone's own record button must not
    /// flicker into `.transcribing` because a watch clip landed, and a failure here must
    /// not set `notice`, which belongs to whatever the person holding the phone last did.
    func transcribeClip(_ samples: [Float]) async throws -> String {
        if asrManager == nil {
            // Never start the download on a watch clip's behalf: that would spend half a
            // gigabyte of someone's data plan on an action they took on a different
            // device, which is exactly what the consent gate exists to prevent.
            guard AsrModels.modelsExist(
                at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            else { throw ClipError.modelNotDownloaded }
            await loadModel()
        }
        guard let manager = asrManager else { throw ClipError.modelUnavailable }
        guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        else { throw ClipError.empty }

        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClipError.empty }
        return text
    }

    private func transcribe(_ audio: [Float], token: Int) async {
        guard let manager = asrManager else { return }
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(audio, decoderState: &decoderState, language: nil)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A cancel superseded this run. Dropping the text is safe only because no
            // path can start a new recording from `.transcribing` — only an explicit
            // cancel bumps the epoch here.
            guard token == generation else { return }
            state = .ready
            if !text.isEmpty {
                onTranscription?(text)
            }
        } catch {
            guard token == generation else { return }
            failSession("Transcription failed. Try recording again.\n\n\(error.localizedDescription)")
        }
    }

    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        levelMeter.reset()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Called only after this generation has activated and settled the audio session.
    /// The replacement is what prevents an idle headset switch from carrying a stale
    /// input node or hardware format into the new tap.
    private func rebuildEngine() {
        engine.stop()
        engine = AVAudioEngine()
        tapInstalled = false
    }

    private func ensureSessionActive() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(
                .playAndRecord, mode: .measurement,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        }
        try session.setActive(true)
    }

    private func requestMicPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private final class SampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock()
        buffer.append(contentsOf: chunk)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let copy = buffer
        buffer.removeAll(keepingCapacity: true)
        return copy
    }
}
