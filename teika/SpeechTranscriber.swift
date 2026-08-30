import AVFoundation
import FluidAudio
import Observation
import UIKit

@MainActor
@Observable
final class SpeechTranscriber {
    enum ModelState: Equatable {
        /// First launch with no approved model on disk.
        case needsDownload
        /// The user approved the initial download. A nil fraction is the compile phase.
        case initialDownload(Double?)
        /// A previously downloaded model is loading into memory. Capture is available.
        case cachedPreparation
        case ready
        case failed(String)
    }

    enum ActivityState: Equatable {
        case idle
        case recording
        /// Audio has been captured and retained while the model is unavailable.
        case waitingForModel
        case transcribing
    }

    private(set) var modelState: ModelState
    private(set) var activityState: ActivityState = .idle
    /// A recoverable capture problem shown next to the record button.
    private(set) var notice: String?
    private(set) var noticeOffersSettings = false
    var onTranscription: ((String) -> Void)?

    let levelMeter = AudioLevelMeter()

    private var asrManager: AsrManager?
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private let samples = SampleStore()
    private var sessionActive = false
    /// Every start, stop, cancellation, and discard invalidates older continuations.
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    private struct LocalJob {
        let token: Int
        let samples: [Float]
    }

    private struct WatchJob {
        let id: UUID
        let samples: [Float]
        let continuation: CheckedContinuation<String, Error>
    }

    private enum ActiveInference: Hashable {
        case local(Int)
        case watch(UUID)
    }

    /// At most one local job exists. It is always selected before the next Watch job.
    private var localJob: LocalJob?
    private var watchJobs: [WatchJob] = []
    private var inferenceOrder = InferenceOrder<ActiveInference>()
    private var inferenceTask: Task<Void, Never>?

    private static let completedSetupKey = "teika.completedSpeechModelSetup"
    private var completedSetup: Bool {
        didSet { UserDefaults.standard.set(completedSetup, forKey: Self.completedSetupKey) }
    }

    /// Cached preparation permits capture; first-time setup and a known load failure do not.
    var canStartRecording: Bool {
        Self.recordingIsAvailable(modelState: modelState, activityState: activityState)
    }

    static func recordingIsAvailable(
        modelState: ModelState, activityState: ActivityState
    ) -> Bool {
        guard activityState == .idle else { return false }
        return switch modelState {
        case .cachedPreparation, .ready: true
        case .needsDownload, .initialDownload, .failed: false
        }
    }

    /// Published to the Watch. This means setup has completed before and deferred clips
    /// are welcome, not that the model happens to be resident in memory right now.
    var canAcceptDeferredClips: Bool {
        _ = modelState
        return completedSetup
    }

