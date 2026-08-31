import Foundation
import SwiftData
import SwiftUI
import UserNotifications
import CoreHaptics
import AudioToolbox
import UIKit

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onNotificationFiredForeground: ((UNNotification) -> Void)?
    var onNotificationOpened: ((UNNotificationResponse) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound, .list])
        let n = notification
        DispatchQueue.main.async { [weak self] in
            self?.onNotificationFiredForeground?(n)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let resp = response
        DispatchQueue.main.async { [weak self] in
            self?.onNotificationOpened?(resp)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
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
    private var isAppReady = false

    private var cachedTypes: [WatchSyncManager.SyncedActivityType] = []
    private var cachedActiveRecords: [WatchSyncManager.SyncedActivityRecord] = []
    private var cachedCompletedRecords: [WatchSyncManager.SyncedActivityRecord] = []

    private var safeTypeValues: [(id: UUID, name: String, iconName: String, color: String, group: String)] = []
    private var safeRecordValues: [(id: UUID, activityTypeId: UUID, startTime: Date, endTime: Date?, isActive: Bool, note: String)] = []

    struct VibrationAlert: Identifiable {
        let id = UUID()
        let reminder: ActivityReminder
        let activityName: String
        let reminderType: ReminderType
        let notificationIdentifier: String
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rebuildCache()
            self?.sendSync()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isAppReady = true
        }
    }

    func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, _ in
            if granted {
                DispatchQueue.main.async {
                    self?.rescheduleAllReminders()
                }
            }
        }

        notificationDelegate.onNotificationFiredForeground = { [weak self] notification in
            DispatchQueue.main.async {
                self?.handleNotificationFired(notification)
            }
        }

        notificationDelegate.onNotificationOpened = { [weak self] response in
            DispatchQueue.main.async {
                self?.handleNotificationOpened(response)
            }
        }

        if #available(iOS 26.0, *) {
            Task {
                let authorized = await AlarmKitManager.shared.ensureAuthorized()
                print("[ViewModel] AlarmKit authorization: \(authorized)")
            }
        }
    }

    private func cleanNotificationIdentifier(_ raw: String) -> String {
        var id = raw.replacingOccurrences(of: "-repeat", with: "")
        if let dashRange = id.range(of: "-r"), id[dashRange.upperBound...].allSatisfy(\.isNumber) {
            id = String(id[id.startIndex..<dashRange.lowerBound])
        }
        return id
    }

    private func handleNotificationFired(_ notification: UNNotification) {
        guard isAppReady else { return }
        let identifier = cleanNotificationIdentifier(notification.request.identifier)
        let userInfo = notification.request.content.userInfo

        if let reminderTypeRaw = userInfo["reminderType"] as? Int,
           let reminderType = ReminderType(rawValue: reminderTypeRaw) {
            let activityName = userInfo["activityName"] as? String ?? "活动"
            startContinuousVibration()
            activeVibrationAlert = VibrationAlert(
                reminder: ActivityReminder(activityTypeId: UUID(), activityName: activityName, activityIconName: "bell.fill", activityColor: "#FF3B30", hour: 0, minute: 0),
                activityName: activityName,
                reminderType: reminderType,
                notificationIdentifier: identifier
            )
            return
        }

        guard let reminder = reminders.first(where: { $0.id.uuidString == identifier }) else { return }
        let reminderType = ReminderType.load(for: reminder.id)
        if reminderType == .vibration || reminderType == .vibrationWithLongPress {
            startContinuousVibration()
            activeVibrationAlert = VibrationAlert(
                reminder: reminder,
                activityName: reminder.activityName,
                reminderType: reminderType,
                notificationIdentifier: identifier
            )
        }
    }

    private func handleNotificationOpened(_ response: UNNotificationResponse) {
        guard isAppReady else { return }
        let identifier = cleanNotificationIdentifier(response.notification.request.identifier)
        let userInfo = response.notification.request.content.userInfo

        if let reminderTypeRaw = userInfo["reminderType"] as? Int,
           let reminderType = ReminderType(rawValue: reminderTypeRaw) {
            let activityName = userInfo["activityName"] as? String ?? "活动"
            startContinuousVibration()
            activeVibrationAlert = VibrationAlert(
                reminder: ActivityReminder(activityTypeId: UUID(), activityName: activityName, activityIconName: "bell.fill", activityColor: "#FF3B30", hour: 0, minute: 0),
                activityName: activityName,
                reminderType: reminderType,
                notificationIdentifier: identifier
            )
            return
        }

        guard let reminder = reminders.first(where: { $0.id.uuidString == identifier }) else { return }
        let reminderType = ReminderType.load(for: reminder.id)
        if reminderType == .vibration || reminderType == .vibrationWithLongPress {
            startContinuousVibration()
            activeVibrationAlert = VibrationAlert(
                reminder: reminder,
                activityName: reminder.activityName,
                reminderType: reminderType,
                notificationIdentifier: identifier
            )
        }
    }

    func startContinuousVibration() {
        stopHapticsOnly()

        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            do {
                let engine = try CHHapticEngine()
                try engine.start()

                engine.stoppedHandler = { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.startSystemVibrationLoop()
                    }
                }

                let pattern = try CHHapticPattern(events: [
                    CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ], relativeTime: 0, duration: 60)
                ], parameters: [])

                let player = try engine.makeAdvancedPlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                hapticPlayer = player
                hapticEngine = engine
            } catch {
                startSystemVibrationLoop()
            }
        } else {
            startSystemVibrationLoop()
        }
    }

    private var vibrationTimer: Timer?

    private func startSystemVibrationLoop() {
        vibrationTimer?.invalidate()
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        }
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
    }

    private func stopHapticsOnly() {
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        if let player = hapticPlayer {
            try? player.stop(atTime: CHHapticTimeImmediate)
            hapticPlayer = nil
        }
        if let engine = hapticEngine {
            try? engine.stop()
            hapticEngine = nil
        }
    }

    func stopVibration() {
        stopHapticsOnly()
        if let alert = activeVibrationAlert {
            var identifiers = [alert.notificationIdentifier]
            for i in 1...10 {
                identifiers.append("\(alert.notificationIdentifier)-r\(i)")
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.syncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.modelContext != nil else { return }
                    self.rebuildCache()
                    self.sendSync()
                }
            }
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: .watchRequestedData, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.isAppReady == true else { return }
                self?.rebuildCache()
                self?.sendSync()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .watchDidBecomeReachable, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.isAppReady == true else { return }
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
        cachedTypes = safeTypeValues.map { v in
            WatchSyncManager.SyncedActivityType(id: v.id, name: v.name, iconName: v.iconName, color: v.color, group: v.group)
        }

        cachedActiveRecords = safeRecordValues.filter { $0.isActive }.map { v in
            WatchSyncManager.SyncedActivityRecord(id: v.id, activityTypeId: v.activityTypeId, startTime: v.startTime, endTime: v.endTime, isActive: v.isActive, note: v.note)
        }

        cachedCompletedRecords = safeRecordValues.filter { !$0.isActive }.prefix(50).map { v in
            WatchSyncManager.SyncedActivityRecord(id: v.id, activityTypeId: v.activityTypeId, startTime: v.startTime, endTime: v.endTime, isActive: v.isActive, note: v.note)
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
                    if let typeId = newRecord.activityType?.id {
                        safeRecordValues.append((id: newRecord.id, activityTypeId: typeId, startTime: newRecord.startTime, endTime: newRecord.endTime, isActive: newRecord.isActive, note: newRecord.note))
                    }
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
            let fetched = try context.fetch(descriptor)
            activityTypes = fetched
            safeTypeValues = fetched.compactMap { type in
                (id: type.id, name: type.name, iconName: type.iconName, color: type.color, group: type.group)
            }
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
            let fetched = try context.fetch(descriptor)
            todayRecords = fetched
            activeRecords = fetched.filter { $0.isActive }
            safeRecordValues = fetched.compactMap { record in
                guard let typeId = record.activityType?.id else { return nil }
                return (id: record.id, activityTypeId: typeId, startTime: record.startTime, endTime: record.endTime, isActive: record.isActive, note: record.note)
            }
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
            if let typeId = record.activityType?.id {
                safeRecordValues.append((id: record.id, activityTypeId: typeId, startTime: record.startTime, endTime: record.endTime, isActive: record.isActive, note: record.note))
            }
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
            if let idx = safeRecordValues.firstIndex(where: { $0.id == record.id }) {
                safeRecordValues[idx] = (id: record.id, activityTypeId: safeRecordValues[idx].activityTypeId, startTime: record.startTime, endTime: record.endTime, isActive: false, note: record.note)
            }
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
            safeRecordValues.removeAll { $0.id == record.id }
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
        reminders = ActivityReminder.loadAll()
    }

    func addReminder(activityTypeId: UUID, activityName: String, activityIconName: String, activityColor: String, hour: Int, minute: Int, reminderType: ReminderType = .notification) {
        let reminder = ActivityReminder(
            activityTypeId: activityTypeId,
            activityName: activityName,
            activityIconName: activityIconName,
            activityColor: activityColor,
            hour: hour,
            minute: minute
        )
        reminders.append(reminder)
        ActivityReminder.saveAll(reminders)
        ReminderType.save(type: reminderType, for: reminder.id)
        
        if reminderType == .vibration || reminderType == .vibrationWithLongPress {
            scheduleAlarmKitAlarm(for: reminder, reminderType: reminderType)
        } else {
            scheduleNotification(for: reminder)
        }
    }
    
    private func scheduleAlarmKitAlarm(for reminder: ActivityReminder, reminderType: ReminderType) {
        scheduleNotification(for: reminder)
        
        guard #available(iOS 26.0, *) else {
            print("[AlarmKit] iOS < 26, notification-only mode")
            return
        }
        
        print("[AlarmKit] Also attempting AlarmKit schedule...")
        let manager = AlarmKitManager.shared
        
        Task {
            let authorized = await manager.ensureAuthorized()
            guard authorized else {
                print("[AlarmKit] Not authorized, using notification-only")
                return
            }
            
            do {
                try await manager.scheduleAlarm(
                    id: reminder.id,
                    hour: reminder.hour,
                    minute: reminder.minute,
                    activityName: reminder.activityName,
                    activityIconName: reminder.activityIconName,
                    activityColor: reminder.activityColor,
                    reminderId: reminder.id.uuidString
                )
                print("[AlarmKit] Daily alarm scheduled!")
            } catch {
                print("[AlarmKit] Schedule failed (notification still active): \(error)")
            }
        }
    }

    func deleteReminder(_ reminder: ActivityReminder) {
        cancelNotification(for: reminder)
        cancelAlarmKitAlarm(for: reminder)
        ReminderType.remove(for: reminder.id)
        reminders.removeAll { $0.id == reminder.id }
        ActivityReminder.saveAll(reminders)
    }
    
    private func cancelAlarmKitAlarm(for reminder: ActivityReminder) {
        guard #available(iOS 26.0, *) else { return }
        
        Task { @MainActor in
            do {
                try await AlarmKitManager.shared.cancelAlarm(id: reminder.id)
            } catch {
                print("[AlarmKit] Failed to cancel alarm: \(error)")
            }
        }
    }

    func toggleReminder(_ reminder: ActivityReminder) {
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index].isEnabled.toggle()
            ActivityReminder.saveAll(reminders)
            if reminders[index].isEnabled {
                let reminderType = ReminderType.load(for: reminder.id)
                if reminderType == .vibration || reminderType == .vibrationWithLongPress {
                    scheduleAlarmKitAlarm(for: reminders[index], reminderType: reminderType)
                } else {
                    scheduleNotification(for: reminders[index])
                }
            } else {
                cancelNotification(for: reminder)
                cancelAlarmKitAlarm(for: reminder)
            }
        }
    }

    private func scheduleNotification(for reminder: ActivityReminder) {
        guard reminder.isEnabled else { return }
        let reminderType = ReminderType.load(for: reminder.id)

        let content = UNMutableNotificationContent()
        content.title = "行迹提醒"
        content.body = "该开始\(reminder.activityName)了"
        content.categoryIdentifier = "ACTIVITY_REMINDER"
        content.userInfo = ["reminderId": reminder.id.uuidString]

        let calendar = Calendar.current
        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.hour = reminder.hour
        dateComponents.minute = reminder.minute

        switch reminderType {
        case .notification:
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("[Reminder] schedule failed: \(error)")
                }
            }

        case .vibration, .vibrationWithLongPress:
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo["isRepeating"] = true
            content.userInfo["reminderType"] = reminderType.rawValue
            content.userInfo["activityName"] = reminder.activityName

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("[Reminder] vibration schedule failed: \(error)")
                }
            }

            var fireDate = calendar.date(from: dateComponents) ?? Date()
            if fireDate <= Date() {
                fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
            }

            let vibrationMessages = [
                "该开始\(reminder.activityName)了！",
                "⏰ \(reminder.activityName)时间到！",
                "别忘了\(reminder.activityName)哦！",
                "\(reminder.activityName)提醒 - 请开始吧！",
                "还有\(reminder.activityName)没完成呢！",
                "重要提醒：\(reminder.activityName)",
                "\(reminder.activityName)时间到了！",
                "请立即开始\(reminder.activityName)！"
            ]

            for i in 1...10 {
                let repeatContent = UNMutableNotificationContent()
                repeatContent.title = "行迹提醒"
                repeatContent.body = vibrationMessages[(i - 1) % vibrationMessages.count]
                repeatContent.sound = .default
                repeatContent.interruptionLevel = .timeSensitive
                repeatContent.badge = 1
                repeatContent.userInfo = [
                    "reminderId": reminder.id.uuidString,
                    "isRepeating": true,
                    "reminderType": reminderType.rawValue,
                    "activityName": reminder.activityName,
                    "repeatIndex": i
                ]
                let repeatDate = fireDate.addingTimeInterval(TimeInterval(i * 3))
                let interval = repeatDate.timeIntervalSinceNow
                guard interval > 0 else { continue }
                let repeatTrigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                let repeatRequest = UNNotificationRequest(identifier: "\(reminder.id.uuidString)-r\(i)", content: repeatContent, trigger: repeatTrigger)
                UNUserNotificationCenter.current().add(repeatRequest) { error in
                    if let error = error {
                        print("[Reminder] repeat-\(i) schedule failed: \(error)")
                    }
                }
            }
        }
    }

    private func cancelNotification(for reminder: ActivityReminder) {
        var identifiers = [reminder.id.uuidString]
        for i in 1...10 {
            identifiers.append("\(reminder.id.uuidString)-r\(i)")
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
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
            fetchActivityTypes()
        } catch {
            print("Failed to save sample data: \(error)")
        }
    }
}
