import WidgetKit
import SwiftUI

struct ActrailWatchComplicationEntryView: View {
    var entry: ActivityEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(entry.totalMinutes), in: 0...600) {
                Image(systemName: "timer")
            } currentValueLabel: {
                Text("\(entry.totalMinutes)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircular)
            .widgetLabel {
                Text("\(entry.totalMinutes)m")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("今日活动")
                    .font(.system(size: 10))
                    .minimumScaleFactor(0.8)
                Text("\(entry.totalMinutes)分钟")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.8)
            }
        case .accessoryInline:
            Text("\(entry.totalMinutes)分钟")
        case .accessoryCorner:
            Text("\(entry.totalMinutes)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .widgetLabel {
                    Gauge(value: Double(entry.totalMinutes), in: 0...600) {
                        Image(systemName: "timer")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                }
        default:
            Text("\(entry.totalMinutes)m")
        }
    }
}

struct ActivityEntry: TimelineEntry {
    let date: Date
    let totalMinutes: Int
}

struct ActivityTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActivityEntry {
        ActivityEntry(date: Date(), totalMinutes: 42)
    }

    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) {
        completion(ActivityEntry(date: Date(), totalMinutes: 42))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        let entry = ActivityEntry(date: Date(), totalMinutes: 42)
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct ActrailWatchComplication: Widget {
    let kind: String = "ActrailWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActivityTimelineProvider()) { entry in
            ActrailWatchComplicationEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("今日活动")
        .description("显示今日活动总时长")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

@main
struct ActrailWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        ActrailWatchComplication()
    }
}