import SwiftUI
import WidgetKit

struct RecordControl: ControlWidget {
    static let kind = "com.gustavscirulis.teika.control.record"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRecordingOpenIntent()) {
                Label("Start Recording", systemImage: "mic.fill")
            }
        }
        .displayName("Start Recording")
        .description("Opens Teika and starts a new recording.")
    }
}
