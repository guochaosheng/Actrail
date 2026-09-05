import Foundation
import SwiftData
import SwiftUI
import UserNotifications

class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onTriggered: ((UNNotification) -> Void)?
    var onTapped: ((UNNotificationResponse) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let n = notification
        DispatchQueue.main.async { [weak self] in
            self?.onTriggered?(n)
        }
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let resp = response
        DispatchQueue.main.async { [weak self] in
            self?.onTapped?(resp)
        }
        completionHandler()
    }
}

@Observable
class ActivityViewModel {
    var activityTypes: [ActivityType] = []
    var activeRecords: [ActivityRecord] = []
    var todayRecords: [ActivityRecord] = []
    var reminders: [ActivityReminder] = []
    var reminderLogs: [ReminderLogEntry] = []
    var selectedDate: Date = Date()
    var isWatchReachable = false
    var watchStatusString = "尚未查询"

    private var modelContext: ModelContext?
    private let syncManager = WatchSyncManager.shared
    private var syncTimer: Timer?
    private var isAppReady = false
    private let reminderDelegate = ReminderNotificationDelegate()

    private var cachedTypes: [WatchSyncManager.SyncedActivityType] = []
    private var cachedActiveRecords: [WatchSyncManager.SyncedActivityRecord] = []
    private var cachedCompletedRecords: [WatchSyncManager.SyncedActivityRecord] = []
    private var cachedReminders: [WatchSyncManager.SyncedReminder] = []

    private var safeTypeValues: [(id: UUID, name: String, iconName: String, color: String, group: String)] = []
    private var safeRecordValues: [(id: UUID, activityTypeId: UUID, startTime: Date, endTime: Date?, isActive: Bool, note: String)] = []
    private var lastStartActivityDate: Date = .distantPast

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

        syncManager.onReminderLogReceived = { [weak self] log in
            Task { @MainActor in
                self?.appendReminderLog(log)
            }
        }

