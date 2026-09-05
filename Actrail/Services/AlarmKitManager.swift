import Foundation
import AlarmKit

nonisolated struct ActrailAlarmMetadata: AlarmMetadata {
    let reminderId: String
}

final class AlarmKitManager {
    static let shared = AlarmKitManager()
    let alarmManager = AlarmManager.shared

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

    private func makeConfiguration(date: Date, reminderId: String) async throws -> AlarmManager.AlarmConfiguration<ActrailAlarmMetadata> {
        let alert = AlarmPresentation.Alert(
            title: "行迹闹钟",
            stopButton: AlarmButton(text: "停止", textColor: .white, systemImageName: "stop")
        )
        let metadata = ActrailAlarmMetadata(reminderId: reminderId)
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: metadata,
            tintColor: .blue
        )
        let schedule = Alarm.Schedule.fixed(date)
        return AlarmManager.AlarmConfiguration(
            schedule: schedule,
            attributes: attributes,
            sound: .default
        )
    }

    func scheduleAlarm(id: UUID, date: Date, reminderId: String) async throws {
        let configuration = try await makeConfiguration(date: date, reminderId: reminderId)
        _ = try await alarmManager.schedule(id: id, configuration: configuration)
        DiagnosticLog.append(tag: "AlarmKitAPI", message: "scheduleAlarm 成功 id=\(id.uuidString.prefix(8)) date=\(date)")
    }

    func cancelAlarm(id: UUID) {
        DiagnosticLog.append(tag: "AlarmKitAPI", message: "cancelAlarm \(id.uuidString.prefix(8))")
        try? alarmManager.cancel(id: id)
    }

    func stopAlarm(id: UUID) {
        DiagnosticLog.append(tag: "AlarmKitAPI", message: "stopAlarm \(id.uuidString.prefix(8))")
        try? alarmManager.stop(id: id)
    }
}
