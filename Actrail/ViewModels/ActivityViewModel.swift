import Foundation
import SwiftData
import SwiftUI

@Observable
class ActivityViewModel {
    var activityTypes: [ActivityType] = []
    var activeRecords: [ActivityRecord] = []
    var todayRecords: [ActivityRecord] = []
    var selectedDate: Date = Date()
    var isWatchReachable = false

    private var modelContext: ModelContext?
    private let syncManager = WatchSyncManager.shared
    private var syncTimer: Timer?

    private var cachedTypes: [WatchSyncManager.SyncedActivityType] = []
    private var cachedActiveRecords: [WatchSyncManager.SyncedActivityRecord] = []
    private var cachedCompletedRecords: [WatchSyncManager.SyncedActivityRecord] = []

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchActivityTypes()
        fetchTodayRecords()

        if activityTypes.isEmpty {
            insertSampleData()
            fetchActivityTypes()
        }

        setupSyncManager()
        setupNotifications()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rebuildCache()
            self?.sendSync()
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

    private func setupNotifications() {
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
