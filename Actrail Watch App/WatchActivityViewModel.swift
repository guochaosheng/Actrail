import Foundation
import WatchConnectivity
import WatchKit

@Observable
class WatchActivityViewModel {
    var activityTypes: [WatchActivityType] = []
    var activeRecords: [WatchActivityRecord] = []
    var completedRecords: [WatchActivityRecord] = []
    var reminders: [WatchReminder] = []
    var firingReminder: WatchReminder?
    var isReachable = false

    private let syncManager = WatchSyncManager.shared
    private var syncTimer: Timer?
    private var reminderCheckTimer: Timer?
    private var firedReminderKeys: Set<String> = []
    private let notificationDelegate = WatchNotificationDelegate()

    init() {
        setupSyncListener()
        setupReachabilityObserver()
        setupReminderActions()
        setupWatchNotifications()
        requestInitialData()
        startReminderCheck()
    }

    deinit {
        syncTimer?.invalidate()
        reminderCheckTimer?.invalidate()
    }

    private func setupReachabilityObserver() {
        syncManager.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor in
                self?.isReachable = reachable
                if reachable {
                    self?.requestInitialData()
                }
            }
        }
    }

    private func setupReminderActions() {
        syncManager.onReminderTest = { [weak self] in
            Task { @MainActor in
                self?.fireTestReminder()
            }
        }
        syncManager.onQueryWatchStatus = { [weak self] in
            Task { @MainActor in
                self?.reportWatchStatusToiPhone()
            }
        }
    }

    func reportWatchStatusToiPhone() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            center.getPendingNotificationRequests { requests in
                let reminderRequests = requests.filter { $0.identifier.hasPrefix("reminder-") }
                let pending = reminderRequests.count
                let total = requests.count
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                var scheduleLines: [String] = []
                for r in reminderRequests.sorted(by: { a, b in
                    let da = (a.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                    let db = (b.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                    return da < db
                }) {
                    let next = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                    let short = r.identifier.replacingOccurrences(of: "reminder-", with: "").prefix(4)
                    if let next {
                        scheduleLines.append("  \(short): 下次 \(formatter.string(from: next))")
                    }
                }
                let status: [String: Any] = [
                    "授权": self?.authString(settings.authorizationStatus) ?? "unknown",
                    "手表提醒数": self?.reminders.count ?? 0,
                    "待处理提醒通知": pending,
                    "待处理通知总数": total,
                    "可达": self?.syncManager.isReachable ?? false,
                    "下次触发": scheduleLines.joined(separator: "\n")
                ]
                self?.syncManager.sendWatchStatus(status)
            }
        }
    }

    private func authString(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    func fireTestReminder() {
        if let reminder = reminders.first(where: { $0.isEnabled }) {
            fireReminder(reminder)
        }
        scheduleWatchTestNotification()
    }

    private func requestInitialData() {
        syncManager.requestDataFromiPhone()
        startPeriodicSync()
    }

    private func startPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncManager.requestDataFromiPhone()
            }
        }
    }

    private func startReminderCheck() {
        reminderCheckTimer?.invalidate()
        reminderCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDueReminders()
            }
        }
    }

    private func checkDueReminders() {
        guard firingReminder == nil else { return }
        let now = Date()
        let dayKey = Calendar.current.startOfDay(for: now).timeIntervalSince1970

        for reminder in reminders where reminder.isEnabled {
            // 比较日期是否相同（年月日时分）
            let reminderKey = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.date
            )
            let nowKey = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: now
            )
            if reminderKey == nowKey {
                let key = "\(dayKey)-\(reminder.id.uuidString)"
                guard !firedReminderKeys.contains(key) else { continue }
                firedReminderKeys.insert(key)
                fireReminder(reminder)
                return
            }
        }
    }

    private func fireReminder(_ reminder: WatchReminder) {
        firingReminder = reminder
        WKInterfaceDevice.current().play(.notification)
    }

    func unlockReminder() {
        guard let reminder = firingReminder else { return }
        firingReminder = nil
        _ = reminder
    }

    // MARK: - Watch Local Notifications

    private func setupWatchNotifications() {
        notificationDelegate.onTriggered = { [weak self] _ in
            Task { @MainActor in
                self?.logWatchReminder(sentSuccessfully: true, source: "iWatch 本地通知")
            }
        }
        notificationDelegate.onTapped = { [weak self] _ in
            Task { @MainActor in
                self?.logWatchConfirmed()
            }
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, let self else { return }
            Task { @MainActor in
                self.rescheduleWatchNotifications()
            }
        }
    }

    private func remindersEquivalent(_ new: [WatchReminder]) -> Bool {
        guard new.count == reminders.count else { return false }
        let oldSet = Set(reminders.map { "\($0.id)-\($0.date.timeIntervalSince1970)" })
        let newSet = Set(new.map { "\($0.id)-\($0.date.timeIntervalSince1970)" })
        return oldSet == newSet
    }

    private func rescheduleWatchNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let calendar = Calendar.current
        for reminder in reminders {
            // 检查提醒时间是否已过
            guard reminder.date > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "行迹提醒"
            content.body = "请检查当前正在进行的活动是否正确"
            content.sound = .default
            content.userInfo = ["presetTime": reminder.date]

            let dateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.date
            )

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
            let request = UNNotificationRequest(
                identifier: "reminder-\(reminder.id.uuidString)",
                content: content,
                trigger: trigger
            )
            center.add(request) { [weak self] error in
                let ok = error == nil
                let f = DateFormatter()
                f.dateFormat = "MM/dd HH:mm"
                let entry = WatchSyncManager.WatchReminderLogEntry(
                    content: "iWatch 排定提醒 \(f.string(from: reminder.date))（等待系统投递）",
                    presetTime: Date(),
                    sentTime: Date(),
                    sentSuccessfully: ok,
                    source: ok ? "iWatch 计划" : "iWatch 排定失败"
                )
                if ok {
                    self?.syncManager.sendReminderLog(entry)
                }
            }
        }
    }

    /// Schedules a debug local notification 10 seconds from now to verify the watch
    /// notification pipeline works independently of the iPhone.
    func scheduleWatchTestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                print("[Watch] notification authorization denied")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "行迹提醒"
            content.body = "这是手表本地通知测试（10秒后）"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
            let request = UNNotificationRequest(
                identifier: "watch-test-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("[Watch] test notification schedule failed: \(error)")
                } else {
                    print("[Watch] test notification scheduled")
                }
            }
        }
    }

    private func updateFiredKeys() {
        let now = Date()
        let dayKey = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        for reminder in reminders where reminder.isEnabled {
            let reminderKey = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.date
            )
            let nowKey = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: now
            )
            if reminderKey == nowKey {
                let key = "\(dayKey)-\(reminder.id.uuidString)"
                firedReminderKeys.insert(key)
            }
        }
    }

    private func setupSyncListener() {
        syncManager.onDataUpdate = { [weak self] data in
            Task { @MainActor in
                self?.handleSyncData(data)
            }
        }
    }

    func logWatchReminder(sentSuccessfully: Bool, source: String) {
        let entry = WatchSyncManager.WatchReminderLogEntry(
            content: "请检查当前正在进行的活动是否正确",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: sentSuccessfully,
            source: source
        )
        syncManager.sendReminderLog(entry)
    }

    func logWatchConfirmed() {
        let entry = WatchSyncManager.WatchReminderLogEntry(
            content: "已确认收到提醒",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iWatch 已确认"
        )
        syncManager.sendReminderLog(entry)
    }

    private func handleSyncData(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(WatchSyncManager.SyncMessage.self, from: data)

            let types = message.activityTypes.map { syncType in
                WatchActivityType(
                    id: syncType.id,
                    name: syncType.name,
                    iconName: syncType.iconName,
                    color: syncType.color
                )
            }

            let iPhoneActive = message.activeRecords.filter { $0.isActive }.map { syncRecord -> WatchActivityRecord in
                let type = types.first(where: { $0.id == syncRecord.activityTypeId })
                return WatchActivityRecord(
                    id: syncRecord.id,
                    activityType: type ?? WatchActivityType(name: "未知", iconName: "questionmark", color: "#8E8E93"),
                    startTime: syncRecord.startTime,
                    endTime: syncRecord.endTime,
                    isActive: syncRecord.isActive
                )
            }

            let iPhoneCompleted = message.completedRecords.filter { !$0.isActive }.map { syncRecord -> WatchActivityRecord in
                let type = types.first(where: { $0.id == syncRecord.activityTypeId })
                return WatchActivityRecord(
                    id: syncRecord.id,
                    activityType: type ?? WatchActivityType(name: "未知", iconName: "questionmark", color: "#8E8E93"),
                    startTime: syncRecord.startTime,
                    endTime: syncRecord.endTime,
                    isActive: syncRecord.isActive
                )
            }

            // 合并：保留 Watch 本地已存在但 iPhone 尚未确认的活动
            // 按活动类型匹配（Watch 和 iPhone 各自生成 UUID，ID 不同）
            let iPhoneActiveTypeIDs = Set(iPhoneActive.map(\.activityType.id))
            let pendingLocal = activeRecords.filter { record in
                record.isActive && !iPhoneActiveTypeIDs.contains(record.activityType.id)
            }
            self.activeRecords = iPhoneActive + pendingLocal
            self.completedRecords = iPhoneCompleted

            self.activityTypes = types
            self.updateComplicationData()
            let reminders = message.reminders.map { syncReminder in
                WatchReminder(
                    id: syncReminder.id,
                    date: syncReminder.date
                )
            }
            if !self.remindersEquivalent(reminders) {
                self.reminders = reminders
                self.rescheduleWatchNotifications()
            }
        } catch {
            print("[Watch VM] Failed to decode sync data: \(error)")
        }
    }

    func startActivity(_ type: WatchActivityType) {
        if activeRecords.contains(where: { $0.activityType.id == type.id && $0.isActive }) {
            return
        }

        let record = WatchActivityRecord(activityType: type)
        activeRecords.append(record)

        syncManager.sendActivityStart(typeId: type.id)
    }

    func stopActivity(_ record: WatchActivityRecord) {
        if let index = activeRecords.firstIndex(where: { $0.id == record.id }) {
            var updatedRecord = record
            updatedRecord.stop()
            activeRecords.remove(at: index)
            completedRecords.insert(updatedRecord, at: 0)

            syncManager.sendActivityStop(recordId: record.id)
        }
    }

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

    private func updateComplicationData() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        var totalSeconds: TimeInterval = 0
        var activeActivityName: String?

        for record in completedRecords {
            guard let endTime = record.endTime else { continue }
            if record.startTime >= startOfDay && record.startTime < endOfDay {
                totalSeconds += endTime.timeIntervalSince(record.startTime)
            }
        }

        for record in activeRecords where record.isActive {
            if record.startTime >= startOfDay && record.startTime < endOfDay {
                totalSeconds += Date().timeIntervalSince(record.startTime)
                activeActivityName = record.activityType.name
            }
        }

        let totalMinutes = Int(totalSeconds) / 60
        let defaults = UserDefaults.standard
        defaults.set(totalMinutes, forKey: "todayTotalMinutes")
        if let name = activeActivityName {
            defaults.set(name, forKey: "activeActivityName")
        } else {
            defaults.removeObject(forKey: "activeActivityName")
        }
    }
}

