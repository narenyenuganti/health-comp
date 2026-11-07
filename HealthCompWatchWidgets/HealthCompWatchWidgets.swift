import SwiftUI
import WidgetKit

@main
struct HealthCompWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchMatchComplication()
    }
}

struct WatchMatchEntry: TimelineEntry {
    let date: Date
}

struct WatchMatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchMatchEntry {
        WatchMatchEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchMatchEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchMatchEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct WatchMatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchMatchComplication", provider: WatchMatchProvider()) { _ in
            Text("HealthComp")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Match")
        .description("The score of your match.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
