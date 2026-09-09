import Foundation
import WatchConnectivity
import WatchKit
import WidgetKit

enum AppGroupConstant {
    static let suiteName = "group.com.actrail.app"
    static let todayTotalMinutesKey = "todayTotalMinutes"
    static let activeActivityNameKey = "activeActivityName"
    static let activeStartDateKey = "activeStartDate"
    static let activeBaseMinutesKey = "activeBaseMinutes"
    static let activeCountKey = "activeCount"
}

@Observable
class WatchActivityViewModel {
    var activityTypes: [WatchActivityType] = []
    var activeRecords: [WatchActivityRecord] = []
    var completedRecords: [WatchActivityRecord] = []
    var reminders: [WatchReminder] = []
    var isReachable = false
    var isConnectingToPhone = false

    private let syncManager = WatchSyncManager.shared
    private var syncTimer: Timer?
    private var reminderCheckTimer: Timer?
    private var reconnectTimer: Timer?
    private var connectingHideTask: Task<Void, Never>?
    private var fetchRetryTask: Task<Void, Never>?
    private var firedReminderKeys: Set<String> = []
    private var reportedReminderKeys: Set<String> = []
    private let notificationDelegate = WatchNotificationDelegate()

    init() {
        setupSyncListener()
        setupReachabilityObserver()
        setupReminderActions()
        setupWatchNotifications()
        requestInitialData()
        startReminderCheck()
        startReconnectLoop()
    }

    deinit {
        syncTimer?.invalidate()
        reminderCheckTimer?.invalidate()
        reconnectTimer?.invalidate()
        connectingHideTask?.cancel()
        fetchRetryTask?.cancel()
    }

