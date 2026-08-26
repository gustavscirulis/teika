import AppIntents

/// The system recognizes `OpenIntent` controls as app launchers only when this
/// type belongs to both the host app and the widget extension.
struct StartRecordingOpenIntent: OpenIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let isDiscoverable = false

    @Parameter(title: "Target", default: .record)
    var target: RecordingDestination

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingLauncher.shared.request()
        return .result()
    }
}

enum RecordingDestination: String, AppEnum {
    case record

    static let typeDisplayRepresentation = TypeDisplayRepresentation("Teika destination")
    static let caseDisplayRepresentations: [RecordingDestination: DisplayRepresentation] = [
        .record: "New Recording"
    ]
}