    init() {
        let modelsExist = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
        modelState = modelsExist ? .cachedPreparation : .needsDownload
        completedSetup = modelsExist || UserDefaults.standard.bool(
            forKey: Self.completedSetupKey)
        if !modelsExist {
            // A removed app/model must return to the consent gate. The Watch may still
            // have stale readiness and the phone will safely retain anything it sends.
            completedSetup = false
        }

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
        center.addObserver(forName: .teikaDeleteModel, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in await self?.resetModel() }
        }
        #endif
    }

    private func scheduleAbandonSession(_ message: String) {
        guard activityState == .recording else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self, token == self.generation else { return }
            self.failSession(message)
        }
    }

    /// Loads silently only when an already-approved model is on disk.
    func prepareIfNeeded() async {
        guard asrManager == nil, loadTask == nil else { return }
        if case .failed = modelState { return }
        guard AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
        else {
            modelState = .needsDownload
            return
        }
        await loadModel()
    }

    /// Starts the consented initial load or reloads a cached model.
    func loadModel() async {
        if asrManager != nil {
            notice = nil
            modelState = .ready
            resumePendingRecording()
            pumpInference()
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

    func retryModelLoad() async {
        notice = nil
        await loadModel()
    }

    private func performLoad() async {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        let alreadyDownloaded = AsrModels.modelsExist(at: cacheDir, version: .v3)
        modelState = alreadyDownloaded ? .cachedPreparation : .initialDownload(0)
        notice = nil
        do {
            let models: AsrModels
            if alreadyDownloaded {
                models = try await AsrModels.loadFromCache(version: .v3)
            } else {
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
            completedSetup = true
            excludeFromBackup(cacheDir)
            modelState = .ready
            resumePendingRecording()
            pumpInference()
        } catch {
            let message: String
            if alreadyDownloaded || completedSetup {
                message = "Couldn't prepare the speech model.\n\n\(error.localizedDescription)"
            } else {
                message = "Couldn't load the speech model. The first launch needs a network connection to download it (~0.5 GB); after that it works offline.\n\n\(error.localizedDescription)"
            }
            modelState = .failed(message)
            if activityState == .waitingForModel {
                notice = "Couldn't prepare the speech model. Your recording is still in memory."
            }
        }
    }

    private func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static let downloadPhaseWeight = 0.5

    private func updateDownloadProgress(_ progress: DownloadProgress) {
        guard case .initialDownload = modelState else { return }
        switch progress.phase {
        case .listing:
            break
        case .downloading:
            modelState = .initialDownload(
                min(progress.fractionCompleted / Self.downloadPhaseWeight, 1))
        case .compiling:
            modelState = .initialDownload(nil)
        }
    }

    func toggleRecording() {
        switch activityState {
        case .recording:
            stopAndTranscribe()
        case .waitingForModel:
            discardPendingRecording()
        case .transcribing:
            cancelRecording()
        case .idle:
            beginRecording()
        }
    }

    func startRecordingIfIdle() {
        guard canStartRecording else { return }
        beginRecording()
    }

    private func beginRecording() {
        guard canStartRecording, !sessionActive else { return }
        sessionActive = true
        generation += 1
        let token = generation
        notice = nil
        noticeOffersSettings = false
        Task { await startRecording(token: token) }
    }

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
            guard token == generation else { return }
            rebuildEngine()

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0,
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
                guard let out = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: capacity)
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
                        let values = channel[0]
                        for index in 0..<frames {
                            sumSquares += values[index] * values[index]
                        }
                        let rms = (sumSquares / Float(frames)).squareRoot()
                        let db = 20 * log10(max(rms, 1e-7))
                        meter.report(min(max((db + 55) / 35, 0), 1))
                    }
                }
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            UIApplication.shared.isIdleTimerDisabled = true
            activityState = .recording
        } catch {
            guard token == generation else { return }
            failSession("Couldn't start recording.\n\n\(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() {
        guard sessionActive else { return }
        endSession()
        let token = generation
        Haptics.recordingEnded()

        let captured = samples.drain()
        guard captured.count >= ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        else {
            activityState = .idle
            return
        }

        localJob = LocalJob(token: token, samples: captured)
        inferenceOrder.enqueueLocal(.local(token))
        if modelState == .ready, asrManager != nil {
            activityState = .transcribing
            pumpInference()
        } else {
            activityState = .waitingForModel
            if case .failed = modelState {
                notice = "Couldn't prepare the speech model. Your recording is still in memory."
            }
        }
    }

    private func resumePendingRecording() {
        guard activityState == .waitingForModel, localJob != nil,
              modelState == .ready, asrManager != nil
        else { return }
        notice = nil
        activityState = .transcribing
    }

    /// Explicitly releases retained iPhone audio without affecting Watch work.
    func discardPendingRecording() {
        guard activityState == .waitingForModel else { return }
        if let token = localJob?.token {
            inferenceOrder.cancelQueuedLocal(.local(token))
        }
        generation += 1
        localJob = nil
        notice = nil
        activityState = .idle
        pumpInference()
    }

    /// Cancels a queued or active local job. Watch jobs remain queued and keep running.
    func cancelRecording() {
        let queuedToken = localJob?.token
        endSession()
        localJob = nil
        _ = samples.drain()
        notice = nil
        noticeOffersSettings = false
        activityState = .idle
        if let queuedToken {
            inferenceOrder.cancelQueuedLocal(.local(queuedToken))
        }
        if case .local = inferenceOrder.active {
            inferenceTask?.cancel()
        } else {
            pumpInference()
        }
    }

    private func endSession() {
        generation += 1
        teardownEngine()
        sessionActive = false
    }

    private func failSession(_ message: String, offersSettings: Bool = false) {
        endSession()
        localJob = nil
        _ = samples.drain()
        notice = message
        noticeOffersSettings = offersSettings
        activityState = .idle
    }

    enum ClipError: Error {
        case modelNotDownloaded
        case modelUnavailable
        case empty
    }

    /// Enqueues Watch inference behind any active job. A local recording that stops while
    /// Watch work is active is selected before the next Watch clip.
    func transcribeClip(_ samples: [Float]) async throws -> String {
        guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        else { throw ClipError.empty }
        guard completedSetup else { throw ClipError.modelNotDownloaded }
        guard modelState == .ready, asrManager != nil else {
            throw ClipError.modelUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            watchJobs.append(
                WatchJob(id: UUID(), samples: samples, continuation: continuation))
            if let id = watchJobs.last?.id {
                inferenceOrder.enqueueWatch(.watch(id))
            }
            pumpInference()
        }
    }

    private func pumpInference() {
        guard modelState == .ready, let manager = asrManager,
              let next = inferenceOrder.startNext()
        else {
            return
        }

        if case .local(let token) = next,
           let job = localJob, job.token == token, activityState == .transcribing
        {
            localJob = nil
            inferenceTask = Task { [weak self] in
                let result = await Self.runInference(job.samples, manager: manager)
                self?.finishLocal(job, result: result)
            }
            return
        }

        guard case .watch(let id) = next,
              let index = watchJobs.firstIndex(where: { $0.id == id })
        else {
            inferenceOrder.finish(next)
            pumpInference()
            return
        }
        let job = watchJobs.remove(at: index)
        inferenceTask = Task { [weak self] in
            let result = await Self.runInference(job.samples, manager: manager)
            self?.finishWatch(job, result: result)
        }
    }

    private static func runInference(
        _ audio: [Float], manager: AsrManager
    ) async -> Result<String, Error> {
        do {
            var decoderState = TdtDecoderState.make(
                decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(
                audio, decoderState: &decoderState, language: nil)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ClipError.empty }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    private func finishLocal(_ job: LocalJob, result: Result<String, Error>) {
        guard inferenceOrder.active == .local(job.token) else { return }
        inferenceOrder.finish(.local(job.token))
        inferenceTask = nil
        defer { pumpInference() }

        guard job.token == generation, activityState == .transcribing else { return }
        activityState = .idle
        switch result {
        case .success(let text):
            onTranscription?(text)
        case .failure(let error):
            if error is CancellationError { return }
            notice = "Transcription failed. Try recording again.\n\n\(error.localizedDescription)"
        }
    }

    private func finishWatch(_ job: WatchJob, result: Result<String, Error>) {
        guard inferenceOrder.active == .watch(job.id) else { return }
        inferenceOrder.finish(.watch(job.id))
        inferenceTask = nil
        switch result {
        case .success(let text): job.continuation.resume(returning: text)
        case .failure(let error): job.continuation.resume(throwing: error)
        }
        pumpInference()
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

    #if DEBUG
    private func resetModel() async {
        guard activityState == .idle, inferenceOrder.active == nil else { return }
        asrManager = nil
        completedSetup = false
        modelState = .needsDownload
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: .v3))
        await prepareIfNeeded()
    }
    #endif
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
