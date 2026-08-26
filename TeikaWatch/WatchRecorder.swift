import AVFoundation
import Foundation

/// Captures a clip on the wrist and hands back a file.
///
/// Uses `AVAudioRecorder` rather than the phone's `AVAudioEngine` tap: the phone needs
/// raw samples to feed the speech model, but the watch needs a *file* to hand to
/// WatchConnectivity, and `AVAudioRecorder` produces one directly with metering built
/// in. That removes the converter, the sample buffer and the level maths that the tap
/// on the phone has to do by hand.
@MainActor
@Observable
final class WatchRecorder {
    struct Recording {
        let url: URL
        let duration: TimeInterval
    }

    /// AAC rather than PCM, and this is the number that decides how the feature feels.
    /// A WatchConnectivity file transfer moves roughly 20–100 KB/s over the Bluetooth
    /// link. 16 kHz mono PCM is 32 KB/s of audio, so a 30-second note would be nearly a
    /// megabyte and take tens of seconds to arrive. At 48 kbps the same note is ~180 KB,
    /// which lands in a couple of seconds, and the loss is well below what the speech
    /// model can tell apart.
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 48_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    /// The duration analogue of the phone's `minimumRequiredSamples` guard. A tap this
    /// short is a stray touch, not speech, and the model rejects it anyway.
    static let minimumDuration: TimeInterval = 0.4

    let levelMeter = AudioLevelMeter()
    private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?

    var permissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }

        self.recorder = recorder
        isRecording = true
        startMetering()
    }

    /// Stops and returns the clip, or nil if it was too short to be speech (in which
    /// case the file is already deleted).
    func stop() -> Recording? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        let url = recorder.url
        recorder.stop()
        teardown()

        guard duration >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Recording(url: url, duration: duration)
    }

    func cancel() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        teardown()
        try? FileManager.default.removeItem(at: url)
    }

    /// Clears clips left behind by a transfer that never finished, or by the app being
    /// killed mid-recording. Cheap, and the alternative is a slowly filling temp
    /// directory the user can never see.
    static func sweepStaleClips() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: nil)
        else { return }
        for url in entries where url.lastPathComponent.hasPrefix("clip-") {
            try? fm.removeItem(at: url)
        }
    }

    private func teardown() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        isRecording = false
        levelMeter.reset()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// 30 Hz is plenty: the orb smooths the level with a 0.1 s attack and a 0.47 s
    /// decay, so sampling faster would buy nothing and cost wakeups.
    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.sampleLevel() }
        }
    }

    private func sampleLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // The same window the phone's tap uses on its own RMS, so both orbs respond to
        // a voice identically: −55 dBFS is silence, −20 dBFS is full deflection.
        let db = recorder.averagePower(forChannel: 0)
        levelMeter.report(min(max((db + 55) / 35, 0), 1))
    }

    enum RecorderError: Error {
        case couldNotStart
    }
}
