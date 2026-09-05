import Foundation
import SwiftData

@Model
final class ActivityType {
    var id: UUID
    var name: String
    var iconName: String
    var color: String
    var group: String
    var createdAt: Date
    var isArchived: Bool
    
    init(name: String, iconName: String, color: String, group: String = "默认") {
        self.id = UUID()
        self.name = name
        self.iconName = iconName
        self.color = color
        self.group = group
        self.createdAt = Date()
        self.isArchived = false
    }
}

@Model
final class ActivityRecord {
    var id: UUID
    var activityType: ActivityType?
    var startTime: Date
    var endTime: Date?
    var note: String
    var isActive: Bool
    var duration: TimeInterval {
        guard let endTime = endTime else {
            return Date().timeIntervalSince(startTime)
        }
        return endTime.timeIntervalSince(startTime)
    }
    
    init(activityType: ActivityType, startTime: Date = Date(), note: String = "") {
        self.id = UUID()
        self.activityType = activityType
        self.startTime = startTime
        self.endTime = nil
        self.note = note
        self.isActive = true
    }
    
    func stop() {
        self.endTime = Date()
        self.isActive = false
    }
    
    func pause() {
        self.endTime = Date()
    }
    
    func resume() {
        self.startTime = Date()
        self.endTime = nil
        self.isActive = true
    }
}

struct ActivityReminder: Codable, Identifiable {
    var id: UUID
    var date: Date
    var isEnabled: Bool
    var createdAt: Date
    var alarmEnabled: Bool
    var alarmGraceMinutes: Int

    init(date: Date, alarmEnabled: Bool = false, alarmGraceMinutes: Int = 5) {
        self.id = UUID()
        self.date = date
        self.isEnabled = true
        self.createdAt = Date()
        self.alarmEnabled = alarmEnabled
        self.alarmGraceMinutes = alarmGraceMinutes
    }

    enum CodingKeys: String, CodingKey {
        case id, date, isEnabled, createdAt
        case alarmEnabled, alarmGraceMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        alarmEnabled = try c.decodeIfPresent(Bool.self, forKey: .alarmEnabled) ?? false
        alarmGraceMinutes = try c.decodeIfPresent(Int.self, forKey: .alarmGraceMinutes) ?? 5

        // 向后兼容：旧格式用 hour/minute，新格式用 date
        if let d = try? c.decode(Date.self, forKey: .date) {
            date = d
        } else {
            // 尝试从旧格式解码 hour/minute
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let h = try legacy.decode(Int.self, forKey: .hour)
            let m = try legacy.decode(Int.self, forKey: .minute)
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.hour = h
            comps.minute = m
            date = Calendar.current.date(from: comps) ?? Date()
        }
    }

    var hour: Int {
        Calendar.current.component(.hour, from: date)
    }

    var minute: Int {
        Calendar.current.component(.minute, from: date)
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: date)
    }

    // 向后兼容 CodingKeys（旧数据含 hour/minute）
    enum LegacyCodingKeys: String, CodingKey {
        case hour, minute
    }

    static let defaultsKey = "activityReminders"

    static func loadAll() -> [ActivityReminder] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let reminders = try? JSONDecoder().decode([ActivityReminder].self, from: data) else {
            return []
        }
        return reminders
    }

    static func saveAll(_ reminders: [ActivityReminder]) {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

struct ReminderLogEntry: Codable, Identifiable {
    var id: UUID
    var content: String
    var presetTime: Date
    var sentTime: Date
    var sentSuccessfully: Bool
    var source: String
    var status: String
    var reminderID: UUID?

    init(content: String, presetTime: Date, sentTime: Date, sentSuccessfully: Bool, source: String, status: String = "", reminderID: UUID? = nil) {
        self.id = UUID()
        self.content = content
        self.presetTime = presetTime
        self.sentTime = sentTime
        self.sentSuccessfully = sentSuccessfully
        self.source = source
        self.status = status
        self.reminderID = reminderID
    }

    enum CodingKeys: String, CodingKey {
        case id, content, presetTime, sentTime, sentSuccessfully, source
        case status, reminderID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        presetTime = try c.decode(Date.self, forKey: .presetTime)
        sentTime = try c.decode(Date.self, forKey: .sentTime)
        sentSuccessfully = try c.decode(Bool.self, forKey: .sentSuccessfully)
        source = try c.decode(String.self, forKey: .source)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        reminderID = try c.decodeIfPresent(UUID.self, forKey: .reminderID)
    }

    static let defaultsKey = "reminderLogs"

    static func loadAll() -> [ReminderLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let logs = try? JSONDecoder().decode([ReminderLogEntry].self, from: data) else {
            return []
        }
        return logs
    }

    static func saveAll(_ logs: [ReminderLogEntry]) {
        if let data = try? JSONEncoder().encode(logs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