class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onTriggered: ((UNNotification) -> Void)?
    var onTapped: ((UNNotificationResponse) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let n = notification
        DispatchQueue.main.async { [weak self] in
            self?.onTriggered?(n)
        }
        completionHandler([.sound, .banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let resp = response
        DispatchQueue.main.async { [weak self] in
            self?.onTapped?(resp)
        }
        completionHandler()
    }
}

struct WatchReminder: Identifiable {
    let id: UUID
    let date: Date
    let isEnabled: Bool

    init(id: UUID = UUID(), date: Date, isEnabled: Bool = true) {
        self.id = id
        self.date = date
        self.isEnabled = isEnabled
    }

    var hour: Int { Calendar.current.component(.hour, from: date) }
    var minute: Int { Calendar.current.component(.minute, from: date) }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: date)
    }
}

struct WatchActivityType: Identifiable {
    let id: UUID
    let name: String
    let iconName: String
    let color: String

    init(id: UUID = UUID(), name: String, iconName: String, color: String) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.color = color
    }
}

struct WatchActivityRecord: Identifiable {
    let id: UUID
    let activityType: WatchActivityType
    var startTime: Date
    var endTime: Date?
    var isActive: Bool

    init(id: UUID = UUID(), activityType: WatchActivityType, startTime: Date = Date(), endTime: Date? = nil, isActive: Bool = true) {
        self.id = id
        self.activityType = activityType
        self.startTime = startTime
        self.endTime = endTime
        self.isActive = isActive
    }

    mutating func stop() {
        self.endTime = Date()
        self.isActive = false
    }

    var duration: TimeInterval {
        guard let endTime = endTime else {
            return Date().timeIntervalSince(startTime)
        }
        return endTime.timeIntervalSince(startTime)
    }
}