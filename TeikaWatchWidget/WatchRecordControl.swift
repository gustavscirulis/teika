import SwiftUI
import WidgetKit

/// Teika in the watch's Control Center: one swipe up and a tap, from any app or the
/// watch face, instead of finding the app in the grid.
///
/// A distinct `kind` from the phone's `RecordControl` even though both say the same
/// thing. watchOS 26 also offers the paired iPhone's controls on the watch, and that
/// one would start a recording on the phone in your pocket — the opposite of what
/// someone reaching for their wrist means.
struct WatchRecordControl: ControlWidget {
    static let kind = "com.gustavscirulis.teika.watchkitapp.control.record"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRecordingOpenIntent()) {
                // Shorter than the phone's "Start Recording", which wraps to two lines
                // in the width a watch control tile gets.
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Start Recording")
        .description("Opens Teika on your watch and starts recording.")
    }
}
