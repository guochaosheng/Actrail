import WidgetKit
import SwiftUI
import os

let complicationLog = Logger(subsystem: "com.actrail.app", category: "complication")

struct ActrailWatchComplicationEntryView: View {
    var entry: ActivityEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                Text("\(entry.totalMinutes)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
            .widgetLabel {
                Text("\(entry.totalMinutes)")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(entry.totalMinutes)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.8)
            }
        case .accessoryInline:
            Text("\(entry.totalMinutes)")
        case .accessoryCorner:
            ZStack {
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                Text("\(entry.totalMinutes)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
            .widgetLabel {
                Text("\(entry.totalMinutes)")
            }
        default:
            Text("\(entry.totalMinutes)")
        }
    }
}

struct ActivityEntry: TimelineEntry {
    let date: Date
    let totalMinutes: Int
    let activeCount: Int
}

enum AppGroupConstant {
    static let suiteName = "group.com.actrail.app"
    static let todayTotalMinutesKey = "todayTotalMinutes"
    static let activeActivityNameKey = "activeActivityName"
    static let activeStartDateKey = "activeStartDate"
    static let activeBaseMinutesKey = "activeBaseMinutes"
    static let activeCountKey = "activeCount"
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

    func sharedActiveCount() -> Int {
        UserDefaults(suiteName: AppGroupConstant.suiteName)?.integer(forKey: AppGroupConstant.activeCountKey) ?? 0
    }

    func currentEntry() -> ActivityEntry {
        if let start = sharedActiveStart() {
            let base = sharedActiveBase()
            let minutes = base + Int(Date().timeIntervalSince(start)) / 60
            return ActivityEntry(date: Date(), totalMinutes: minutes, activeCount: sharedActiveCount())
        }
        return ActivityEntry(date: Date(), totalMinutes: sharedTotalMinutes(), activeCount: sharedActiveCount())
    }

    func placeholder(in context: Context) -> ActivityEntry {
        currentEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        let now = Date()
        // 观测：记录 provider 每次读取到的 activeCount，供主进程透传后外部验证
        let seen = sharedActiveCount()
        UserDefaults(suiteName: AppGroupConstant.suiteName)?.set(seen, forKey: "providerSeenActiveCount")
        UserDefaults(suiteName: AppGroupConstant.suiteName)?.set(now, forKey: "providerSeenTime")
        if let start = sharedActiveStart() {
            let base = sharedActiveBase()
            let minutes = base + Int(now.timeIntervalSince(start) / 60)
            let entry = ActivityEntry(date: now, totalMinutes: minutes, activeCount: sharedActiveCount())
            complicationLog.info("表盘重建 timeline(进行中) total=\(minutes, privacy: .public) activeCount=\(entry.activeCount, privacy: .public)")
            // 每分钟重建 timeline：既推进进行中分钟数，又能读取最新的 activeCount
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60))))
        } else {
            let entry = ActivityEntry(date: now, totalMinutes: sharedTotalMinutes(), activeCount: sharedActiveCount())
            complicationLog.info("表盘重建 timeline(空闲) total=\(entry.totalMinutes, privacy: .public) activeCount=\(entry.activeCount, privacy: .public)")
            // 每分钟重建 timeline：即使 watch app 未运行、无外部 reload，
            // 也能在 1 分钟内自动读取最新的 activeCount（系统按预算调度）。
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60))))
        }
    }
}

struct ActiveCountComplicationEntryView: View {
    var entry: ActivityEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                Text("\(entry.activeCount)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
            .widgetLabel {
                Text("\(entry.activeCount)")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(entry.activeCount)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .minimumScaleFactor(0.8)
            }
        case .accessoryInline:
            Text("\(entry.activeCount)")
        case .accessoryCorner:
            ZStack {
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                Text("\(entry.activeCount)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .minimumScaleFactor(0.7)
            }
            .widgetLabel {
                Text("\(entry.activeCount)")
            }
        default:
            Text("\(entry.activeCount)")
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
        .configurationDisplayName("今日活动时长")
        .description("显示今日活动总时长")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

struct ActiveCountComplication: Widget {
    let kind: String = "ActiveCountComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActivityTimelineProvider()) { entry in
            ActiveCountComplicationEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("进行中活动数")
        .description("显示当前正在进行活动的个数")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

@main
struct ActrailWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        ActrailWatchComplication()
        ActiveCountComplication()
    }
}