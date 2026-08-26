import AppIntents

struct TeikaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start a recording with \(.applicationName)",
                "Start recording with \(.applicationName)",
                "Record with \(.applicationName)",
                "New recording with \(.applicationName)",
                "New note with \(.applicationName)",
                "Take a note with \(.applicationName)",
                "Dictate with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
    }
}
