import SwiftUI
import WidgetKit

struct RecordWidget: Widget {
    static let kind = "com.gustavscirulis.teika.widget.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: RecordTimelineProvider()) { _ in
            RecordWidgetView()
        }
        .configurationDisplayName("Start Recording")
        .description("Opens Teika and starts a new recording.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct RecordTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> RecordTimelineEntry {
        RecordTimelineEntry(date: .now)
    }

    func getSnapshot(in _: Context, completion: @escaping (RecordTimelineEntry) -> Void) {
        completion(RecordTimelineEntry(date: .now))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<RecordTimelineEntry>) -> Void) {
        completion(Timeline(entries: [RecordTimelineEntry(date: .now)], policy: .never))
    }
}

private struct RecordTimelineEntry: TimelineEntry {
    let date: Date
}

private struct RecordWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "mic.fill")
                    .font(.title2)
            case .accessoryRectangular:
                Label("Start recording", systemImage: "mic.fill")
                    .font(.headline)
            case .accessoryInline:
                Label("Record", systemImage: "mic.fill")
            default:
                VStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 34, weight: .medium))
                    Text("New Recording")
                        .font(.headline)
                }
            }
        }
        .widgetURL(TeikaURL.record)
        .containerBackground(for: .widget) {
            if family == .systemSmall {
                LinearGradient(
                    colors: [.black, Color(red: 0.08, green: 0.12, blue: 0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Color.clear
            }
        }
    }
}
