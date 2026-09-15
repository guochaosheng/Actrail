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
    var selectedCalendarDate: Date? = nil
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

        // 调试 hooks：必须在 init 阶段执行（devicectl 后台 launch 不渲染 UI、不触发 onAppear）。
        // 通道优先用 launch arguments（argv），env 在真机 devicectl 注入不可靠。
        if self.flag("STOP_ALL_ACTIVE") {
            stopAllActiveForDebug()
        }
        if self.flag("AUTOADD_ACTIVITY") {
            autoStartActivityForDebug()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rebuildCache()
            self?.sendSync()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isAppReady = true
        }

        performAutoBackupIfNeeded()
    }

    private func flag(_ key: String) -> Bool {
        // launch arguments: "-ACTRAIL_STOP_ALL_ACTIVE" / "-ACTRAIL_AUTOADD_ACTIVITY"
        if CommandLine.arguments.contains("-ACTRAIL_\(key)") { return true }
        if ProcessInfo.processInfo.environment[key] == "1" { return true }
        return false
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
                guard let self else { return }
                // iWatch 端上报的执行/确认记录：回调优先合并为对应「iWatch 计划」
                // 的唯一「执行成功」结算记录（不另生成事件记录，避免两条并存）。
                var normalized = log
                if normalized.source == "iWatch 已确认" || normalized.source == "iWatch 本地通知" {
                    normalized.status = normalized.sentSuccessfully ? "执行成功" : "执行失败"
                    if normalized.sentSuccessfully, self.settleWatchExecutionReported(normalized) {
                        return
                    }
                } else if normalized.source == "iWatch 计划" && normalized.status.isEmpty {
                    normalized.status = "计划中"
                }
                self.appendReminderLog(normalized)
            }
        }

        syncManager.onWatchStatusReceived = { [weak self] status in
            Task { @MainActor in
                self?.presentWatchStatus(status)
            }
        }

        isWatchReachable = syncManager.isReachable

        // 闹钟一响（系统回调状态流）立即为对应闹钟计划追加「执行成功」
        AlarmKitManager.shared.onAlarmAlerting = { [weak self] alarmID in
            Task { @MainActor in
                self?.settleAlarmFired(alarmID: alarmID)
            }
        }
        AlarmKitManager.shared.startAlarmMonitoring()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.syncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.modelContext != nil else { return }
                    self.markExpiredPlans()
                    let changed = self.sendSyncIfChanged()
                    self.extendReminderSchedules()
                }
            }
        }
    }

    // 仅当发送快照与上一次实际发送不一致时才调用 sendSync()。
    // 3 秒轮询改用它，避免每 3 秒无条件轰炸 applicationContext，
    // 否则 watch 后台队列被无价值消息塞满、真正变化被拖延，且旧消息延迟重放会
    // 造成表盘“停止后消失又回显”。
    private var lastSentSignature: String?

    @discardableResult
    private func sendSyncIfChanged() -> Bool {
        rebuildCache()
        let active = cachedActiveRecords
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id)|\($0.isActive)|\($0.endTime?.timeIntervalSince1970 ?? 0)" }
            .joined(separator: ":")
        let signature = "A\(active)C\(cachedCompletedRecords.count)R\(cachedReminders.count)"
        guard signature != lastSentSignature else { return false }
        lastSentSignature = signature
        sendSync()
        return true
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
            let iWatchPlans = reminderLogs
                .filter { $0.reminderID == reminder.id && $0.source == "iWatch 计划" && $0.presetTime > now }
            let watchPlanID = iWatchPlans
                .min { $0.presetTime < $1.presetTime }?
                .id
            var plansByDay: [String: String] = [:]
            for plan in iWatchPlans {
                plansByDay[Self.reminderDayKey(plan.presetTime)] = plan.id.uuidString
            }
            return WatchSyncManager.SyncedReminder(
                id: reminder.id,
                date: reminder.date,
                watchPlanID: watchPlanID,
                plansByDay: plansByDay.isEmpty ? nil : plansByDay
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
        refreshSmartOrderIfNeeded()
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
            // 优先按 recordId：从 iPhone 同步到 watch 的活动，ID 两端一致可直接匹配。
            if let recordIdString = userInfo["recordId"] as? String,
               let recordId = UUID(uuidString: recordIdString),
               let record = activeRecords.first(where: { $0.id == recordId }) {
                stopActivity(record)
            } else if let typeIdString = userInfo["typeId"] as? String,
                      let typeId = UUID(uuidString: typeIdString),
                      let record = activeRecords.first(where: { $0.activityType?.id == typeId && $0.isActive }) {
                // watch 本地启动的活动 recordId 不匹配（两端 UUID 不同），按类型停止对应进行中记录。
                stopActivity(record)
            }
        default:
            break
        }
    }

    // MARK: - Data operations

    /// 智能排序：按使用频率降序、总时长降序排列活动类型，
    /// 方便用户就近点击、减少在 iWatch 上滚动。
    private func smartSortedTypes(from types: [ActivityType]) -> [ActivityType] {
        guard let context = modelContext else { return types }
        let allRecords = (try? context.fetch(FetchDescriptor<ActivityRecord>())) ?? []
        var stats: [UUID: (count: Int, duration: TimeInterval)] = [:]
        for record in allRecords {
            guard let typeId = record.activityType?.id else { continue }
            var s = stats[typeId, default: (0, 0)]
            s.count += 1
            s.duration += record.duration
            stats[typeId] = s
        }
        return types.sorted { a, b in
            let ca = stats[a.id]?.count ?? 0
            let cb = stats[b.id]?.count ?? 0
            if ca != cb { return ca > cb }
            let da = stats[a.id]?.duration ?? 0
            let db = stats[b.id]?.duration ?? 0
            return da > db
        }
    }

    /// 智能排序模式下，记录变化后重新计算排序；普通模式无操作。
    private func refreshSmartOrderIfNeeded() {
        guard AppSettings.activitySortMode == "smart" else { return }
        fetchActivityTypes()
    }

    func fetchActivityTypes() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ActivityType>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        do {
            let fetched = try context.fetch(descriptor)
            let sorted = AppSettings.activitySortMode == "smart" ? smartSortedTypes(from: fetched) : fetched
            activityTypes = sorted
            safeTypeValues = sorted.compactMap { type in
                (id: type.id, name: type.name, iconName: type.iconName, color: type.color, group: type.group)
            }
        } catch {
            print("Failed to fetch activity types: \(error)")
        }
    }

    func fetchTodayRecords() {
        guard let context = modelContext else { return }
        let calendar = Calendar.current
        let targetDate = selectedCalendarDate ?? Date()
        let startOfDay = calendar.startOfDay(for: targetDate)
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

            // 跨日进行中记录（startTime 早于今日 0 点）也必须进缓存，
            // 否则 cachedActiveRecords 会漏掉它们，表盘「进行中活动数」比真实值偏小。
            // 同时纳入 activeRecords，使它们在 UI 里可见且可被停止（否则无法从 iPhone 停掉，
            // 表盘数字会一直 ≥ iPhone 显示的进行中活动）。
            let activeDescriptor = FetchDescriptor<ActivityRecord>(
                predicate: #Predicate { $0.isActive },
                sortBy: [SortDescriptor(\.startTime, order: .reverse)]
            )
            if let activeAll = try? context.fetch(activeDescriptor) {
                for record in activeAll {
                    if !activeRecords.contains(where: { $0.id == record.id }) {
                        activeRecords.append(record)
                    }
                    if !safeRecordValues.contains(where: { $0.id == record.id }) {
                        guard let typeId = record.activityType?.id else { continue }
                        safeRecordValues.append((id: record.id, activityTypeId: typeId, startTime: record.startTime, endTime: record.endTime, isActive: record.isActive, note: record.note))
                    }
                }
                // 观测：当前全部 active 记录数（跨日修复是否生效）
                UserDefaults.standard.set(activeAll.count, forKey: "DebugActiveAllCount")
                UserDefaults.standard.set(Date(), forKey: "DebugActiveAllTime")
            }

            rebuildCache()
            sendSyncIfChanged()
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
            let alarmID = reminder.scheduledAlarmIDs[todayKey]
            let fireTime = alarmID.flatMap { AlarmKitManager.shared.alarmFireTime(id: $0) }
            if let alarmID {
                AlarmKitManager.shared.cancelAlarm(id: alarmID)
            }
            appendCancelledEntries(for: reminder, date: Date(), alarmFireTime: fireTime)
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
            refreshSmartOrderIfNeeded()
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
            refreshSmartOrderIfNeeded()
            rebuildCache()
            sendSync()
        } catch {
            print("Failed to save activity record: \(error)")
            // 观测：stop 保存失败（真机验证跨日 active 停止时 save 是否报错）
            UserDefaults.standard.set("\(error)", forKey: "DebugStopSaveError")
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

    /// 为全部活动类型重新分配连续 sortOrder（按传入顺序），用于拖拽排序后持久化。
    func reorderActivityTypes(_ ordered: [ActivityType]) {
        guard let context = modelContext else { return }
        for (index, type) in ordered.enumerated() {
            type.sortOrder = index
        }
        do {
            try context.save()
            activityTypes = ordered
            safeTypeValues = ordered.compactMap { type in
                (id: type.id, name: type.name, iconName: type.iconName, color: type.color, group: type.group)
            }
            rebuildCache()
        } catch {
            print("Failed to reorder activity types: \(error)")
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
                // 关闭提醒 = 取消全部已排定计划，追加不可变「取消成功」结果记录
                let plansSnapshot = reminderLogs
                for log in plansSnapshot where
                    log.reminderID == reminders[index].id && log.status == "计划中" &&
                    ["iPhone 计划", "iWatch 计划", "闹钟计划"].contains(log.source) &&
                    !planResultExists(for: log) {
                    appendPlanResult(for: log, status: "取消成功")
                }
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
        pushRemindersToWatch()
    }

    func rescheduleAllPhoneNotificationsPublic() {
        setupReminderNotifications()
    }

    /// 应用初始化重置：删除 iPhone / iWatch / 闹钟排定计划、记录提醒、
    /// 提醒历史、全部活动历史记录；活动类型恢复默认；正在进行活动全部清除。
    func resetAllAppData() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .filter { $0.identifier.hasPrefix("reminder-") }
                .map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        let appAlarmIDs = Set(reminders.flatMap { $0.scheduledAlarmIDs.values }.map(\.uuidString))
            .union(AlarmKitManager.shared.registeredAlarmIDs().map(\.uuidString))
        if let before = AlarmKitManager.shared.queryAlarms() {
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm"
            let mine = before.filter { appAlarmIDs.contains($0.id.uuidString) }
            let times = before.map { alarm in
                switch alarm.schedule {
                case .fixed(let date)?: return f.string(from: date)
                case .relative(let rel)?: return String(format: "%02d:%02d", rel.time.hour, rel.time.minute)
                case nil: return "无时刻"
                }
            }.joined(separator: ", ")
            DiagnosticLog.append(tag: "AlarmReset", message: "重置前系统闹钟 \(before.count) 个（本app登记∪缓存可匹配 \(mine.count) 个）" + (before.isEmpty ? "" : " → \(times)"))
        }
        let cancelIDs = Array(Set(reminders.flatMap { $0.scheduledAlarmIDs.values }.map(\.uuidString))
            .union(AlarmKitManager.shared.registeredAlarmIDs().map(\.uuidString)))
            .compactMap { UUID(uuidString: $0) }
        AlarmKitManager.shared.cancelAlarms(ids: cancelIDs)
        AlarmKitManager.shared.clearAlarmRegistry()
        if let after = AlarmKitManager.shared.queryAlarms() {
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm"
            let times = after.map { alarm in
                switch alarm.schedule {
                case .fixed(let date)?: return f.string(from: date)
                case .relative(let rel)?: return String(format: "%02d:%02d", rel.time.hour, rel.time.minute)
                case nil: return "无时刻"
                }
            }.joined(separator: ", ")
            DiagnosticLog.append(tag: "AlarmReset", message: "重置后系统闹钟 \(after.count) 个" + (after.isEmpty ? "（已清空）" : " → \(times)"))
        }
        reminders.removeAll()
        ActivityReminder.saveAll(reminders)

        reminderLogs.removeAll()
        ReminderLogEntry.saveAll(reminderLogs)

        guard let context = modelContext else { return }
        if let records = try? context.fetch(FetchDescriptor<ActivityRecord>()) {
            for record in records {
                context.delete(record)
            }
        }
        if let types = try? context.fetch(FetchDescriptor<ActivityType>()) {
            for type in types {
                context.delete(type)
            }
        }
        try? context.save()

        activeRecords.removeAll()
        todayRecords.removeAll()
        activityTypes.removeAll()
        safeRecordValues.removeAll()
        safeTypeValues.removeAll()

        insertSampleData()
        fetchActivityTypes()
        fetchTodayRecords()

        rebuildCache()
        pushRemindersToWatch()
        sendSync()
    }

    // MARK: - 设置：启动通知开关

    /// 全量取消 iPhone 排定中的「reminder-」前缀通知。
    private func cancelAllPendingReminderNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests
                .filter { $0.identifier.hasPrefix("reminder-") }
                .map(\.identifier)
            if !ids.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    /// 全量取消本 app 的 AlarmKit 闹钟并清空注册表。
    private func cancelAllScheduledAlarms() {
        let ids = Set(reminders.flatMap { $0.scheduledAlarmIDs.values }.map(\.uuidString))
            .union(AlarmKitManager.shared.registeredAlarmIDs().map(\.uuidString))
            .sorted()
            .compactMap(UUID.init(uuidString:))
        AlarmKitManager.shared.cancelAlarms(ids: ids)
        AlarmKitManager.shared.clearAlarmRegistry()
    }

    /// 启动通知关闭：撤销 iPhone/iWatch/闹钟全部排定计划并清空未来排定缓存；
    /// 启动通知开启：重新排定未来 3 天提醒并同步到 iWatch。
    func setNotificationsEnabled(_ enabled: Bool) {
        if enabled {
            extendReminderSchedules()
            pushRemindersToWatch()
        } else {
            cancelAllPendingReminderNotifications()
            cancelAllScheduledAlarms()
            let plansSnapshot = reminderLogs
            for log in plansSnapshot where
                log.status == "计划中" &&
                ["iPhone 计划", "iWatch 计划", "闹钟计划"].contains(log.source) &&
                !planResultExists(for: log) {
                appendPlanResult(for: log, status: "取消成功")
            }
            for index in reminders.indices {
                reminders[index].scheduledDates.removeAll()
                reminders[index].scheduledAlarmIDs.removeAll()
            }
            ActivityReminder.saveAll(reminders)
            pushRemindersToWatch()
        }
    }

    // MARK: - 设置：导出 / 导入 / 自动备份

    private func cancelAllPlansAndAlarms() {
        cancelAllPendingReminderNotifications()
        cancelAllScheduledAlarms()
    }

    func exportAllData() throws -> Data {
        let types: [ActivityType]
        let records: [ActivityRecord]
        if let context = modelContext {
            types = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
            records = (try? context.fetch(FetchDescriptor<ActivityRecord>())) ?? []
        } else {
            types = []
            records = []
        }
        let snapshot = ActrailDataSnapshot(
            version: 1,
            exportedAt: Date(),
            activityTypes: types.map { type in
                ActrailBackedActivityType(
                    id: type.id, name: type.name, iconName: type.iconName,
                    color: type.color, group: type.group,
                    createdAt: type.createdAt, isArchived: type.isArchived
                )
            },
            activityRecords: records.map { record in
                ActrailBackedActivityRecord(
                    id: record.id, activityTypeId: record.activityType?.id,
                    startTime: record.startTime, endTime: record.endTime,
                    note: record.note, isActive: record.isActive
                )
            },
            reminders: reminders,
            reminderLogs: reminderLogs
        )
        return try JSONEncoder().encode(snapshot)
    }

    /// 导入数据：先清空 iPhone/iWatch/闹钟排定计划、全部历史与本地数据，
    /// 再用备份内容重建，并重新排定提醒、同步到 iWatch。
    func importAllData(_ data: Data) throws {
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(ActrailDataSnapshot.self, from: data)

        cancelAllPlansAndAlarms()

        guard let context = modelContext else { return }
        for record in (try? context.fetch(FetchDescriptor<ActivityRecord>())) ?? [] {
            context.delete(record)
        }
        for type in (try? context.fetch(FetchDescriptor<ActivityType>())) ?? [] {
            context.delete(type)
        }
        try? context.save()

        for t in snapshot.activityTypes {
            let type = ActivityType(name: t.name, iconName: t.iconName, color: t.color, group: t.group)
            type.id = t.id
            type.createdAt = t.createdAt
            type.isArchived = t.isArchived
            context.insert(type)
        }
        try context.save()

        let fetchedTypes = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
        let typeById = Dictionary(uniqueKeysWithValues: fetchedTypes.map { ($0.id, $0) })

        for r in snapshot.activityRecords {
            guard let type = typeById[r.activityTypeId ?? UUID()] else { continue }
            let record = ActivityRecord(activityType: type)
            record.id = r.id
            record.startTime = r.startTime
            record.endTime = r.endTime
            record.note = r.note
            record.isActive = r.isActive
            context.insert(record)
        }
        try context.save()

        reminders = snapshot.reminders
        ActivityReminder.saveAll(reminders)
        reminderLogs = snapshot.reminderLogs
        ReminderLogEntry.saveAll(reminderLogs)

        fetchActivityTypes()
        fetchTodayRecords()

        if AppSettings.notificationsEnabled {
            extendReminderSchedules()
        }
        rebuildCache()
        pushRemindersToWatch()
        sendSync()
    }

    /// 自动备份：仅当「自动备份」开启且今天还没备份过时执行。
    func performAutoBackupIfNeeded() {
        guard AppSettings.autoBackupEnabled else { return }
        if let last = AppSettings.lastAutoBackupDate, Calendar.current.isDateInToday(last) {
            return
        }
        do {
            let url = try backupDataNow()
            AppSettings.lastAutoBackupDate = Date()
            AppSettings.lastAutoBackupURL = url.lastPathComponent
            print("[Backup] 自动备份完成：\(url.lastPathComponent)")
        } catch {
            print("[Backup] 自动备份失败：\(error)")
        }
    }

    /// 立即导出完整数据并保存到 Documents/Backups，返回文件 URL。
    @discardableResult
    func backupDataNow() throws -> URL {
        let data = try exportAllData()
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("Actrail-\(f.string(from: Date())).json")
        try data.write(to: url)
        return url
    }

    func requestWatchStatus() {
        watchStatusString = "查询中…"
        syncManager.requestWatchStatus()
    }

    func requestWatchWakeLog() {
        syncManager.requestWatchWakeLog()
    }

    var watchSessionStatus: String {
        syncManager.sessionDebugStatus
    }

    /// 调试用：devicectl launch 时设置环境变量 AUTOADD_ACTIVITY=1，
    /// app 启动后自动开始"第一个未在进行中"的活动类型，
    /// 用于自动化验证 iPhone→iWatch 表盘链路（触发进行中活动数变化）。
    func autoStartActivityForDebug() {
        guard let first = activityTypes.first(where: { type in
            !activeRecords.contains(where: { $0.activityType?.id == type.id && $0.isActive })
        }) else {
            print("[AUTOADD] 所有活动类型均在进行中")
            return
        }
        startActivity(first)
        print("[AUTOADD] 已自动开始 \(first.name)")
    }

    /// 调试用：devicectl launch 时设置环境变量 STOP_ALL_ACTIVE=1，
    /// 停止所有进行中活动（activeCount 归零），配合 AUTOADD 做 0→1 归零验证。
    func stopAllActiveForDebug() {
        let running = activeRecords.filter(\.isActive)
        for record in running {
            stopActivity(record)
        }
        // 观测：STOP_ALL 查到/停了几条（用于真机验证跨日 active 是否可停止）
        let ud = UserDefaults.standard
        ud.set(running.count, forKey: "DebugStopFound")
        ud.set(Date(), forKey: "DebugStopTime")
        print("[AUTOSTOP] 已停止 \(running.count) 个进行中活动")
    }

    /// 调试用：串行执行“全停→开始→全停→开始→全停”，一键观察表盘是否跟随 iPhone 变化。
    func runAutoTestSequence() {
        Task { @MainActor in
            stopAllActiveForDebug()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            autoStartActivityForDebug()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            stopAllActiveForDebug()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            autoStartActivityForDebug()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            stopAllActiveForDebug()
        }
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
                self?.settlePhoneNotificationFired(notification)
            }
        }

        reminderDelegate.onTapped = { [weak self] response in
            DispatchQueue.main.async {
                let userInfo = response.notification.request.content.userInfo
                let planID = (userInfo["planID"] as? String).flatMap(UUID.init(uuidString:))
                let reminderID = (userInfo["reminderId"] as? String).flatMap(UUID.init(uuidString:))
                self?.logPhoneNotificationTapped(reminderID: reminderID, planID: planID)
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

    private func settlePhoneNotificationFired(_ notification: UNNotification) {
        let contentObject = notification.request.content
        let presetTime = contentObject.userInfo["presetTime"] as? Date ?? Date()
        let planID = (contentObject.userInfo["planID"] as? String).flatMap(UUID.init(uuidString:))
        let reminderID = (contentObject.userInfo["reminderId"] as? String).flatMap(UUID.init(uuidString:))
        // 回调优先：前台投递时立即为对应「iPhone 计划」追加一条「执行成功」结果记录。
        // 若无匹配的原计划记录（历史数据），合成一条等价的计划记录再结算，保证仍只有一条。
        let planLog: ReminderLogEntry
        if let matched = reminderLogs.first(where: {
            $0.source == "iPhone 计划" &&
            ($0.id == planID || (planID == nil && $0.reminderID == reminderID)) &&
            Self.reminderDayKey($0.presetTime) == Self.reminderDayKey(presetTime)
        }) {
            planLog = matched
        } else {
            planLog = ReminderLogEntry(
                content: "",
                presetTime: presetTime,
                sentTime: Date(),
                sentSuccessfully: true,
                source: "iPhone 计划",
                status: "计划中",
                reminderID: reminderID,
                planID: planID
            )
        }
        appendPlanResult(for: planLog, status: "执行成功")
    }

    private func appendReminderLog(_ entry: ReminderLogEntry) {
        if ["iPhone 计划", "iWatch 计划", "闹钟计划"].contains(entry.source) {
            let alreadyExists = reminderLogs.contains { existing in
                existing.reminderID == entry.reminderID &&
                existing.source == entry.source &&
                existing.content == entry.content &&
                Calendar.current.isDate(existing.presetTime, inSameDayAs: entry.presetTime)
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

    private func appendCancelledEntries(for reminder: ActivityReminder, date: Date, alarmFireTime: Date? = nil) {
        let time = Self.logDateFormatter.string(from: date)
        let alarmAnchor: Date
        if let fireTime = alarmFireTime {
            alarmAnchor = fireTime
        } else {
            let slotForDay = reminder.scheduledDates.first(where: {
                Calendar.current.isDate($0, inSameDayAs: date)
            }) ?? reminderLogs.first(where: {
                $0.reminderID == reminder.id
                    && $0.status == "计划中"
                    && Calendar.current.isDate($0.presetTime, inSameDayAs: date)
            })?.presetTime ?? date
            alarmAnchor = Calendar.current.date(
                byAdding: .minute,
                value: reminder.alarmGraceMinutes,
                to: slotForDay
            ) ?? slotForDay
        }
        let roundedAnchor = Calendar.current.date(
            bySettingHour: Calendar.current.component(.hour, from: alarmAnchor),
            minute: Calendar.current.component(.minute, from: alarmAnchor),
            second: 0,
            of: alarmAnchor
        ) ?? alarmAnchor
        let alarmTime = Self.logDateFormatter.string(from: roundedAnchor)
        let alertPreset = Calendar.current.date(
            byAdding: .minute,
            value: -reminder.alarmGraceMinutes,
            to: roundedAnchor
        ) ?? roundedAnchor
        let iphone = ReminderLogEntry(
            content: "iPhone 计划 \(time) 取消成功（已确认活动，未投递撤销）",
            presetTime: date,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 计划",
            status: "取消成功",
            reminderID: reminder.id
        )
        let watch = ReminderLogEntry(
            content: "iWatch 计划 \(time) 取消成功（已确认活动，未投递撤销）",
            presetTime: date,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iWatch 计划",
            status: "取消成功",
            reminderID: reminder.id
        )
        let alarm = ReminderLogEntry(
            content: "闹钟记录 \(alarmTime) 取消成功（已确认活动）",
            presetTime: alertPreset,
            sentTime: Date(),
            sentSuccessfully: true,
            source: "闹钟计划",
            status: "取消成功",
            reminderID: reminder.id
        )
        // 对应计划已存在执行成功/执行失败（通知已投递）时不再生成「取消成功」，
        // 避免与执行结果并存两条矛盾记录。
        if !planHasExecutionResult("iPhone 计划", reminderID: reminder.id, date: date) {
            appendReminderLog(iphone)
        }
        if !planHasExecutionResult("iWatch 计划", reminderID: reminder.id, date: date) {
            appendReminderLog(watch)
        }
        if reminder.alarmEnabled && !planHasExecutionResult("闹钟计划", reminderID: reminder.id, date: date) {
            appendReminderLog(alarm)
        }
    }

    /// 该提醒当天是否存在「执行成功/执行失败」结果记录。
    private func planHasExecutionResult(_ source: String, reminderID: UUID?, date: Date) -> Bool {
        guard let reminderID else { return false }
        return reminderLogs.contains { candidate in
            candidate.source == source &&
            candidate.reminderID == reminderID &&
            (candidate.status == "执行成功" || candidate.status == "执行失败") &&
            Calendar.current.isDate(candidate.presetTime, inSameDayAs: date)
        }
    }

    func deleteReminderLog(_ log: ReminderLogEntry) {
        reminderLogs.removeAll { $0.id == log.id }
        ReminderLogEntry.saveAll(reminderLogs)
    }

    /// 撤销某提醒某天的底层调度：AlarmKit 闹钟 + 当天 pending 通知。
    /// onResult 返回是否真的移除了底层调度（false = 取消失败，无对象可撤）。
    private func deactivatePlanSlot(reminderID: UUID?, at date: Date, onResult: ((Bool) -> Void)? = nil) {
        let dayKey = Self.reminderDayKey(date)
        var removedSomething = false
        if let reminderID {
            if let idx = reminders.firstIndex(where: { $0.id == reminderID }),
               let alarmID = reminders[idx].scheduledAlarmIDs[dayKey] {
                AlarmKitManager.shared.cancelAlarms(ids: [alarmID])
                reminders[idx].scheduledAlarmIDs.removeValue(forKey: dayKey)
                ActivityReminder.saveAll(reminders)
                removedSomething = true
            }
            let identifier = "reminder-\(reminderID.uuidString)-\(dayKey)"
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                let ids = requests
                    .filter { $0.identifier == identifier }
                    .map(\.identifier)
                if !ids.isEmpty {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
                    removedSomething = true
                }
                DispatchQueue.main.async {
                    onResult?(removedSomething)
                }
            }
        } else {
            onResult?(false)
        }
    }

    /// 闹钟进入响铃状态时，为匹配该闹钟的「闹钟计划」追加「执行成功」。
    private func settleAlarmFired(alarmID: UUID) {
        guard let reminder = reminders.first(where: { $0.scheduledAlarmIDs.values.contains(alarmID) }) else { return }
        for log in reminderLogs where
            log.source == "闹钟计划" &&
            log.status == "计划中" &&
            log.reminderID == reminder.id &&
            reminder.scheduledAlarmIDs[Self.reminderDayKey(log.presetTime)] == alarmID &&
            !planResultExists(for: log) {
            appendPlanResult(for: log, status: "执行成功")
        }
    }

    private func reminderGraceMinutes(for reminderID: UUID?) -> Int {
        guard let reminderID, let reminder = reminders.first(where: { $0.id == reminderID }) else { return 0 }
        return reminder.alarmGraceMinutes
    }

    /// 该闹钟计划的底层闹钟是否已被系统消费（触发时间已过且系统列表中已不存在）。
    private func alarmSlotConsumed(for log: ReminderLogEntry) -> Bool {
        guard let reminder = reminders.first(where: { $0.id == log.reminderID }) else { return false }
        guard let alarmID = reminder.scheduledAlarmIDs[Self.reminderDayKey(log.presetTime)] else { return false }
        guard let alarms = AlarmKitManager.shared.queryAlarms() else { return false }
        return !alarms.contains { $0.id == alarmID }
    }

    /// 计划结果状态：取消/执行操作的落地标记（不修改原「计划中」记录，只追加新记录）
    private static let planResultStatuses: Set<String> = ["取消成功", "取消失败", "执行成功", "执行失败"]

    private func planResultExists(for log: ReminderLogEntry) -> Bool {
        reminderLogs.contains { candidate in
            candidate.reminderID == log.reminderID &&
            candidate.source == log.source &&
            candidate.planID == log.planID &&
            Self.planResultStatuses.contains(candidate.status)
        }
    }

    /// 回调优先：iWatch 上报执行/确认时，立即合并为对应「iWatch 计划」的唯一执行成功，
    /// 不生成「iWatch 本地通知」事件记录。返回能否匹配到原计划；匹配不到才降级保留事件记录。
    private func settleWatchExecutionReported(_ log: ReminderLogEntry) -> Bool {
        let planLog = reminderLogs.first { candidate in
            guard candidate.source == "iWatch 计划" && candidate.status == "计划中" else { return false }
            if let pid = log.planID, let cpid = candidate.planID { return pid == cpid }
            if let rid = log.reminderID, candidate.reminderID == rid {
                return Self.reminderDayKey(candidate.presetTime) == Self.reminderDayKey(log.presetTime)
            }
            return false
        }
        guard let planLog else { return false }
        appendPlanResult(for: planLog, status: "执行成功")
        return true
    }

    private func appendPlanResult(for log: ReminderLogEntry, status: String) {
        // 幂等：同一计划只允许一条结果记录（回调与轮询兜底并发时也不会产生两条）
        guard !planResultExists(for: log) else { return }
        let displayDate: Date
        if log.source == "闹钟计划",
           let grace = reminders.first(where: { $0.id == log.reminderID })?.alarmGraceMinutes {
            displayDate = Calendar.current.date(byAdding: .minute, value: grace, to: log.presetTime) ?? log.presetTime
        } else {
            displayDate = log.presetTime
        }
        let time = Self.logDateFormatter.string(from: displayDate)
        let cancelled = status == "取消成功" || status == "取消失败"
        let executed = status == "执行成功" || status == "执行失败"
        let note: String
        if cancelled {
            note = log.source == "闹钟计划" ? "闹钟已撤销" : "提醒已撤销"
        } else if executed {
            note = "通知/提醒已发出"
        } else {
            note = ""
        }
        appendReminderLog(ReminderLogEntry(
            content: "\(log.source) \(time) \(status)（\(note)）",
            presetTime: log.presetTime,
            sentTime: Date(),
            sentSuccessfully: status != "取消失败" && status != "执行失败",
            source: log.source,
            status: status,
            reminderID: log.reminderID,
            planID: log.planID
        ))
    }

    private func markExpiredPlans() {
        let now = Date()
        // 是否有进行中活动：有活动 = 已确认提醒目的达成 → 三条全部取消；
        // 无活动 = 保留闹钟（让 n 分钟后闹钟再强烈提醒），iPhone/iWatch
        // 计划按「通知是否实际发出」区分为「执行成功」（发出过）或「取消成功」（未发出被撤销）。
        // 已生成的「计划中」记录不再更新状态，操作结果一律追加为新的结果记录。
        // iPhone/闹钟计划的「执行成功」为「回调优先 + 轮询兜底」：前台投递/响铃时
        // 立即由回调结算；后台投递时由本轮询结算。appendPlanResult 幂等，同一计划始终只有一条结果。
        let hasActive = activeRecords.contains { $0.isActive }
        let plansSnapshot = reminderLogs
        for log in plansSnapshot {
            guard log.status == "计划中" else { continue }
            let source = log.source
            let isAlarm = source == "闹钟计划"
            guard source == "iPhone 计划" || source == "iWatch 计划" || isAlarm else { continue }
            guard now > log.presetTime else { continue }
            guard !planResultExists(for: log) else { continue }

            if isAlarm {
                // 无活动时保留闹钟计划，让 n 分钟后闹钟强烈提醒；
                // 若闹钟触发时间已过且系统已无该闹钟（已响并被消费）→ 追加「执行成功」。
                if !hasActive {
                    let fireDate = log.presetTime.addingTimeInterval(
                        TimeInterval(reminderGraceMinutes(for: log.reminderID) * 60)
                    )
                    guard now > fireDate else { continue }
                    if alarmSlotConsumed(for: log) {
                        appendPlanResult(for: log, status: "执行成功")
                    }
                    continue
                }
                deactivatePlanSlot(reminderID: log.reminderID, at: log.presetTime) { ok in
                    self.appendPlanResult(for: log, status: ok ? "取消成功" : "取消失败")
                }
            } else if source == "iWatch 计划" {
                // iWatch 计划的「执行成功」在收到 watch 上报（iWatch 本地通知/已确认）时
                // 即时合并为唯一结算记录（settleWatchExecutionReported，回调优先）；
                // iPhone 无法反查手表端 pending，无独立轮询结算，此处只处理活动确认导致的取消。
                // 未上报前保持「计划中」等待。
                if hasActive {
                    // 已确认活动目的达成：取消意图已同步给 iWatch（pushRemindersToWatch），
                    // iPhone 无法直接撤销手表端通知，故按意图取消记录为「取消成功」。
                    appendPlanResult(for: log, status: "取消成功")
                }
            } else {
                // iPhone 计划：回调已在前台投递时优先结算（见 settlePhoneNotificationFired）；
                // 此处为轮询兜底（后台投递无回调）：pending 反查判定实际投递——
                // slot 到点且仍在 pending = 未投递 → 撤销 → 取消成功/取消失败；
                // slot 到点且不在 pending = 通知已成功发出 → 补「执行成功」。
                // 已投递的判定优先于 hasActive：投递是事实，即使存在进行中活动
                // 也应记「执行成功」，避免已收到的通知反而记成「取消成功」。
                let identifier = "reminder-\(log.reminderID?.uuidString ?? "nil")-\(Self.reminderDayKey(log.presetTime))"
                UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                    let stillPending = requests.contains { $0.identifier == identifier }
                    DispatchQueue.main.async {
                        if stillPending {
                            self.deactivatePlanSlot(reminderID: log.reminderID, at: log.presetTime) { ok in
                                self.appendPlanResult(for: log, status: ok ? "取消成功" : "取消失败")
                            }
                        } else {
                            self.appendPlanResult(for: log, status: "执行成功")
                        }
                    }
                }
            }
        }
    }

    private func logPhoneNotificationTapped(reminderID: UUID?, planID: UUID?) {
        let entry = ReminderLogEntry(
            content: "已确认收到提醒",
            presetTime: Date(),
            sentTime: Date(),
            sentSuccessfully: true,
            source: "iPhone 已确认",
            status: "执行成功",
            reminderID: reminderID,
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
        guard AppSettings.notificationsEnabled else { return }
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

    private func planFailureEntry(for reminder: ActivityReminder, date: Date, detail: String, source: String) -> ReminderLogEntry {
        let time = Self.logDateFormatter.string(from: date)
        return ReminderLogEntry(
            content: "计划失败 \(time)：\(detail)",
            presetTime: date,
            sentTime: Date(),
            sentSuccessfully: false,
            source: source,
            status: "排定失败",
            reminderID: reminder.id
        )
    }

    private func scheduleReminderSlot(_ reminder: ActivityReminder, at date: Date) {
        guard reminder.isEnabled else { return }
        let entries = self.makePlanEntries(for: reminder, date: date)
        // 发起排定即先记录计划日志，保证提醒历史立即有对应记录；
        // 实际注册通知随后进行，失败时再补一条失败日志。
        self.appendReminderLog(entries.iPhone)
        self.appendReminderLog(entries.iWatch)
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional ||
                  settings.authorizationStatus == .ephemeral else {
                print("[Reminder] permission not granted, cannot schedule slot")
                DispatchQueue.main.async {
                    self.appendReminderLog(self.planFailureEntry(for: reminder, date: date, detail: "通知未授权，无法排队投递", source: "iPhone 计划"))
                    self.appendReminderLog(self.planFailureEntry(for: reminder, date: date, detail: "通知未授权，无法排队投递", source: "iWatch 计划"))
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "行迹提醒"
            content.body = "请检查当前正在进行的活动是否正确"
            content.sound = reminder.alarmSound == "none" ? nil : .default
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
                    DispatchQueue.main.async {
                        self.appendReminderLog(self.planFailureEntry(for: reminder, date: date, detail: error.localizedDescription, source: "iPhone 计划"))
                        self.appendReminderLog(self.planFailureEntry(for: reminder, date: date, detail: error.localizedDescription, source: "iWatch 计划"))
                    }
                } else {
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
        let content = "闹钟已排定 \(f.string(from: alarmDate))"
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

    // MARK: - 统计趋势数据

    func dateRange(for period: String) -> DateInterval {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case "本周":
            let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return DateInterval(start: startOfWeek, end: now)
        case "本月":
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return DateInterval(start: startOfMonth, end: now)
        default: // 今日
            let startOfDay = calendar.startOfDay(for: now)
            return DateInterval(start: startOfDay, end: now)
        }
    }

    func fetchRecords(from startDate: Date, to endDate: Date) -> [ActivityRecord] {
        guard let context = modelContext else { return [] }
        let predicate = #Predicate<ActivityRecord> { record in
            record.startTime >= startDate && record.startTime < endDate && !record.isActive
        }
        let descriptor = FetchDescriptor<ActivityRecord>(predicate: predicate, sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func getAggregatedStats(from startDate: Date, to endDate: Date) -> (totalSeconds: Int, recordCount: Int) {
        let records = fetchRecords(from: startDate, to: endDate)
        let total = records.reduce(0) { $0 + Int($1.duration) }
        return (total, records.count)
    }

    func getActivityDistribution(from startDate: Date, to endDate: Date) -> [(type: String, seconds: Int, color: String)] {
        let records = fetchRecords(from: startDate, to: endDate)
        var dict: [String: (seconds: Int, color: String)] = [:]
        for record in records {
            let name = record.activityType?.name ?? "未知"
            let color = record.activityType?.color ?? "#8E8E93"
            let existing = dict[name, default: (0, color)]
            dict[name] = (existing.seconds + Int(record.duration), color)
        }
        return dict.map { (type: $0.key, seconds: $0.value.seconds, color: $0.value.color) }
            .sorted { $0.seconds > $1.seconds }
    }

    func getActivityRanking(from startDate: Date, to endDate: Date) -> [(name: String, seconds: Int, color: String)] {
        let distribution = getActivityDistribution(from: startDate, to: endDate)
        return distribution.map { (name: $0.type, seconds: $0.seconds, color: $0.color) }
    }

    func formatDurationHuman(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 { return "\(totalSeconds)秒" }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)小时\(minutes)分钟" }
        if hours > 0 { return "\(hours)小时" }
        return "\(minutes)分钟"
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

// MARK: - 数据快照（导出 / 导入）

struct ActrailBackedActivityType: Codable {
    var id: UUID
    var name: String
    var iconName: String
    var color: String
    var group: String
    var createdAt: Date
    var isArchived: Bool
}

struct ActrailBackedActivityRecord: Codable {
    var id: UUID
    var activityTypeId: UUID?
    var startTime: Date
    var endTime: Date?
    var note: String
    var isActive: Bool
}

struct ActrailDataSnapshot: Codable {
    var version: Int
    var exportedAt: Date
    var activityTypes: [ActrailBackedActivityType]
    var activityRecords: [ActrailBackedActivityRecord]
    var reminders: [ActivityReminder]
    var reminderLogs: [ReminderLogEntry]
}
