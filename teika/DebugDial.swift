#if DEBUG
import AVFoundation
import DialKit
import Foundation

struct DebugConfig: Codable, Equatable {
    var appStoreScreenshots = false
    var showRecordingState = false
    var simulateLoading = false
    var simulateCompile = false
    var fakeProgress = 0.0
    var showRecordingShortcutPrompt = true
    var showEmptyNotesState = false

    static let dialControls: [DialControl<DebugConfig>] = [
        .group("screenshots", children: [
            // Configure the visual state before enabling screenshot mode, which hides
            // the DialKit launcher so it cannot appear in the capture.
            .toggle(
                "showRecordingState",
                keyPath: \.showRecordingState,
                label: "Record mode"
            ),
            .toggle(
                "appStoreScreenshots",
                keyPath: \.appStoreScreenshots,
                label: "App Store screenshots"
            ),
        ]),
        .group("notes", children: [
            .toggle(
                "showRecordingShortcutPrompt",
                keyPath: \.showRecordingShortcutPrompt,
                label: "Shortcut prompt"
            ),
            .toggle(
                "showEmptyNotesState",
                keyPath: \.showEmptyNotesState,
                label: "Empty notes state"
            ),
        ]),
        .group("modelLoading", children: [
            .toggle("simulateLoading", keyPath: \.simulateLoading),
            .slider("fakeProgress", keyPath: \.fakeProgress, range: 0...1, step: 0.01),
            .toggle("simulateCompile", keyPath: \.simulateCompile, label: "Compile phase"),
            .action("deleteModel", label: "Delete model & reload"),
        ])
    ]
}

/// Fixed, value-only presentation data for App Store captures. None of these notes are
/// SwiftData models, so screenshot mode cannot insert, delete, or alter the real library.
enum AppStoreScreenshotContent {
    struct SampleNote: Identifiable {
        let id: Int
        let text: String
        let createdAt: Date

        var title: String {
            String(text.prefix(60))
        }
    }

    static let transcript =
        "I kept coming back to the same idea. The fastest way to keep a thought "
        + "is to say it out loud before it gets away."

    static var notes: [SampleNote] {
        [
            SampleNote(
                id: 0,
                text: "Idea for the opening paragraph Start with the walk not the argument",
                createdAt: date(daysAgo: 0, hour: 10, minute: 42)
            ),
            SampleNote(
                id: 1,
                text: "Groceries, olive oil, rice, two lemons, coffee beans.",
                createdAt: date(daysAgo: 0, hour: 9, minute: 18)
            ),
            SampleNote(
                id: 2,
                text: "The bug only shows up when the network drops mid request.",
                createdAt: date(daysAgo: 1, hour: 18, minute: 36)
            ),
            SampleNote(
                id: 3,
                text: "Voicemail for the landlord about the radiator.",
                createdAt: date(daysAgo: 1, hour: 14, minute: 12)
            ),
            SampleNote(
                id: 4,
                text: "Book recommendation from the flight. Something about maps.",
                createdAt: date(daysAgo: 1, hour: 8, minute: 51)
            ),
            SampleNote(
                id: 5,
                text: "Follow up with Maya about the workshop outline.",
                createdAt: date(daysAgo: 4, hour: 16, minute: 24)
            ),
            SampleNote(
                id: 6,
                text: "The train is quieter after nine. That might be the best time to write.",
                createdAt: date(daysAgo: 4, hour: 9, minute: 7)
            ),
            SampleNote(
                id: 7,
                text: "Packing list for the weekend: charger, rain jacket, notebook.",
                createdAt: date(daysAgo: 12, hour: 19, minute: 43)
            ),
            SampleNote(
                id: 8,
                text: "A better name for the project might be hiding in the first draft.",
                createdAt: date(daysAgo: 24, hour: 11, minute: 15)
            ),
            SampleNote(
                id: 9,
                text: "Remember to send the photos before Friday.",
                createdAt: date(daysAgo: 45, hour: 15, minute: 32)
            ),
        ]
    }

    private static func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

/// Runs the microphone only far enough to drive the screenshot orb. Buffers are
/// measured in place and discarded; nothing is retained or passed to transcription.
@MainActor
final class DebugAudioLevelMonitor {
    let levelMeter = AudioLevelMeter()

    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var generation = 0

    func start() async -> Bool {
        if engine.isRunning { return true }

        generation += 1
        let token = generation
        guard await requestMicPermission(), token == generation else { return false }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)

            try await Task.sleep(for: .milliseconds(150))
            guard token == generation else { return false }

            engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                stop()
                return false
            }

            let meter = levelMeter
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }

                var sumSquares: Float = 0
                for index in 0..<frameCount {
                    sumSquares += samples[index] * samples[index]
                }
                let rms = (sumSquares / Float(frameCount)).squareRoot()
                let decibels = 20 * log10(max(rms, 1e-7))
                meter.report(min(max((decibels + 55) / 35, 0), 1))
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            return true
        } catch {
            guard token == generation else { return false }
            stop()
            return false
        }
    }

    func stop() {
        generation += 1
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine = AVAudioEngine()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        levelMeter.reset()
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

extension Notification.Name {
    static let teikaDeleteModel = Notification.Name("teika.debug.deleteModel")
}
#endif
