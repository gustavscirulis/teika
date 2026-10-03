import SwiftUI
import WidgetKit

/// Teika as a corner complication (e.g. Infograph).
///
/// `.accessoryCorner` is watchOS-only, so it can't be declared on the phone's
/// `RecordWidget` — the corner slot needs its own widget in this watch extension.
///
/// Complications are tap-to-launch surfaces: the whole tile opens the watch app
/// with `teika://record`, which the app drains via `RecordingLauncher` (the same
/// path as the phone widget's `.widgetURL`). In-widget `Button(intent:)`s don't
/// fire on watch-face complications, so this deliberately uses `.widgetURL`.
struct WatchRecordWidget: Widget {
    static let kind = "com.gustavscirulis.teika.watchkitapp.widget.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchRecordTimelineProvider()) { _ in
            WatchRecordWidgetView()
        }
        .configurationDisplayName("Start Recording")
        .description("Opens Teika on your watch and starts a new recording.")
        .supportedFamilies([.accessoryCorner])
    }
}

private struct WatchRecordTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> WatchRecordTimelineEntry {
        WatchRecordTimelineEntry(date: .now)
    }

    func getSnapshot(in _: Context, completion: @escaping (WatchRecordTimelineEntry) -> Void) {
        completion(WatchRecordTimelineEntry(date: .now))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WatchRecordTimelineEntry>) -> Void) {
        completion(Timeline(entries: [WatchRecordTimelineEntry(date: .now)], policy: .never))
    }
}

private struct WatchRecordTimelineEntry: TimelineEntry {
    let date: Date
}

private struct WatchRecordWidgetView: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.title2)
            .widgetURL(TeikaURL.record)
            .containerBackground(for: .widget) {
                Color.clear
            }
    }
}
