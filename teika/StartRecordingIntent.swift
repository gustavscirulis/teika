import AppIntents

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription(
        "Opens Teika and starts recording. The transcript is saved as a note and copied to the clipboard.",
        categoryName: "Recording",
        searchKeywords: ["dictate", "dictation", "transcribe", "voice", "speech", "note"]
    )
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingLauncher.shared.request()
        return .result()
    }
}