        syncManager.onWatchStatusReceived = { [weak self] status in
            Task { @MainActor in
                self?.presentWatchStatus(status)
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
                    self.cancelExpiredAlarms()
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

        cachedReminders = reminders.filter(\.isEnabled).map { reminder in
            WatchSyncManager.SyncedReminder(
                id: reminder.id,
                date: reminder.date
            )
        }
    }

    private func sendSync() {
        syncManager.sendActivityUpdate(
            types: cachedTypes,
            activeRecords: cachedActiveRecords,
            completedRecords: cachedCompletedRecords,
            reminders: cachedReminders
        )
    }

    // MARK: - Handle data received from Watch

private func handleSyncFromWatch(types: [WatchSyncManager.SyncedActivityType], records: [WatchSyncManager.SyncedActivityRecord]) {
        // iPhone 是记录的唯一数据源。Watch 端开始/停止活动通过 action 消息到达，
        // 由 handleWatchAction 创建/停止记录。这里只做内存展示层面的对账，
        // 绝不创建新的持久化记录，否则一次过期的反向同步会把所有类型的活动
        // 批量写入（产生“点一个活动，全部类型都出现在正在进行”的幽灵记录）。
        for syncRecord in records where syncRecord.isActive {
            if let existing = activeRecords.first(where: { $0.id == syncRecord.id }), existing.isActive == false {
                existing.isActive = true
                existing.endTime = nil
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

        // 用户点击活动按钮 = 开始工作 = 立即取消闹钟振动
        // 不检查 activeRecords，因为新活动记录尚未创建
        for reminder in reminders where reminder.alarmEnabled {
            DiagnosticLog.append(tag: "AlarmCancel", message: "startActivity 无条件取消闹钟 id=\(reminder.id.uuidString.prefix(8))")
            AlarmKitManager.shared.stopAlarm(id: reminder.id)
            markAlarmCancelled(reminderID: reminder.id)
        }

        if activeRecords.contains(where: { $0.activityType?.id == type.id && $0.isActive }) {
            return
        }

        // 一次用户点击会触发 SwiftUI 对该网格的所有按钮重放（同一瞬间为每个活动类型
        // 各调用一次 startActivity）。用时间窗口合并，只保留第一个，避免点一个活动却
        // 把 6 种类型全部加入“正在进行”。
        let now = Date()
        if now.timeIntervalSince(lastStartActivityDate) < 0.8 {
            return
        }
        lastStartActivityDate = now

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

    func addReminder(date: Date, alarmEnabled: Bool = false, alarmGraceMinutes: Int = 5) {
        let reminder = ActivityReminder(date: date, alarmEnabled: alarmEnabled, alarmGraceMinutes: alarmGraceMinutes)
        reminders.append(reminder)
        ActivityReminder.saveAll(reminders)
        schedulePhoneNotification(for: reminder)
        pushRemindersToWatch()
        logWatchSchedule(date: date)
    }

    func deleteReminder(_ reminder: ActivityReminder) {
        reminders.removeAll { $0.id == reminder.id }
        ActivityReminder.saveAll(reminders)
        cancelPhoneNotification(for: reminder)
        pushRemindersToWatch()
    }

    // MARK: - Watch Reminder

    private func pushRemindersToWatch() {
        rebuildCache()
        sendSync()
    }

    func toggleReminder(_ reminder: ActivityReminder) {
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index].isEnabled.toggle()
            ActivityReminder.saveAll(reminders)
            if reminders[index].isEnabled {
                schedulePhoneNotification(for: reminders[index])
            } else {
                cancelPhoneNotification(for: reminders[index])
            }
            pushRemindersToWatch()
        }
    }

    func testReminderOnWatch() {
        pushRemindersToWatch()
        syncManager.sendReminderTest()
    }

    func rescheduleAllPhoneNotificationsPublic() {
        setupReminderNotifications()
    }

    func requestWatchStatus() {
        watchStatusString = "查询中…"
        syncManager.requestWatchStatus()
    }

    private func presentWatchStatus(_ status: [String: Any]) {
        let pieces = status.sorted { $0.key < $1.key }.map { key, value in
            "\(key): \(value)"
        }
        watchStatusString = pieces.joined(separator: "\n")
    }

    // MARK: - iPhone Local Notifications

    func setupReminderNotifications() {
        reminderLogs = ReminderLogEntry.loadAll()
        let center = UNUserNotificationCenter.current()
        center.delegate = reminderDelegate

        reminderDelegate.onTriggered = { [weak self] notification in
            DispatchQueue.main.async {
                self?.logPhoneNotificationFired(notification)
            }
        }

        reminderDelegate.onTapped = { [weak self] _ in
            DispatchQueue.main.async {
                self?.logPhoneNotificationTapped()
            }
        }

        let centerGet = UNUserNotificationCenter.current()
        centerGet.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self?.rescheduleAllPhoneNotifications()
                case .notDetermined:
                    centerGet.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                        DispatchQueue.main.async {
                            guard granted else { return }
                            self?.rescheduleAllPhoneNotifications()
                        }
                    }
                case .denied:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func logPhoneNotificationFired(_ notification: UNNotification) {
        let contentObject = notification.request.content
        let presetTime = contentObject.userInfo["presetTime"] as? Date ?? Date()
        let content = contentObject.body.isEmpty
            ? contentObject.title
            : contentObject.body
        let entry = ReminderLogEntry(
            content: content,
            presetTime: presetTime,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 本地通知"
        )
        appendReminderLog(entry)
    }

    private func appendReminderLog(_ entry: ReminderLogEntry) {
        if entry.source == "iPhone 计划" || entry.source == "iWatch 计划" {
            let alreadyExists = reminderLogs.contains { existing in
                existing.source == entry.source &&
                existing.content == entry.content &&
                Calendar.current.isDate(existing.presetTime, inSameDayAs: Date())
            }
            if alreadyExists { return }
        }
        reminderLogs.insert(entry, at: 0)
        if reminderLogs.count > 50 {
            reminderLogs = Array(reminderLogs.prefix(50))
        }
        ReminderLogEntry.saveAll(reminderLogs)
    }

    func deleteReminderLog(_ log: ReminderLogEntry) {
        reminderLogs.removeAll { $0.id == log.id }
        ReminderLogEntry.saveAll(reminderLogs)
    }

    func logWatchSchedule(date: Date) {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        let content = "iWatch 排定提醒 \(f.string(from: date))（等待系统投递）"
        let entry = ReminderLogEntry(
            content: content,
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iWatch 计划"
        )
        appendReminderLog(entry)
    }

    private func logPhoneNotificationTapped() {
        let entry = ReminderLogEntry(
            content: "已确认收到提醒",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 已确认"
        )
        appendReminderLog(entry)
    }

    private func rescheduleAllPhoneNotifications() {
        for reminder in reminders where reminder.isEnabled {
            schedulePhoneNotification(for: reminder)
        }
    }

    private func schedulePhoneNotification(for reminder: ActivityReminder) {
        guard reminder.isEnabled else { return }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional ||
                  settings.authorizationStatus == .ephemeral else {
                print("[Reminder] permission not granted, cannot schedule \(reminder.id)")
                return
            }

            // 检查提醒时间是否已过
            guard reminder.date > Date() else {
                print("[Reminder] \(reminder.id) already past, skipping")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "行迹提醒"
            content.body = "请检查当前正在进行的活动是否正确"
            content.sound = .default
            content.userInfo = ["presetTime": reminder.date]

            let dateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.date
            )

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
            let request = UNNotificationRequest(
                identifier: "reminder-\(reminder.id.uuidString)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                guard let self else { return }
                if let error = error {
                    print("[Reminder] schedule failed for \(reminder.id): \(error)")
                } else {
                    let f = DateFormatter()
                    f.dateFormat = "MM/dd HH:mm"
                    print("[Reminder] scheduled \(reminder.id) for \(f.string(from: reminder.date))")
                    let entry = ReminderLogEntry(
                        content: "已安排提醒 \(f.string(from: reminder.date))（等待系统投递）",
                        presetTime: reminder.date,
                        sentTime: Date(),
                        sentSuccessfully: true,
                        source: "iPhone 计划"
                    )
                    DispatchQueue.main.async {
                        self.appendReminderLog(entry)
                        print("[Reminder] alarmEnabled=\(reminder.alarmEnabled), grace=\(reminder.alarmGraceMinutes)min")
                        if reminder.alarmEnabled {
                            DiagnosticLog.append(tag: "AlarmSchedule", message: "alarmEnabled=true → 调用 scheduleAlarm id=\(reminder.id.uuidString.prefix(8))")
                            self.scheduleAlarm(for: reminder)
                        } else {
                            DiagnosticLog.append(tag: "AlarmCancel", message: "alarmEnabled=false → cancelAlarm id=\(reminder.id.uuidString.prefix(8))")
                            AlarmKitManager.shared.cancelAlarm(id: reminder.id)
                        }
                    }
                }
            }
        }
    }

    private func scheduleAlarm(for reminder: ActivityReminder) {
        DiagnosticLog.append(tag: "AlarmSchedule", message: "scheduleAlarm 进入 id=\(reminder.id.uuidString.prefix(8)) enabled=\(reminder.alarmEnabled) grace=\(reminder.alarmGraceMinutes)")
        Task {
            let authed = await AlarmKitManager.shared.ensureAuthorized()
            DiagnosticLog.append(tag: "AlarmSchedule", message: "ensureAuthorized=\(authed)")
            guard authed else {
                DiagnosticLog.append(tag: "AlarmSchedule", message: "未授权，跳过 alarm \(reminder.id.uuidString.prefix(8))")
                return
            }
            let alarmDate = Calendar.current.date(
                byAdding: .minute,
                value: reminder.alarmGraceMinutes,
                to: reminder.date
            ) ?? reminder.date
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm:ss"
            DiagnosticLog.append(tag: "AlarmSchedule", message: "排定闹钟 \(f.string(from: alarmDate)) (reminder=\(f.string(from: reminder.date)), grace=\(reminder.alarmGraceMinutes)min)")
            do {
                try await AlarmKitManager.shared.scheduleAlarm(
                    id: reminder.id,
                    date: alarmDate,
                    reminderId: reminder.id.uuidString
                )
                DiagnosticLog.append(tag: "AlarmSchedule", message: "✓ 闹钟排定成功 id=\(reminder.id.uuidString.prefix(8))")
                appendAlarmPlan(reminder: reminder, alarmDate: alarmDate)
            } catch {
                DiagnosticLog.append(tag: "AlarmSchedule", message: "✗ 排定失败: \(error.localizedDescription)")
                appendReminderLog(ReminderLogEntry(
                    content: "闹钟排定失败（\(error.localizedDescription)）",
                    presetTime: Date(),
                    sentTime: Date(),
                    sentSuccessfully: false,
                    source: "闹钟计划"
                ))
            }
        }
    }

    func stopAlarmIfActiveActivity() {
        cancelExpiredAlarms()
    }

    private func cancelExpiredAlarms() {
        let now = Date()
        for reminder in reminders where reminder.alarmEnabled && reminder.isEnabled {
            if now > reminder.date {
                let alreadyCancelled = reminderLogs.contains {
                    $0.reminderID == reminder.id && $0.status == "已取消"
                }
                if !alreadyCancelled {
                    AlarmKitManager.shared.cancelAlarm(id: reminder.id)
                    markAlarmCancelled(reminderID: reminder.id)
                }
            }
        }
    }

    private func appendAlarmPlan(reminder: ActivityReminder, alarmDate: Date) {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        let content = "闹钟已排定 \(f.string(from: reminder.date)) + \(reminder.alarmGraceMinutes) 分钟 → \(f.string(from: alarmDate))"
        DispatchQueue.main.async {
            self.appendReminderLog(ReminderLogEntry(
                content: content,
                presetTime: Date(),
                sentTime: Date(),
                sentSuccessfully: true,
                source: "闹钟计划",
                status: "计划中",
                reminderID: reminder.id
            ))
        }
    }

    private func markAlarmCancelled(reminderID: UUID) {
        DispatchQueue.main.async {
            if let index = self.reminderLogs.firstIndex(where: {
                $0.reminderID == reminderID && $0.source == "闹钟计划" && $0.status == "计划中"
            }) {
                self.reminderLogs[index].status = "已取消"
                self.reminderLogs[index].sentTime = Date()
                ReminderLogEntry.saveAll(self.reminderLogs)
            } else {
                self.appendReminderLog(ReminderLogEntry(
                    content: "闹钟已停止（打开 App 且存在进行中活动）",
                    presetTime: Date(),
                    sentTime: Date(),
                    sentSuccessfully: true,
                    source: "闹钟已取消",
                    status: "已取消",
                    reminderID: reminderID
                ))
            }
        }
    }

    private func cancelPhoneNotification(for reminder: ActivityReminder) {
        DiagnosticLog.append(tag: "AlarmCancel", message: "cancelPhoneNotification id=\(reminder.id.uuidString.prefix(8))")
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["reminder-\(reminder.id.uuidString)"])
        AlarmKitManager.shared.cancelAlarm(id: reminder.id)
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

        let now = Date()
        for (index, type) in sampleTypes.enumerated() {
            type.createdAt = now.addingTimeInterval(TimeInterval(index))
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