    private func setupReachabilityObserver() {
        syncManager.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor in
                guard let self else { return }
                let wasLinked = self.isReachable
                self.isReachable = reachable
                if reachable {
                    self.requestInitialData()
                    // 断连后重连成功：立即开启高频拉取，直到真正拿到一次快照
                    if !wasLinked {
                        self.rapidFetchUntilSuccess()
                    }
                }
            }
        }
    }

    /// 断连重连成功后每秒持续拉取 iPhone 快照，直到收到一次数据（handleSyncData 会取消），
    /// 兜底最多持续 15 秒退回常规 2 秒轮询。
    private func rapidFetchUntilSuccess() {
        fetchRetryTask?.cancel()
        fetchRetryTask = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled && attempts < 15 {
                guard let self else { return }
                self.syncManager.requestDataFromiPhone()
                attempts += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - 连接拦截：未连接 iPhone 时任何按钮操作都提示「正在连接中」

    /// 与 UI 圆点同源：用 VM 缓存的 isReachable（由 sessionReachabilityDidChange 回调更新），
    /// 避免 WCSession.isReachable 瞬时值与界面状态不一致导致"显示未连接却放行操作"。
    private func isPhoneLinked() -> Bool {
        WCSession.default.activationState == .activated && self.isReachable
    }

    /// App 打开后持续尝试连接，直到成功；断连后自动继续重连。
    private func startReconnectLoop() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tryReconnect()
            }
        }
        Task { @MainActor in
            self.tryReconnect()
        }
    }

    private func tryReconnect() {
        if isPhoneLinked() {
            return
        }
        syncManager.requestDataFromiPhone()
    }

    /// 用户点击任意操作按钮前的统一守卫：已连接则放行，否则弹出「正在连接中」。
    func onUserAction() -> Bool {
        guard isPhoneLinked() else {
            showConnectingIndicator()
            return false
        }
        return true
    }

    private func showConnectingIndicator() {
        isConnectingToPhone = true
        connectingHideTask?.cancel()
        connectingHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self.isConnectingToPhone = false
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
        fireReminder()
        scheduleWatchTestNotification()
    }

    private func requestInitialData() {
        requestDataFromiPhone()
        startPeriodicSync()
        scheduleBackgroundRefresh()
    }

    func requestDataFromiPhone() {
        syncManager.requestDataFromiPhone()
    }

    private func startPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncManager.requestDataFromiPhone()
            }
        }
    }

    func scheduleBackgroundRefresh() {
        // watchOS SwiftUI 独立 app 无法使用 WKExtension.scheduleBackgroundRefresh / BGTaskScheduler。
        // 后台更新由 iPhone 端 transferCurrentComplicationUserInfo 触发（系统唤醒本 app 处理）。
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
                fireReminder()
                return
            }
        }
    }

    private func fireReminder() {
        WKInterfaceDevice.current().play(.notification)
    }

    // MARK: - Watch Local Notifications

    private func setupWatchNotifications() {
        notificationDelegate.onTriggered = { [weak self] notification in
            Task { @MainActor in
                let planID = (notification.request.content.userInfo["planID"] as? String).flatMap(UUID.init(uuidString:))
                let reminderID = Self.reminderID(from: notification.request.identifier)
                self?.logWatchReminder(
                    sentSuccessfully: true,
                    source: "iWatch 本地通知",
                    reminderID: reminderID,
                    planID: planID
                )
            }
        }
        notificationDelegate.onTapped = { [weak self] response in
            Task { @MainActor in
                let planID = (response.notification.request.content.userInfo["planID"] as? String).flatMap(UUID.init(uuidString:))
                let reminderID = Self.reminderID(from: response.notification.request.identifier)
                self?.logWatchConfirmed(reminderID: reminderID, planID: planID)
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

    /// 从通知 identifier（reminder-<UUID>-<yyyyMMdd>）解析回提醒 id，
    /// 保证触发/确认日志能精确关联到具体提醒。
    private static func reminderID(from identifier: String) -> UUID? {
        let parts = identifier.components(separatedBy: "-")
        guard parts.first == "reminder", parts.count >= 6 else { return nil }
        let uuidString = parts.dropFirst().dropLast().joined(separator: "-")
        return UUID(uuidString: uuidString)
    }

    private func remindersEquivalent(_ new: [WatchReminder]) -> Bool {
        guard new.count == reminders.count else { return false }
        let oldSet = Set(reminders.map { "\($0.id)-\($0.date.timeIntervalSince1970)-\($0.planID?.uuidString ?? "")" })
        let newSet = Set(new.map { "\($0.id)-\($0.date.timeIntervalSince1970)-\($0.planID?.uuidString ?? "")" })
        return oldSet == newSet
    }

    private func rescheduleWatchNotifications(resetReportedKeys: Bool = false) {
        if resetReportedKeys {
            reportedReminderKeys.removeAll()
        }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let calendar = Calendar.current
        let now = Date()
        for reminder in reminders {
            _ = reminder.isEnabled
            let hour = calendar.component(.hour, from: reminder.date)
            let minute = calendar.component(.minute, from: reminder.date)
            let startOfDay = calendar.startOfDay(for: now)

            // 跟随 iPhone 滚动 3 天：从今天起（当天已过则从明天起）为未来 3 天各排一个
            var candidates: [Date] = []
            var day = startOfDay
            var guardCount = 0
            while candidates.count < 3 && guardCount < 31 {
                guardCount += 1
                if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
                    if candidate > now {
                        let dayKey = Self.dayKey(candidate)
                        if !candidates.contains(where: { Self.dayKey($0) == dayKey }) {
                            candidates.append(candidate)
                        }
                    }
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }

            for candidate in candidates {
                let content = UNMutableNotificationContent()
                content.title = "行迹提醒"
                content.body = "请检查当前正在进行的活动是否正确"
                content.sound = .default
                let dayKey = Self.dayKey(candidate)
                var userInfo: [String: Any] = ["presetTime": candidate]
                let planIDString = reminder.plansByDay[dayKey] ?? reminder.planID?.uuidString
                if let pid = planIDString { userInfo["planID"] = pid }
                content.userInfo = userInfo

                let dateComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: candidate
                )

                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
                let request = UNNotificationRequest(
                    identifier: "reminder-\(reminder.id.uuidString)-\(dayKey)",
                    content: content,
                    trigger: trigger
                )
                let reportKey = "\(reminder.id.uuidString)-\(dayKey)"
                let slotPlanID = planIDString.flatMap(UUID.init(uuidString:))
                center.add(request) { [weak self] error in
                    guard let self else { return }
                    let ok = error == nil
                    if ok, self.reportedReminderKeys.contains(reportKey) { return }
                    let f = DateFormatter()
                    f.dateFormat = "MM/dd HH:mm"
                    let entry = WatchSyncManager.WatchReminderLogEntry(
                        content: "iWatch 排定提醒 \(f.string(from: candidate))（等待系统投递）",
                        presetTime: candidate,
                        sentTime: Date(),
                        sentSuccessfully: ok,
                        source: ok ? "iWatch 计划" : "iWatch 排定失败",
                        reminderID: reminder.id,
                        planID: slotPlanID
                    )
                    if ok {
                        self.reportedReminderKeys.insert(reportKey)
                        self.syncManager.sendReminderLog(entry)
                    } else {
                        self.syncManager.sendReminderLog(entry)
                    }
                }
            }
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
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

    func logWatchReminder(sentSuccessfully: Bool, source: String, reminderID: UUID? = nil, planID: UUID? = nil) {
        let entry = WatchSyncManager.WatchReminderLogEntry(
            content: "请检查当前正在进行的活动是否正确",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: sentSuccessfully,
            source: source,
            reminderID: reminderID,
            planID: planID
        )
        syncManager.sendReminderLog(entry)
    }

    func logWatchConfirmed(reminderID: UUID? = nil, planID: UUID? = nil) {
        let entry = WatchSyncManager.WatchReminderLogEntry(
            content: "已确认收到提醒",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iWatch 已确认",
            reminderID: reminderID,
            planID: planID
        )
        syncManager.sendReminderLog(entry)
    }

    private func handleSyncData(_ data: Data) {
        // 收到一次快照即视为拉取成功，停止断连重连后的高频重试
        fetchRetryTask?.cancel()
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

            // 合并：保留 Watch 本地已存在且 iPhone 尚未确认（从未见过）的活动
            // 按活动类型匹配（Watch 和 iPhone 各自生成 UUID，ID 不同）
            // 若 iPhone 的 completedRecords 里已存在该类型，说明 iPhone 已停掉，
            // 不应再保留为本地 pending
            let iPhoneActiveTypeIDs = Set(iPhoneActive.map(\.activityType.id))
            let iPhoneCompletedTypeIDs = Set(iPhoneCompleted.map(\.activityType.id))
            let pendingLocal = activeRecords.filter { record in
                record.isActive
                    && !iPhoneActiveTypeIDs.contains(record.activityType.id)
                    && !iPhoneCompletedTypeIDs.contains(record.activityType.id)
            }
            self.activeRecords = iPhoneActive + pendingLocal
            self.completedRecords = iPhoneCompleted

            self.activityTypes = types
            print("[Watch VM] handleSyncData: iPhoneActive=\(iPhoneActive.count), pendingLocal=\(pendingLocal.count), activeCount=\(self.activeRecords.filter(\.isActive).count)")
            self.updateComplicationData()
            let reminders = message.reminders.map { syncReminder in
                WatchReminder(
                    id: syncReminder.id,
                    date: syncReminder.date,
                    planID: syncReminder.watchPlanID,
                    plansByDay: syncReminder.plansByDay ?? [:]
                )
            }
            if !self.remindersEquivalent(reminders) {
                self.reminders = reminders
            }
            // 每次数据到达都重排（幂等），确保打开 App 后按当天/次日滚动续排
            self.rescheduleWatchNotifications()
            self.scheduleBackgroundRefresh()
        } catch {
            print("[Watch VM] Failed to decode sync data: \(error)")
        }
    }

    func startActivity(_ type: WatchActivityType) {
        guard onUserAction() else { return }
        if activeRecords.contains(where: { $0.activityType.id == type.id && $0.isActive }) {
            return
        }

        let record = WatchActivityRecord(activityType: type)
        activeRecords.append(record)

        updateComplicationData()
        syncManager.sendActivityStart(typeId: type.id)
    }

    func stopActivity(_ record: WatchActivityRecord) {
        guard onUserAction() else { return }
        if let index = activeRecords.firstIndex(where: { $0.id == record.id }) {
            var updatedRecord = record
            updatedRecord.stop()
            activeRecords.remove(at: index)
            completedRecords.insert(updatedRecord, at: 0)

            updateComplicationData()
            syncManager.sendActivityStop(recordId: record.id, typeId: record.activityType.id)
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

        // 进行中活动数 = 当前所有正在进行的活动个数（不限当日）
        let activeCount = activeRecords.filter(\.isActive).count

        var totalSeconds: TimeInterval = 0
        var activeActivityName: String?
        var activeStart: Date?

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
                if activeStart == nil {
                    activeStart = record.startTime
                }
            }
        }

        let totalMinutes = Int(totalSeconds) / 60
        let shared = UserDefaults(suiteName: AppGroupConstant.suiteName)
        shared?.set(totalMinutes, forKey: AppGroupConstant.todayTotalMinutesKey)
        shared?.set(activeCount, forKey: AppGroupConstant.activeCountKey)
        print("[Watch VM] updateComplicationData: wrote activeCount=\(activeCount), totalMinutes=\(totalMinutes)")

        if let start = activeStart {
            let baseSeconds = totalSeconds - Date().timeIntervalSince(start)
            shared?.set(start, forKey: AppGroupConstant.activeStartDateKey)
            shared?.set(Int(baseSeconds) / 60, forKey: AppGroupConstant.activeBaseMinutesKey)
        } else {
            shared?.removeObject(forKey: AppGroupConstant.activeStartDateKey)
            shared?.removeObject(forKey: AppGroupConstant.activeBaseMinutesKey)
        }

        if let name = activeActivityName {
            shared?.set(name, forKey: AppGroupConstant.activeActivityNameKey)
        } else {
            shared?.removeObject(forKey: AppGroupConstant.activeActivityNameKey)
        }

        WidgetCenter.shared.reloadAllTimelines()
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
    let planID: UUID?
    var plansByDay: [String: String]

    init(id: UUID = UUID(), date: Date, isEnabled: Bool = true, planID: UUID? = nil, plansByDay: [String: String] = [:]) {
        self.id = id
        self.date = date
        self.isEnabled = isEnabled
        self.planID = planID
        self.plansByDay = plansByDay
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