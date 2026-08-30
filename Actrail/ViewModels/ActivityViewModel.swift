import Foundation
import SwiftData
import SwiftUI
import UserNotifications
import CoreHaptics
import AudioToolbox

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onNotificationFired: ((UNNotification) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
        onNotificationFired?(notification)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

@Observable
class ActivityViewModel {
    var activityTypes: [ActivityType] = []
    var activeRecords: [ActivityRecord] = []
    var todayRecords: [ActivityRecord] = []
    var reminders: [ActivityReminder] = []
    var selectedDate: Date = Date()
    var isWatchReachable = false

    var activeVibrationAlert: VibrationAlert?

    private var modelContext: ModelContext?
    private let syncManager = WatchSyncManager.shared
    private var syncTimer: Timer?
    private let notificationDelegate = NotificationDelegate()
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticAdvancedPatternPlayer?

    private var cachedTypes: [WatchSyncManager.SyncedActivityType] = []
    private var cachedActiveRecords: [WatchSyncManager.SyncedActivityRecord] = []
    private var cachedCompletedRecords: [WatchSyncManager.SyncedActivityRecord] = []

    struct VibrationAlert: Identifiable {
        let id = UUID()
        let reminder: ActivityReminder
        let activityName: String
        let reminderType: ReminderType
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchActivityTypes()
        fetchTodayRecords()
        fetchReminders()

        if activityTypes.isEmpty {
            insertSampleData()
            fetchActivityTypes()
        }

        setupSyncManager()
        setupNotificationObservers()
        setupHapticEngine()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rebuildCache()
            self?.sendSync()
        }
    }

    func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        center.requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert]) { [weak self] granted, _ in
            if granted {
                DispatchQueue.main.async {
                    self?.rescheduleAllReminders()
                }
            }
        }

        notificationDelegate.onNotificationFired = { [weak self] notification in
            self?.handleNotificationFired(notification)
        }
    }

    private func setupHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
        } catch {
            print("Haptic engine failed: \(error)")
        }
    }

    private func handleNotificationFired(_ notification: UNNotification) {
        let identifier = notification.request.identifier
        guard let reminder = reminders.first(where: { $0.id.uuidString == identifier }) else { return }

        if reminder.reminderType == .vibration || reminder.reminderType == .vibrationWithLongPress {
            startContinuousVibration()
            activeVibrationAlert = VibrationAlert(
                reminder: reminder,
                activityName: reminder.activityType?.name ?? "未知活动",
                reminderType: reminder.reminderType
            )
        }
    }

    func startContinuousVibration() {
        guard let engine = hapticEngine else {
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            return
        }

        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ], relativeTime: 0, duration: 30)
            ], parameters: [])

            hapticPlayer = try engine.makeAdvancedPlayer(with: pattern)
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        }
    }

    func stopVibration() {
        do {
            try hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        } catch {}
        hapticPlayer = nil
        activeVibrationAlert = nil
    }

    private func rescheduleAllReminders() {
        for reminder in reminders {
            if reminder.isEnabled {
                scheduleNotification(for: reminder)
            }
        }
    }

    private func setupSyncManager() {
        syncManager.startActivityUpdateHandler { [weak self] types, records in
            Task { @MainActor in
                self?.handleSyncFromWatch(types: types, records: records)
            }
        }

        syncManager.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor in
                self?.isWatchReachable = reachable
            }
        }

        isWatchReachable = syncManager.isReachable

        syncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rebuildCache()
                self.sendSync()
            }
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: .watchRequestedData, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildCache()
                self?.sendSync()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .watchDidBecomeReachable, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildCache()
                self?.sendSync()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .watchActivityAction, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleWatchAction(notification: notification)
            }
        }
    }

    // MARK: - Cache

    private func rebuildCache() {
        cachedTypes = activityTypes.compactMap { type in
            WatchSyncManager.SyncedActivityType(
                id: type.id,
                name: type.name,
                iconName: type.iconName,
                color: type.color,
                group: type.group
            )
        }

        cachedActiveRecords = activeRecords.compactMap { record in
            guard let type = record.activityType else { return nil }
            return WatchSyncManager.SyncedActivityRecord(
                id: record.id,
                activityTypeId: type.id,
                startTime: record.startTime,
                endTime: record.endTime,
                isActive: record.isActive,
                note: record.note
            )
        }

        cachedCompletedRecords = todayRecords
            .filter { !$0.isActive }
            .prefix(50)
            .compactMap { record -> WatchSyncManager.SyncedActivityRecord? in
                guard let type = record.activityType else { return nil }
                return WatchSyncManager.SyncedActivityRecord(
                    id: record.id,
                    activityTypeId: type.id,
                    startTime: record.startTime,
                    endTime: record.endTime,
                    isActive: record.isActive,
                    note: record.note
                )
            }
    }

    private func sendSync() {
        syncManager.sendActivityUpdate(
            types: cachedTypes,
            activeRecords: cachedActiveRecords,
            completedRecords: cachedCompletedRecords
        )
    }

    // MARK: - Handle data received from Watch

    private func handleSyncFromWatch(types: [WatchSyncManager.SyncedActivityType], records: [WatchSyncManager.SyncedActivityRecord]) {
        guard let context = modelContext else { return }

        for syncRecord in records where syncRecord.isActive {
            if !activeRecords.contains(where: { $0.id == syncRecord.id }) {
                if let type = activityTypes.first(where: { $0.id == syncRecord.activityTypeId }) {
                    let newRecord = ActivityRecord(
                        activityType: type,
                        startTime: syncRecord.startTime
                    )
                    newRecord.id = syncRecord.id
                    context.insert(newRecord)
                    try? context.save()
                    activeRecords.append(newRecord)
                    todayRecords.insert(newRecord, at: 0)
                }
            }
        }
        rebuildCache()
    }

    // MARK: - Handle Watch actions (start/stop)

    private func handleWatchAction(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let action = userInfo["action"] as? String else { return }

        switch action {
        case "startActivity":
            if let typeIdString = userInfo["typeId"] as? String,
               let typeId = UUID(uuidString: typeIdString),
               let type = activityTypes.first(where: { $0.id == typeId }) {
                if !activeRecords.contains(where: { $0.activityType?.id == type.id && $0.isActive }) {
                    startActivity(type)
                }
            }
        case "stopActivity":
            if let recordIdString = userInfo["recordId"] as? String,
               let recordId = UUID(uuidString: recordIdString),
               let record = activeRecords.first(where: { $0.id == recordId }) {
                stopActivity(record)
            }
        default:
            break
        }
    }

    // MARK: - Data operations

    func fetchActivityTypes() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ActivityType>(sortBy: [SortDescriptor(\.createdAt)])
        do {
            activityTypes = try context.fetch(descriptor)
        } catch {
            print("Failed to fetch activity types: \(error)")
        }
    }

    func fetchTodayRecords() {
        guard let context = modelContext else { return }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = #Predicate<ActivityRecord> { record in
            record.startTime >= startOfDay && record.startTime < endOfDay
        }
        let descriptor = FetchDescriptor<ActivityRecord>(predicate: predicate, sortBy: [SortDescriptor(\.startTime, order: .reverse)])

        do {
            todayRecords = try context.fetch(descriptor)
            activeRecords = todayRecords.filter { $0.isActive }
        } catch {
            print("Failed to fetch today records: \(error)")
        }
    }

    func startActivity(_ type: ActivityType) {
        guard let context = modelContext else { return }

        if activeRecords.contains(where: { $0.activityType?.id == type.id && $0.isActive }) {
            return
        }

        let record = ActivityRecord(activityType: type)
        context.insert(record)
        activeRecords.append(record)
        todayRecords.insert(record, at: 0)

        do {
            try context.save()
            rebuildCache()
            sendSync()
        } catch {
            print("Failed to save activity record: \(error)")
        }
    }

    func stopActivity(_ record: ActivityRecord) {
        guard let context = modelContext else { return }
        record.stop()

        activeRecords.removeAll { $0.id == record.id }

        do {
            try context.save()
            rebuildCache()
            sendSync()
        } catch {
            print("Failed to save activity record: \(error)")
        }
    }

    func deleteRecord(_ record: ActivityRecord) {
        guard let context = modelContext else { return }
        context.delete(record)

        activeRecords.removeAll { $0.id == record.id }
        todayRecords.removeAll { $0.id == record.id }

        do {
            try context.save()
            rebuildCache()
            sendSync()
        } catch {
            print("Failed to delete activity record: \(error)")
        }
    }

    func addActivityType(name: String, iconName: String, color: String, group: String) {
        guard let context = modelContext else { return }
        let type = ActivityType(name: name, iconName: iconName, color: color, group: group)
        context.insert(type)

        do {
            try context.save()
            fetchActivityTypes()
            rebuildCache()
        } catch {
            print("Failed to save activity type: \(error)")
        }
    }

    func deleteActivityType(_ type: ActivityType) {
        guard let context = modelContext else { return }
        context.delete(type)

        do {
            try context.save()
            fetchActivityTypes()
            rebuildCache()
        } catch {
            print("Failed to delete activity type: \(error)")
        }
    }

    // MARK: - Reminders

    func fetchReminders() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ActivityReminder>(sortBy: [SortDescriptor(\.hour), SortDescriptor(\.minute)])
        do {
            reminders = try context.fetch(descriptor)
        } catch {
            print("Failed to fetch reminders: \(error)")
        }
    }

    func addReminder(activityType: ActivityType, hour: Int, minute: Int, reminderType: ReminderType = .notification) {
        guard let context = modelContext else { return }
        let reminder = ActivityReminder(activityType: activityType, hour: hour, minute: minute, reminderType: reminderType)
        context.insert(reminder)

        do {
            try context.save()
            fetchReminders()
            scheduleNotification(for: reminder)

            let content = UNMutableNotificationContent()
            content.title = "行迹"
            content.body = "提醒已设置：\(reminder.timeString) \(activityType.name)"
            content.sound = .default
            let testRequest = UNNotificationRequest(identifier: "test-\(reminder.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(testRequest)
        } catch {
            print("Failed to save reminder: \(error)")
        }
    }

    func deleteReminder(_ reminder: ActivityReminder) {
        guard let context = modelContext else { return }
        cancelNotification(for: reminder)
        context.delete(reminder)

        do {
            try context.save()
            fetchReminders()
        } catch {
            print("Failed to delete reminder: \(error)")
        }
    }

    func toggleReminder(_ reminder: ActivityReminder) {
        guard let context = modelContext else { return }
        reminder.isEnabled.toggle()

        do {
            try context.save()
            if reminder.isEnabled {
                scheduleNotification(for: reminder)
            } else {
                cancelNotification(for: reminder)
            }
        } catch {
            print("Failed to toggle reminder: \(error)")
        }
    }

    private func scheduleNotification(for reminder: ActivityReminder) {
        guard reminder.isEnabled, let type = reminder.activityType else { return }

        let content = UNMutableNotificationContent()
        content.title = "行迹提醒"
        content.body = "该开始\(type.name)了"
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = "ACTIVITY_REMINDER"

        switch reminder.reminderType {
        case .notification:
            content.sound = .default
        case .vibration, .vibrationWithLongPress:
            content.sound = UNNotificationSound.defaultCritical
        }

        let calendar = Calendar.current
        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.hour = reminder.hour
        dateComponents.minute = reminder.minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Reminder] schedule failed: \(error)")
            }
        }
    }

    private func cancelNotification(for reminder: ActivityReminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.id.uuidString])
    }

    // MARK: - Formatting

    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    func getTotalDurationForType(_ type: ActivityType, date: Date = Date()) -> TimeInterval {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return todayRecords
            .filter { $0.activityType?.id == type.id && !$0.isActive }
            .filter { $0.startTime >= startOfDay && $0.startTime < endOfDay }
            .reduce(0) { $0 + $1.duration }
    }

    private func insertSampleData() {
        guard let context = modelContext else { return }

        let sampleTypes = [
            ActivityType(name: "工作", iconName: "briefcase.fill", color: "#007AFF", group: "工作"),
            ActivityType(name: "运动", iconName: "figure.run", color: "#34C759", group: "健康"),
            ActivityType(name: "阅读", iconName: "book.fill", color: "#FF9500", group: "学习"),
            ActivityType(name: "睡眠", iconName: "moon.fill", color: "#5856D6", group: "健康"),
            ActivityType(name: "用餐", iconName: "fork.knife", color: "#FF2D55", group: "生活"),
            ActivityType(name: "通勤", iconName: "car.fill", color: "#8E8E93", group: "生活")
        ]

        for type in sampleTypes {
            context.insert(type)
        }

        do {
            try context.save()
        } catch {
            print("Failed to save sample data: \(error)")
        }
    }
}
