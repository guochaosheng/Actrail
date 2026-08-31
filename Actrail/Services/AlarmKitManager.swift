import Foundation
import AlarmKit

nonisolated struct ActivityAlarmMetadata: AlarmMetadata {
    let activityName: String
    let activityIconName: String
    let activityColor: String
    let reminderId: String
}

class AlarmKitManager {
    static let shared = AlarmKitManager()
    private let alarmManager = AlarmManager.shared
    
    var authorizationStateDescription: String {
        switch alarmManager.authorizationState {
        case .authorized: return "已授权"
        case .denied: return "已拒绝（需到系统设置中开启）"
        case .notDetermined: return "未确定（待请求）"
        @unknown default: return "未知"
        }
    }
    
    var isAuthorized: Bool {
        if case .authorized = alarmManager.authorizationState {
            return true
        }
        return false
    }
    
    func ensureAuthorized() async -> Bool {
        let state = alarmManager.authorizationState
        print("[AlarmKit] ensureAuthorized - state: \(state)")
        switch state {
        case .authorized:
            return true
        case .denied:
            print("[AlarmKit] Denied - user must enable in Settings")
            return false
        case .notDetermined:
            return await requestAuthorization()
        @unknown default:
            return await requestAuthorization()
        }
    }
    
    func requestAuthorization() async -> Bool {
        print("[AlarmKit] Requesting authorization... (current state: \(alarmManager.authorizationState))")
        do {
            let state = try await alarmManager.requestAuthorization()
            print("[AlarmKit] Auth result: \(state)")
            return state == .authorized
        } catch {
            print("[AlarmKit] Authorization error: \(error)")
            return false
        }
    }
    
    func scheduleAlarm(
        id: UUID,
        hour: Int,
        minute: Int,
        activityName: String,
        activityIconName: String,
        activityColor: String,
        reminderId: String
    ) async throws {
        print("[AlarmKit] Scheduling daily alarm for \(hour):\(minute)")
        
        let alert = AlarmPresentation.Alert(
            title: "该开始\(activityName)了"
        )
        
        let metadata = ActivityAlarmMetadata(
            activityName: activityName,
            activityIconName: activityIconName,
            activityColor: activityColor,
            reminderId: reminderId
        )
        
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: metadata,
            tintColor: .blue
        )
        
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        let recurrence = Alarm.Schedule.Relative.Recurrence.weekly([
            .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday
        ])
        let schedule = Alarm.Schedule.relative(
            .init(time: time, repeats: recurrence)
        )
        
        let config = AlarmManager.AlarmConfiguration(
            schedule: schedule,
            attributes: attributes,
            sound: .default
        )
        
        let alarm = try await alarmManager.schedule(id: id, configuration: config)
        print("[AlarmKit] Daily alarm scheduled: \(alarm)")
    }
    
    func cancelAlarm(id: UUID) async throws {
        try await alarmManager.cancel(id: id)
        print("[AlarmKit] Alarm cancelled: \(id)")
    }
    
    func stopAlarm(id: UUID) async throws {
        try await alarmManager.stop(id: id)
        print("[AlarmKit] Alarm stopped: \(id)")
    }
}
