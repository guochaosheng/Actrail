import ClockKit
import Foundation

// WatchKit 表盘数据源（对标 atimelogger 机制）：
// 注册后表盘可挂「进行中活动数」与「今日活动时长」两个 complication，
// 数据来自 AppGroup（与 watch 端写入同一份），iPhone 推送变化时 reloadTimeline 即时刷新。
final class WatchComplicationController: NSObject, CLKComplicationDataSource {

    private struct Snapshot {
        let activeCount: Int
        let totalMinutes: Int
    }

    static let activeCountKind = "ActiveCount"
    static let todayMinutesKind = "TodayMinutes"

    private func snapshot() -> Snapshot {
        guard let ud = UserDefaults(suiteName: AppGroupConstant.suiteName) else {
            return Snapshot(activeCount: 0, totalMinutes: 0)
        }
        let active = ud.integer(forKey: AppGroupConstant.activeCountKey)
        var minutes = ud.integer(forKey: AppGroupConstant.todayTotalMinutesKey)
        if let start = ud.object(forKey: AppGroupConstant.activeStartDateKey) as? Date {
            let base = ud.integer(forKey: AppGroupConstant.activeBaseMinutesKey)
            minutes = max(base, minutes) + Int(Date().timeIntervalSince(start) / 60)
        }
        return Snapshot(activeCount: active, totalMinutes: minutes)
    }

    private func isKind(_ kind: String, _ complication: CLKComplication) -> Bool {
        complication.identifier == kind
    }

    private func text(_ s: String) -> CLKSimpleTextProvider {
        CLKSimpleTextProvider(text: s)
    }

    private func template(for complication: CLKComplication, s: Snapshot) -> CLKComplicationTemplate? {
        let showActive = isKind(Self.activeCountKind, complication)
        let value = showActive ? s.activeCount : s.totalMinutes

        // 观测：记录 CLK 每次读取到的值，供主进程透传后外部验证
        if let ud = UserDefaults(suiteName: AppGroupConstant.suiteName) {
            ud.set(showActive ? s.activeCount : s.totalMinutes, forKey: "clkSeenActiveCount")
            ud.set(Date(), forKey: "clkSeenTime")
        }

        switch complication.family {
        case .modularSmall:
            return CLKComplicationTemplateModularSmallSimpleText(textProvider: text("\(value)"))
        case .utilitarianSmall:
            let label = showActive ? "\(value)个" : "\(value)分钟"
            return CLKComplicationTemplateUtilitarianSmallFlat(textProvider: text(label))
        case .circularSmall:
            return CLKComplicationTemplateCircularSmallSimpleText(textProvider: text("\(value)"))
        case .graphicCorner:
            let inner = CLKSimpleTextProvider(text: "\(value)")
            inner.tintColor = .orange
            return CLKComplicationTemplateGraphicCornerStackText(innerTextProvider: inner, outerTextProvider: text(showActive ? "进行中" : "今日分钟"))
        case .graphicCircular:
            let center = showActive ? text("\(value)个") : text("\(value)m")
            center.tintColor = .orange
            let gauge = CLKSimpleGaugeProvider(style: .fill, gaugeColor: showActive ? .orange : .green, fillFraction: 0)
            return CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
                gaugeProvider: gauge,
                bottomTextProvider: text(showActive ? "进行中" : "时长"),
                centerTextProvider: center
            )
        case .graphicRectangular:
            let header = text(showActive ? "进行中活动数" : "今日活动时长")
            let body = text(showActive ? "\(value) 个" : "\(value) 分钟")
            return CLKComplicationTemplateGraphicRectangularStandardBody(headerTextProvider: header, body1TextProvider: body, body2TextProvider: CLKSimpleTextProvider(text: ""))
        default:
            return nil
        }
    }

    // MARK: - CLKComplicationDataSource

    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        handler([
            CLKComplicationDescriptor(
                identifier: Self.activeCountKind,
                displayName: "CLK 进行中活动数 (CLK)",
                supportedFamilies: [.modularSmall, .utilitarianSmall, .circularSmall, .graphicCorner, .graphicCircular, .graphicRectangular]
            ),
            CLKComplicationDescriptor(
                identifier: Self.todayMinutesKind,
                displayName: "CLK 今日活动时长 (CLK)",
                supportedFamilies: [.modularSmall, .utilitarianSmall, .circularSmall, .graphicCorner, .graphicCircular, .graphicRectangular]
            ),
        ])
    }

    func getSupportedTimeTravelDirections(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTimeTravelDirections) -> Void) {
        handler([])
    }

    func getCurrentTimelineEntry(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        let s = snapshot()
        guard let t = template(for: complication, s: s) else {
            handler(nil)
            return
        }
        handler(CLKComplicationTimelineEntry(date: Date(), complicationTemplate: t))
    }

    func getTimelineEndDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        handler(nil)
    }

    func getPrivacyBehavior(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationPrivacyBehavior) -> Void) {
        handler(.showOnLockScreen)
    }

    func getPlaceholderTemplate(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTemplate?) -> Void) {
        handler(template(for: complication, s: Snapshot(activeCount: 0, totalMinutes: 0)))
    }

    func getLocalizableSampleTemplate(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTemplate?) -> Void) {
        handler(template(for: complication, s: Snapshot(activeCount: 1, totalMinutes: 30)))
    }

    func getAlwaysOnTemplate(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTemplate?) -> Void) {
        let s = snapshot()
        handler(template(for: complication, s: s))
    }
}