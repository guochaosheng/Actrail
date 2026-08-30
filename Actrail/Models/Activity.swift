import Foundation
import SwiftData

enum ReminderType: Int, Codable, CaseIterable {
    case notification = 0
    case vibration = 1
    case vibrationWithLongPress = 2

    var displayName: String {
        switch self {
        case .notification: return "通知"
        case .vibration: return "振动"
        case .vibrationWithLongPress: return "振动+长按解锁"
        }
    }

    var iconName: String {
        switch self {
        case .notification: return "bell.fill"
        case .vibration: return "antenna.radiowaves.left.and.right"
        case .vibrationWithLongPress: return "lock.fill"
        }
    }

    static let defaultsKey = "reminderTypes"

    static func save(type: ReminderType, for reminderId: UUID) {
        var dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        dict[reminderId.uuidString] = type.rawValue
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }

    static func load(for reminderId: UUID) -> ReminderType {
        let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        guard let raw = dict[reminderId.uuidString] else { return .notification }
        return ReminderType(rawValue: raw) ?? .notification
    }

    static func remove(for reminderId: UUID) {
        var dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        dict.removeValue(forKey: reminderId.uuidString)
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }
}

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

@Model
final class ActivityReminder {
    var id: UUID
    var activityType: ActivityType?
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var repeatDays: [Int]
    var createdAt: Date

    init(activityType: ActivityType, hour: Int, minute: Int, repeatDays: [Int] = [1,2,3,4,5,6,7]) {
        self.id = UUID()
        self.activityType = activityType
        self.hour = hour
        self.minute = minute
        self.isEnabled = true
        self.repeatDays = repeatDays
        self.createdAt = Date()
    }

    var timeString: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
