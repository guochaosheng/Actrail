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
    private var suppressPlanAppendsUntil: Date = .distantPast
    private var clearMarkedTime: Date = .distantPast

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
                    self.markExpiredPlans()
                    self.rebuildCache()
                    self.sendSync()
                    self.extendReminderSchedules()
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
                self?.extendReminderSchedules()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .watchDidBecomeReachable, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.isAppReady == true else { return }
                self?.rebuildCache()
                self?.sendSync()
                self?.extendReminderSchedules()
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
            let now = Date()
            let watchPlanID = reminderLogs
                .filter { $0.reminderID == reminder.id && $0.source == "iWatch 计划" && $0.presetTime > now }
                .min { $0.presetTime < $1.presetTime }?
                .id
            return WatchSyncManager.SyncedReminder(
                id: reminder.id,
                date: reminder.date,
                watchPlanID: watchPlanID
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

        // 用户点击活动按钮 = 开始工作 = 立即取消闹钟振动
        // 需在防重放合并之后执行，避免一次点击为每种类型各取消一次闹钟
        let todayKey = Self.reminderDayKey(Date())
        for index in reminders.indices where reminders[index].alarmEnabled {
            let reminder = reminders[index]
            DiagnosticLog.append(tag: "AlarmCancel", message: "startActivity 三边取消 id=\(reminder.id.uuidString.prefix(8))")
            if let alarmID = reminder.scheduledAlarmIDs[todayKey] {
                AlarmKitManager.shared.cancelAlarm(id: alarmID)
            }
            appendCancelledEntries(for: reminder, date: Date())
            // 当日排定作废，下次打开时自动续排
            reminders[index].scheduledDates.removeAll { Calendar.current.isDate($0, inSameDayAs: Date()) }
            reminders[index].scheduledAlarmIDs[todayKey] = nil
        }
        ActivityReminder.saveAll(reminders)

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

    func addReminder(date: Date, alarmEnabled: Bool = false, alarmGraceMinutes: Int = 5, alarmSound: String = "default") {
        let reminder = ActivityReminder(date: date, alarmEnabled: alarmEnabled, alarmGraceMinutes: alarmGraceMinutes, alarmSound: alarmSound)
        reminders.append(reminder)
        ActivityReminder.saveAll(reminders)
        extendReminderSchedules()
        pushRemindersToWatch()
    }

    func deleteReminder(_ reminder: ActivityReminder) {
        DiagnosticLog.append(tag: "ReminderDelete", message: "删除提醒 id=\(reminder.id.uuidString.prefix(8))")
        cancelPhoneNotification(for: reminder)
        reminders.removeAll { $0.id == reminder.id }
        ActivityReminder.saveAll(reminders)
        reminderLogs.removeAll { $0.reminderID == reminder.id }
        ReminderLogEntry.saveAll(reminderLogs)
        pushRemindersToWatch()
        appendReminderLog(ReminderLogEntry(
            content: "已删除「\(reminder.timeString)」（iPhone/iWatch 通知与闹钟均已撤销）",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: true,
            source: "提醒已删除",
            reminderID: reminder.id
        ))
    }

    /// 提醒历史三层归档：
/// 第 1 层 提醒记录（每个提醒一组）；
/// 第 2 层 该提醒内的 iPhone 计划 / iWatch 计划 / 闹钟计划，同一预设时间的归档为一条；
/// 第 3 层 该条里按时间顺序展示预设、发出、确认、取消等全部操作记录。
    func reminderLogGroups() -> [ReminderLogGroup] {
        let grouped = Dictionary(grouping: reminderLogs) { $0.reminderID }
        var groups: [ReminderLogGroup] = []
        for (rid, logs) in grouped {
            let reminder = rid.flatMap { id in reminders.first(where: { $0.id == id }) }
            let isDeleted = rid != nil && reminder == nil
            let displayID = rid.map { "#\(String($0.uuidString.prefix(8)).uppercased())" } ?? "无关联提醒"
            let label: String
            if let reminder {
                label = reminder.timeString
            } else if isDeleted {
                label = "已删除提醒"
            } else {
                label = "未知提醒（无编号）"
            }

            let planSources: Set<String> = ["iPhone 计划", "iWatch 计划", "闹钟计划"]
            let operationSources: Set<String> = ["iPhone 本地通知", "iWatch 本地通知", "iPhone 已确认", "iWatch 已确认"]
            let planLogs = logs.filter { planSources.contains($0.source) }
            let opLogs = logs.filter { operationSources.contains($0.source) }
            let otherLogs = logs.filter { !planSources.contains($0.source) && !operationSources.contains($0.source) }

            var rowsByKind: [ReminderLogKind: [ReminderSlotSection]] = [:]
            var matchedOpIDs = Set<UUID>()

            for kind in [ReminderLogKind.phone, .watch, .alarm] {
                let kindPlans = planLogs.filter { $0.kind == kind }
                let groupedByDay = Dictionary(grouping: kindPlans) { Self.reminderDayKey($0.presetTime) }
                let dayKeys = groupedByDay.keys.sorted { a, b in
                    let ta = groupedByDay[a, default: []].first?.presetTime ?? .distantPast
                    let tb = groupedByDay[b, default: []].first?.presetTime ?? .distantPast
                    return ta > tb
                }
                var rows: [ReminderSlotSection] = []
                for dayKey in dayKeys {
                    let plans = groupedByDay[dayKey, default: []].sorted { $0.presetTime < $1.presetTime }
                    guard let reference = plans.first else { continue }
                    let planIDs = Set(plans.map(\.id))
                    let related = opLogs.filter { op in
                        if let pid = op.planID, planIDs.contains(pid) { return true }
                        guard op.kind == kind else { return false }
                        let t0 = plans.map(\.presetTime).min() ?? reference.presetTime
                        let t1 = plans.map(\.presetTime).max() ?? reference.presetTime
                        return op.presetTime >= t0.addingTimeInterval(-120) && op.presetTime <= t1.addingTimeInterval(120)
                    }
                    matchedOpIDs.formUnion(related.map(\.id))
                    let finalPlan = plans.last
                    let finalStatus = finalPlan.map { $0.status.isEmpty ? "已设定" : $0.status } ?? ""
                    rows.append(ReminderSlotSection(
                        id: "\(rid?.uuidString ?? "-")|\(kind.rawValue)|\(dayKey)",
                        kind: kind,
                        slotLabel: Self.slotLabel(for: reference.presetTime),
                        finalStatus: finalStatus,
                        logs: Self.sortLogs(plans + related)
                    ))
                }
                rows.sort { a, b in
                    let ta = a.logs.first(where: { Self.planSource(of: a.kind) == $0.source })?.presetTime ?? .distantPast
                    let tb = b.logs.first(where: { Self.planSource(of: b.kind) == $0.source })?.presetTime ?? .distantPast
                    return ta > tb
                }
                if !rows.isEmpty { rowsByKind[kind] = rows }
            }

            let unmatchedOps = opLogs.filter { !matchedOpIDs.contains($0.id) }
            if !otherLogs.isEmpty || !unmatchedOps.isEmpty {
                rowsByKind[.other] = [ReminderSlotSection(
                    id: "\(rid?.uuidString ?? "-")|other",
                    kind: .other,
                    slotLabel: "其它",
                    finalStatus: "\(otherLogs.count + unmatchedOps.count) 条",
                    logs: Self.sortLogs(otherLogs + unmatchedOps)
                )]
            }

            var kindSections: [ReminderLogKindSection] = []
            for kind in [ReminderLogKind.other, .phone, .watch, .alarm] {
                guard let rows = rowsByKind[kind], !rows.isEmpty else { continue }
                kindSections.append(ReminderLogKindSection(kind: kind, rows: rows))
            }

            groups.append(ReminderLogGroup(
                id: rid,
                displayID: displayID,
                reminderLabel: isDeleted ? "\(label)（已删除）" : label,
                isDeletedReminder: isDeleted,
                sections: kindSections
            ))
        }
        groups.sort { a, b in
            let la = a.sections.first?.rows.first?.logs.first?.sentTime ?? .distantPast
            let lb = b.sections.first?.rows.first?.logs.first?.sentTime ?? .distantPast
            return la > lb
        }
        return groups
    }

    private static func planSource(of kind: ReminderLogKind) -> String {
        switch kind {
        case .phone: return "iPhone 计划"
        case .watch: return "iWatch 计划"
        case .alarm: return "闹钟计划"
        case .other: return ""
        }
    }

    private static func slotLabel(for date: Date) -> String {
        let cal = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: date)
        if cal.isDateInToday(date) { return "今天 \(time)" }
        if cal.isDateInTomorrow(date) { return "明天 \(time)" }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MM/dd"
        return "\(dayFormatter.string(from: date)) \(time)"
    }

    private static func sortLogs(_ logs: [ReminderLogEntry]) -> [ReminderLogEntry] {
        logs.sorted { a, b in
            if a.sentTime != b.sentTime { return a.sentTime < b.sentTime }
            return a.presetTime < b.presetTime
        }
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
                extendReminderSchedules()
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

    func clearRemindersAndLogs() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .filter { $0.identifier.hasPrefix("reminder-") }
                .map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        for reminder in reminders where reminder.alarmEnabled {
            AlarmKitManager.shared.cancelAlarms(ids: Array(reminder.scheduledAlarmIDs.values))
        }
        reminders.removeAll()
        ActivityReminder.saveAll(reminders)
        // 清空全部日志，包含 iPhone 计划 / iWatch 计划 / 闹钟计划及全部历史
        reminderLogs.removeAll()
        ReminderLogEntry.saveAll(reminderLogs)
        // 抑制随后异步回调（通知 add / AlarmKit / watch 同步）把计划日志再写回来
        clearMarkedTime = Date()
        suppressPlanAppendsUntil = clearMarkedTime.addingTimeInterval(120)
        pushRemindersToWatch()
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

        reminderDelegate.onTapped = { [weak self] response in
            DispatchQueue.main.async {
                let planID = (response.notification.request.content.userInfo["planID"] as? String).flatMap(UUID.init(uuidString:))
                self?.logPhoneNotificationTapped(planID: planID)
            }
        }

        let centerGet = UNUserNotificationCenter.current()
        centerGet.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self?.extendReminderSchedules()
                case .notDetermined:
                    centerGet.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                        DispatchQueue.main.async {
                            guard granted else { return }
                            self?.extendReminderSchedules()
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
        let planID = (contentObject.userInfo["planID"] as? String).flatMap(UUID.init(uuidString:))
        let content = contentObject.body.isEmpty
            ? contentObject.title
            : contentObject.body
        let entry = ReminderLogEntry(
            content: content,
            presetTime: presetTime,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 本地通知",
            planID: planID
        )
        appendReminderLog(entry)
    }

    private func appendReminderLog(_ entry: ReminderLogEntry) {
        if ["iPhone 计划", "iWatch 计划", "闹钟计划"].contains(entry.source) {
            // 清空后的抑制窗口内，不再把计划日志写回来
            if Date() < suppressPlanAppendsUntil && entry.presetTime > clearMarkedTime { return }
            let alreadyExists = reminderLogs.contains { existing in
                existing.reminderID == entry.reminderID &&
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

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private func existingPlanID(reminder: ActivityReminder, date: Date, source: String) -> UUID? {
        reminderLogs.first { log in
            log.reminderID == reminder.id &&
            log.source == source &&
            Calendar.current.isDate(log.presetTime, inSameDayAs: date)
        }?.id
    }

    private func makePlanEntries(for reminder: ActivityReminder, date: Date) -> (iPhone: ReminderLogEntry, iWatch: ReminderLogEntry) {
        let time = Self.logDateFormatter.string(from: date)
        let iphone = ReminderLogEntry(
            content: "已安排提醒 \(time)（等待系统投递）",
            presetTime: date,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 计划",
            status: "计划中",
            reminderID: reminder.id,
            id: existingPlanID(reminder: reminder, date: date, source: "iPhone 计划") ?? UUID()
        )
        let watch = ReminderLogEntry(
            content: "iWatch 排定提醒 \(time)（等待系统投递）",
            presetTime: date,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iWatch 计划",
            status: "计划中",
            reminderID: reminder.id,
            id: existingPlanID(reminder: reminder, date: date, source: "iWatch 计划") ?? UUID()
        )
        return (iphone, watch)
    }

    private func appendCancelledEntries(for reminder: ActivityReminder, date: Date) {
        let time = Self.logDateFormatter.string(from: date)
        var entries: [ReminderLogEntry] = []
        if reminder.alarmEnabled {
            entries.append(ReminderLogEntry(
                content: "闹钟 \(time) 已取消",
                presetTime: date,
                sentTime: Date(),
                sentSuccessfully: true,
                source: "闹钟计划",
                status: "已取消",
                reminderID: reminder.id
            ))
        }
        let iphone = ReminderLogEntry(
            content: "iPhone 提醒 \(time) 当日作废（已确认活动）",
            presetTime: date,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 计划",
            status: "已取消",
            reminderID: reminder.id
        )
        let watch = ReminderLogEntry(
            content: "iWatch 提醒 \(time) 当日作废（已确认活动）",
            presetTime: date,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iWatch 计划",
            status: "已取消",
            reminderID: reminder.id
        )
        appendReminderLog(iphone)
        appendReminderLog(watch)
        entries.forEach { appendReminderLog($0) }
    }

    func deleteReminderLog(_ log: ReminderLogEntry) {
        reminderLogs.removeAll { $0.id == log.id }
        ReminderLogEntry.saveAll(reminderLogs)
    }

    /// 撤销某提醒某天的底层调度：AlarmKit 闹钟 + 当天 pending 通知。
    private func deactivatePlanSlot(reminderID: UUID?, at date: Date) {
        let dayKey = Self.reminderDayKey(date)
        if let reminderID {
            if let idx = reminders.firstIndex(where: { $0.id == reminderID }),
               let alarmID = reminders[idx].scheduledAlarmIDs[dayKey] {
                AlarmKitManager.shared.cancelAlarms(ids: [alarmID])
                reminders[idx].scheduledAlarmIDs.removeValue(forKey: dayKey)
                ActivityReminder.saveAll(reminders)
            }
            let identifier = "reminder-\(reminderID.uuidString)-\(dayKey)"
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                let ids = requests
                    .filter { $0.identifier == identifier }
                    .map(\.identifier)
                if !ids.isEmpty {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
                }
            }
        }
    }

    private func markExpiredPlans() {
        let now = Date()
        // 是否有进行中活动：有活动 = 已确认提醒目的达成 → 三条全取消；
        // 无活动 = 保留闹钟（让 n 分钟后闹钟再强烈提醒），iPhone/iWatch
        // 计划按「通知是否实际发出」区分为「已过期」（发出过）或「已取消」（未发出被撤销）
        let hasActive = activeRecords.contains { $0.isActive }
        var changed = false
        for index in reminderLogs.indices {
            guard reminderLogs[index].status == "计划中" else { continue }
            let source = reminderLogs[index].source
            let isPhoneOrWatch = source == "iPhone 计划" || source == "iWatch 计划"
            let isAlarm = source == "闹钟计划"
            guard isPhoneOrWatch || isAlarm else { continue }
            guard now > reminderLogs[index].presetTime else { continue }
            if isAlarm {
                // 无活动时保留闹钟计划，让 n 分钟后闹钟强烈提醒
                if !hasActive { continue }
                reminderLogs[index].status = "已取消"
                // 真正撤销当天已排定的 AlarmKit 闹钟与 pending 通知
                deactivatePlanSlot(reminderID: reminderLogs[index].reminderID, at: reminderLogs[index].presetTime)
            } else if hasActive {
                reminderLogs[index].status = "已取消"
                deactivatePlanSlot(reminderID: reminderLogs[index].reminderID, at: reminderLogs[index].presetTime)
            } else {
                // 无活动：按通知是否实际发出区分（优先 planID 精确匹配，缺省回退到时间窗口）
                let delivered = reminderLogs.contains { log in
                    let s = log.source
                    guard s == "iPhone 本地通知" || s == "iWatch 本地通知" ||
                          s == "iPhone 已确认" || s == "iWatch 已确认" else { return false }
                    if let pid = reminderLogs[index].planID, let logPid = log.planID {
                        return pid == logPid
                    }
                    return abs(log.presetTime.timeIntervalSince(reminderLogs[index].presetTime)) < 120
                }
                reminderLogs[index].status = delivered ? "已过期" : "已取消"
                // 未实际发出的 iPhone/iWatch 计划可能残留底层 pending 通知，一并撤销
                if !delivered {
                    deactivatePlanSlot(reminderID: reminderLogs[index].reminderID, at: reminderLogs[index].presetTime)
                }
            }
            reminderLogs[index].sentTime = now
            changed = true
        }
        if changed {
            ReminderLogEntry.saveAll(reminderLogs)
        }
    }

    private func logPhoneNotificationTapped(planID: UUID?) {
        let entry = ReminderLogEntry(
            content: "已确认收到提醒",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 已确认",
            planID: planID
        )
        appendReminderLog(entry)
    }

    // MARK: - 滚动 3 天提醒排定
    //
    // 每次 App 打开/被唤醒时调用：为每个开启的提醒保证未来 3 天（今天起算，
    // 若当天该时刻已过则从下一天起算）都有本地通知与 AlarmKit 闹钟。
    // 连续 3 天未打开（iPhone/iWatch）则排定自然耗尽，不再提醒。
    private static func reminderDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    func extendReminderSchedules() {
        guard !reminders.isEmpty else { return }
        let calendar = Calendar.current
        let now = Date()
        for index in reminders.indices where reminders[index].isEnabled {
            let reminder = reminders[index]
            var scheduled = reminder.scheduledDates.filter { $0 > now }
            let hour = calendar.component(.hour, from: reminder.date)
            let minute = calendar.component(.minute, from: reminder.date)
            var day = calendar.startOfDay(for: now)
            var guardCount = 0
            while scheduled.count < 3 && guardCount < 31 {
                guardCount += 1
                guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else {
                    break
                }
                if candidate <= now {
                    // 当天该时刻已过：从下一天起算
                    day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                    continue
                }
                if !scheduled.contains(where: { calendar.isDate($0, inSameDayAs: candidate) }) {
                    self.scheduleReminderSlot(reminder, at: candidate)
                    scheduled.append(candidate)
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }
            if scheduled != reminder.scheduledDates {
                reminders[index].scheduledDates = scheduled
                ActivityReminder.saveAll(reminders)
            }
        }
    }

    private func scheduleReminderSlot(_ reminder: ActivityReminder, at date: Date) {
        guard reminder.isEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional ||
                  settings.authorizationStatus == .ephemeral else {
                print("[Reminder] permission not granted, cannot schedule slot")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "行迹提醒"
            content.body = "请检查当前正在进行的活动是否正确"
            content.sound = reminder.alarmSound == "none" ? nil : .default
            let entries = self.makePlanEntries(for: reminder, date: date)
            content.userInfo = [
                "presetTime": date,
                "reminderId": reminder.id.uuidString,
                "planID": entries.iPhone.id.uuidString,
                "watchPlanID": entries.iWatch.id.uuidString
            ]

            let dateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
            let request = UNNotificationRequest(
                identifier: "reminder-\(reminder.id.uuidString)-\(Self.reminderDayKey(date))",
                content: content,
                trigger: trigger
            )
UNUserNotificationCenter.current().add(request) { [weak self] error in
                guard let self else { return }
                if let error = error {
                    print("[Reminder] schedule failed for slot \(date): \(error)")
                } else {
                    DispatchQueue.main.async {
                        self.appendReminderLog(entries.iPhone)
                        self.appendReminderLog(entries.iWatch)
                        if reminder.alarmEnabled {
                            DiagnosticLog.append(tag: "AlarmSchedule", message: "alarmEnabled=true → scheduleAlarm slot \(date)")
                            self.scheduleAlarm(for: reminder, onDate: date) { alarmID in
                                let dayKeyValue = Self.reminderDayKey(date)
                                if let idx = self.reminders.firstIndex(where: { $0.id == reminder.id }) {
                                    self.reminders[idx].scheduledAlarmIDs[dayKeyValue] = alarmID
                                    ActivityReminder.saveAll(self.reminders)
                                }
                            }
                        }
            }
        }
    }
        }
    }

    private func scheduleAlarm(for reminder: ActivityReminder, onDate reminderDate: Date, completion: ((UUID) -> Void)? = nil) {
        DiagnosticLog.append(tag: "AlarmSchedule", message: "scheduleAlarm 进入 id=\(reminder.id.uuidString.prefix(8)) date=\(reminderDate)")
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
                to: reminderDate
            ) ?? reminderDate
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm:ss"
            DiagnosticLog.append(tag: "AlarmSchedule", message: "排定闹钟 \(f.string(from: alarmDate)) (slot=\(f.string(from: reminderDate)), grace=\(reminder.alarmGraceMinutes)min)")
            do {
                let alarmID = try await AlarmKitManager.shared.scheduleAlarm(
                    date: alarmDate,
                    reminderId: reminder.id.uuidString,
                    alarmSound: reminder.alarmSound
                )
                DiagnosticLog.append(tag: "AlarmSchedule", message: "✓ 闹钟排定成功 id=\(reminder.id.uuidString.prefix(8))")
                appendAlarmPlan(reminder: reminder, alarmDate: alarmDate, slotDate: reminderDate)
                completion?(alarmID)
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
        // 打开 App = 确认还在用；先取消已到点的计划，再自动续排未来 3 天提醒
        markExpiredPlans()
        extendReminderSchedules()
    }

    private func appendAlarmPlan(reminder: ActivityReminder, alarmDate: Date, slotDate: Date) {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        let content = "闹钟已排定 \(f.string(from: alarmDate))（+\(reminder.alarmGraceMinutes) 分钟）"
        DispatchQueue.main.async {
            self.appendReminderLog(ReminderLogEntry(
                content: content,
                presetTime: slotDate,
                sentTime: Date(),
                sentSuccessfully: true,
                source: "闹钟计划",
                status: "计划中",
                reminderID: reminder.id
            ))
        }
    }

    private func cancelPhoneNotification(for reminder: ActivityReminder) {
        DiagnosticLog.append(tag: "AlarmCancel", message: "cancelPhoneNotification id=\(reminder.id.uuidString.prefix(8))")
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .filter { $0.identifier.hasPrefix("reminder-\(reminder.id.uuidString)-") }
                .map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        AlarmKitManager.shared.cancelAlarms(ids: Array(reminder.scheduledAlarmIDs.values))
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index].scheduledDates.removeAll()
            reminders[index].scheduledAlarmIDs.removeAll()
            ActivityReminder.saveAll(reminders)
        }
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
