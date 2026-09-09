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
        shared?.set(totalMinutes, forKey: AppGroupConstant.todayTotalMinutesKey)
        shared?.set(activeCount, forKey: AppGroupConstant.activeCountKey)

        if let start = activeStart {
            let baseSeconds = totalSeconds - Date().timeIntervalSince(start)
            shared?.set(start, forKey: AppGroupConstant.activeStartDateKey)
            shared?.set(Int(baseSeconds) / 60, forKey: AppGroupConstant.activeBaseMinutesKey)
        } else {
            shared?.removeObject(forKey: AppGroupConstant.activeStartDateKey)
            shared?.removeObject(forKey: AppGroupConstant.activeBaseMinutesKey)
        }

        WidgetCenter.shared.reloadAllTimelines()
        watchAppGroupLog.info("写入 AppGroup 完成 activeCount=\(activeCount, privacy: .public) totalMinutes=\(totalMinutes, privacy: .public) 并 reloadAllTimelines")
        WatchWakeLog.shared.add("写入 AppGroup 完成 activeCount=\(activeCount) totalMinutes=\(totalMinutes) 已 reload 表盘")
    }
}