import Foundation
import AlarmKit
import ActivityKit

nonisolated struct ActrailAlarmMetadata: AlarmMetadata {
    let reminderId: String
}

final class AlarmKitManager {
    static let shared = AlarmKitManager()
    let alarmManager = AlarmManager.shared

    private static let registryKey = "com.actrail.alarmRegistry"

    /// 本 app 排定过的系统闹钟 id 登记册（与 reminders 缓存独立，防孤儿）。
    func registeredAlarmIDs() -> [UUID] {
        guard let data = UserDefaults.standard.stringArray(forKey: Self.registryKey) else { return [] }
        return data.compactMap(UUID.init(uuidString:))
    }

    func registerAlarm(id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.registryKey) ?? []
        let key = id.uuidString
        if !ids.contains(key) {
            ids.append(key)
            UserDefaults.standard.set(ids, forKey: Self.registryKey)
            DiagnosticLog.append(tag: "AlarmRegistry", message: "登记闹钟 \(key.prefix(8))（累计 \(ids.count)）")
        }
    }

    func clearAlarmRegistry() {
        UserDefaults.standard.removeObject(forKey: Self.registryKey)
    }

    var authorizationState: AlarmManager.AuthorizationState {
        alarmManager.authorizationState
    }

    var isAuthorized: Bool {
        if case .authorized = alarmManager.authorizationState {
            return true
        }
        return false
    }

    func ensureAuthorized() async -> Bool {
        let state = alarmManager.authorizationState
        switch state {
        case .authorized:
            return true
        case .denied:
            print("[AlarmKit] Denied")
            return false
        case .notDetermined:
            do {
                let result = try await alarmManager.requestAuthorization()
                return result == .authorized
            } catch {
                print("[AlarmKit] Auth error: \(error)")
                return false
            }
        @unknown default:
            return false
        }
    }

    private func makeConfiguration(date: Date, reminderId: String, alarmSound: String = "default") async throws -> AlarmManager.AlarmConfiguration<ActrailAlarmMetadata> {
        let alert = AlarmPresentation.Alert(
            title: "请检查当前正在进行的活动是否正确",
            stopButton: AlarmButton(text: "停止", textColor: .white, systemImageName: "stop")
        )
        let metadata = ActrailAlarmMetadata(reminderId: reminderId)
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: metadata,
            tintColor: .blue
        )
        let schedule = Alarm.Schedule.fixed(date)
        let sound: ActivityKit.AlertConfiguration.AlertSound = alarmSound == "none"
            ? .named("silent.caf")
            : .default
        return AlarmManager.AlarmConfiguration(
            schedule: schedule,
            attributes: attributes,
            sound: sound
        )
    }

    func scheduleAlarm(date: Date, reminderId: String, alarmSound: String = "default") async throws -> UUID {
        let configuration = try await makeConfiguration(date: date, reminderId: reminderId, alarmSound: alarmSound)
        let alarmID = UUID()
        let alarm = try await alarmManager.schedule(id: alarmID, configuration: configuration)
        if alarm.id != alarmID {
            DiagnosticLog.append(tag: "AlarmKitAPI", message: "⚠️ 系统 id 重写: 传入 \(alarmID.uuidString.prefix(8)) → 实际 \(alarm.id.uuidString.prefix(8))")
        }
        registerAlarm(id: alarm.id)
        DiagnosticLog.append(tag: "AlarmKitAPI", message: "scheduleAlarm 成功 id=\(alarm.id.uuidString.prefix(8)) reminder=\(reminderId.prefix(8)) date=\(date)")
        return alarm.id
    }

    func cancelAlarms(ids: [UUID]) {
        DiagnosticLog.append(tag: "AlarmKitAPI", message: "cancelAlarms(count=\(ids.count))")
        for id in ids {
            cancelAlarm(id: id)
        }
    }

    func cancelAlarm(id: UUID) {
        do {
            try alarmManager.cancel(id: id)
            DiagnosticLog.append(tag: "AlarmKitAPI", message: "✓ cancelAlarm 成功 \(id.uuidString.prefix(8))")
        } catch {
            DiagnosticLog.append(tag: "AlarmKitAPI", message: "✗ cancelAlarm 失败 \(id.uuidString.prefix(8)): \(error.localizedDescription)")
        }
    }

    func stopAlarm(id: UUID) {
        DiagnosticLog.append(tag: "AlarmKitAPI", message: "stopAlarm \(id.uuidString.prefix(8))")
        try? alarmManager.stop(id: id)
    }

    /// 闹钟进入响铃状态（.alerting）时回调对应的闹钟 id。
    var onAlarmAlerting: ((UUID) -> Void)?

    private var isMonitoringAlarms = false

    /// 监听系统闹钟状态流：一旦某闹钟 state 变为 .alerting（正在响铃）即回调。
    func startAlarmMonitoring() {
        guard !isMonitoringAlarms else { return }
        isMonitoringAlarms = true
        Task { [weak self] in
            guard let self else { return }
            var previous: [UUID: Alarm.State] = [:]
            for await alarms in self.alarmManager.alarmUpdates {
                var current: [UUID: Alarm.State] = [:]
                for alarm in alarms {
                    current[alarm.id] = alarm.state
                    if alarm.state == .alerting && previous[alarm.id] != .alerting {
                        self.onAlarmAlerting?(alarm.id)
                    }
                }
                previous = current
            }
        }
    }

    /// 查询系统实际排定的闹钟。返回 nil 表示系统查询失败，空数组表示无排定。
    func queryAlarms() -> [Alarm]? {
        do {
            let alarms = try alarmManager.alarms
            DiagnosticLog.append(tag: "AlarmKitAPI", message: "queryAlarms 成功 count=\(alarms.count)")
            return alarms
        } catch {
            DiagnosticLog.append(tag: "AlarmKitAPI", message: "queryAlarms 失败: \(error)")
            return nil
        }
    }

    /// 查询某个闹钟的实际触发时间。
    func alarmFireTime(id: UUID) -> Date? {
        guard let alarms = queryAlarms() else { return nil }
        guard let alarm = alarms.first(where: { $0.id == id }) else { return nil }
        if case .fixed(let date)? = alarm.schedule {
            return date
        }
        return nil
    }
}
