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

enum AppGroupConstant {
    static let suiteName = "group.com.actrail.app"
    static let todayTotalMinutesKey = "todayTotalMinutes"
    static let activeActivityNameKey = "activeActivityName"
    static let activeStartDateKey = "activeStartDate"
    static let activeBaseMinutesKey = "activeBaseMinutes"
}

struct ActivityTimelineProvider: TimelineProvider {
    func sharedTotalMinutes() -> Int {
        UserDefaults(suiteName: AppGroupConstant.suiteName)?.integer(forKey: AppGroupConstant.todayTotalMinutesKey) ?? 0
    }

    func sharedActiveStart() -> Date? {
        UserDefaults(suiteName: AppGroupConstant.suiteName)?.object(forKey: AppGroupConstant.activeStartDateKey) as? Date
    }

    func sharedActiveBase() -> Int {
        UserDefaults(suiteName: AppGroupConstant.suiteName)?.integer(forKey: AppGroupConstant.activeBaseMinutesKey) ?? sharedTotalMinutes()
    }

    func currentEntry() -> ActivityEntry {
        if let start = sharedActiveStart() {
            let base = sharedActiveBase()
            let minutes = base + Int(Date().timeIntervalSince(start)) / 60
            return ActivityEntry(date: Date(), totalMinutes: minutes)
        }
        return ActivityEntry(date: Date(), totalMinutes: sharedTotalMinutes())
    }

    func placeholder(in context: Context) -> ActivityEntry {
        currentEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        let now = Date()
        if let start = sharedActiveStart() {
            let base = sharedActiveBase()
            var entries: [ActivityEntry] = []
            for i in 0..<60 {
                let date = now.addingTimeInterval(TimeInterval(i * 60))
                let minutes = base + Int(date.timeIntervalSince(start)) / 60
                entries.append(ActivityEntry(date: date, totalMinutes: minutes))
            }
            completion(Timeline(entries: entries, policy: .atEnd))
        } else {
            let entry = ActivityEntry(date: now, totalMinutes: sharedTotalMinutes())
            let nextUpdate = now.addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
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