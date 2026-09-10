import ClockKit
import Foundation
import os
import WidgetKit

let watchAppGroupLog = Logger(subsystem: "com.actrail.app", category: "complication")

// 在后台刷新 / 数据到达时把最新快照写入 AppGroup 并刷新表盘，
// 不依赖 VM/UI 存在。WatchActivityViewModel 与 BGTaskScheduler 均复用。
enum WatchAppGroupWriter {
    static func apply(_ data: Data) {
        guard let message = try? JSONDecoder().decode(WatchSyncManager.SyncMessage.self, from: data) else {
            watchAppGroupLog.error("AppGroupWriter 解码失败")
            return
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let activeCount = message.activeRecords.filter(\.isActive).count

        var totalSeconds: TimeInterval = 0
        var activeStart: Date?

        for record in message.completedRecords where !record.isActive {
            guard let endTime = record.endTime else { continue }
            if record.startTime >= startOfDay && record.startTime < endOfDay {
                totalSeconds += endTime.timeIntervalSince(record.startTime)
            }
        }

        for record in message.activeRecords where record.isActive {
            if record.startTime >= startOfDay && record.startTime < endOfDay {
                totalSeconds += Date().timeIntervalSince(record.startTime)
                if activeStart == nil {
                    activeStart = record.startTime
                }
            }
        }

        let totalMinutes = Int(totalSeconds) / 60
        let shared = UserDefaults(suiteName: AppGroupConstant.suiteName)
        let oldCount = shared?.integer(forKey: AppGroupConstant.activeCountKey) ?? -1
        let oldTotal = shared?.integer(forKey: AppGroupConstant.todayTotalMinutesKey) ?? -1
        shared?.set(totalMinutes, forKey: AppGroupConstant.todayTotalMinutesKey)
        shared?.set(activeCount, forKey: AppGroupConstant.activeCountKey)
        let changed = activeCount != oldCount || totalMinutes != oldTotal

        if let start = activeStart {
            let baseSeconds = totalSeconds - Date().timeIntervalSince(start)
            shared?.set(start, forKey: AppGroupConstant.activeStartDateKey)
            shared?.set(Int(baseSeconds) / 60, forKey: AppGroupConstant.activeBaseMinutesKey)
        } else {
            shared?.removeObject(forKey: AppGroupConstant.activeStartDateKey)
            shared?.removeObject(forKey: AppGroupConstant.activeBaseMinutesKey)
        }

        // 只在数据真正变化时 reload，避免高频轮询烧光 watchOS 的 reload 预算
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
            // WatchKit (CLK) 表盘：立刻刷新每个已挂载的 complication（对标 atimelogger 机制）
            let server = CLKComplicationServer.sharedInstance()
            for complication in server.activeComplications ?? [] {
                server.reloadTimeline(for: complication)
            }
        }
        // 持久化到 watch app 沙盒：便于 devicectl 读取验证后台投递是否真正执行（TCCUI 唤醒不打日志回流）
        UserDefaults.standard.set(activeCount, forKey: "lastComplicationActiveCount")
        UserDefaults.standard.set(Date(), forKey: "lastComplicationWriteTime")
        // 透传 complication provider 实际读到的值，验证表盘渲染数据源是否拿到最新值
        if let groupUD = shared {
            UserDefaults.standard.set(groupUD.integer(forKey: "providerSeenActiveCount"), forKey: "providerSeenActiveCount")
            UserDefaults.standard.set(groupUD.object(forKey: "providerSeenTime") as? Date, forKey: "providerSeenTime")
            UserDefaults.standard.set(groupUD.integer(forKey: "clkSeenActiveCount"), forKey: "clkSeenActiveCount")
            UserDefaults.standard.set(groupUD.object(forKey: "clkSeenTime") as? Date, forKey: "clkSeenTime")
        }
        watchAppGroupLog.info("写入 AppGroup activeCount=\(activeCount, privacy: .public) totalMinutes=\(totalMinutes, privacy: .public) reloaded=\(changed, privacy: .public)")
        WatchWakeLog.shared.add("写入 AppGroup activeCount=\(activeCount) totalMinutes=\(totalMinutes) reloaded=\(changed)")
        // 环形接收日志：最近 20 次（active, 时间），定位表盘数字“回显”来源
        var applyLog = UserDefaults.standard.array(forKey: "watchApplyLog") as? [[String: Any]] ?? []
        applyLog.append(["active": activeCount, "total": totalMinutes, "reloaded": changed, "t": Date().timeIntervalSince1970])
        if applyLog.count > 20 { applyLog.removeFirst(applyLog.count - 20) }
        UserDefaults.standard.set(applyLog, forKey: "watchApplyLog")
    }
}