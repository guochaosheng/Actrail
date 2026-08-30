import Foundation
import SwiftData
import SwiftUI
import Combine

@MainActor
class ActivityViewModel: ObservableObject {
    @Published var activityTypes: [ActivityType] = []
    @Published var activeRecords: [ActivityRecord] = []
    @Published var todayRecords: [ActivityRecord] = []
    @Published var selectedDate: Date = Date()
    @Published var isWatchReachable = false
    
    private var modelContext: ModelContext?
    private let syncManager = WatchSyncManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var syncTimer: Timer?
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchActivityTypes()
        fetchTodayRecords()
        
        if activityTypes.isEmpty {
            insertSampleData()
            fetchActivityTypes()
        }
        
        setupSyncListener()
        syncToWatch()

        syncManager.$isReachable
            .receive(on: DispatchQueue.main)
            .assign(to: &$isWatchReachable)
        
        // 每 5 秒自动同步一次，确保 Watch 能收到最新数据
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.activeRecords.isEmpty else { return }
                self.syncToWatch()
            }
        }
    }
    
    private func setupSyncListener() {
        syncManager.startActivityUpdateHandler { [weak self] types, records in
            Task { @MainActor in
                self?.handleWatchUpdate(types: types, records: records)
            }
        }
        
        // Watch 请求数据
        NotificationCenter.default.addObserver(
            forName: .watchRequestedData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("Watch requested data, sending sync")
                self?.syncToWatch()
            }
        }
        
        // Watch 变为可达时自动发送数据
        NotificationCenter.default.addObserver(
            forName: .watchDidBecomeReachable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("Watch became reachable, sending sync")
                self?.syncToWatch()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .watchActivityAction,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleWatchAction(notification: notification)
            }
        }
    }
    
    private func handleWatchUpdate(types: [WatchSyncManager.SyncedActivityType], records: [WatchSyncManager.SyncedActivityRecord]) {
        // 从Watch同步数据到iPhone
        for record in records where record.isActive {
            if let type = activityTypes.first(where: { $0.id == record.activityTypeId }) {
                if !activeRecords.contains(where: { $0.id == record.id }) {
                    let newRecord = ActivityRecord(activityType: type, startTime: record.startTime)
                    if let context = modelContext {
                        context.insert(newRecord)
                        try? context.save()
                        activeRecords.append(newRecord)
                    }
                }
            }
        }
    }
    
    private func handleWatchAction(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let action = userInfo["action"] as? String else { return }
        
        switch action {
        case "startActivity":
            if let typeIdString = userInfo["typeId"] as? String,
               let typeId = UUID(uuidString: typeIdString),
               let type = activityTypes.first(where: { $0.id == typeId }) {
                startActivity(type)
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
        
        // 检查是否有同类型活动正在运行
        if activeRecords.contains(where: { $0.activityType?.id == type.id && $0.isActive }) {
            return
        }
        
        let record = ActivityRecord(activityType: type)
        context.insert(record)
        activeRecords.append(record)
        todayRecords.insert(record, at: 0)
        
        do {
            try context.save()
            syncToWatch()
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
            syncToWatch()
        } catch {
            print("Failed to save activity record: \(error)")
        }
    }
    
    func addActivityType(name: String, iconName: String, color: String, group: String) {
        guard let context = modelContext else { return }
        let type = ActivityType(name: name, iconName: iconName, color: color, group: group)
        context.insert(type)
        
        do {
            try context.save()
            fetchActivityTypes() // 刷新列表
        } catch {
            print("Failed to save activity type: \(error)")
        }
    }
    
    func deleteActivityType(_ type: ActivityType) {
        guard let context = modelContext else { return }
        context.delete(type)
        
        do {
            try context.save()
            fetchActivityTypes() // 刷新列表
        } catch {
            print("Failed to delete activity type: \(error)")
        }
    }
    
    func syncToWatch() {
        print("syncToWatch: types=\(activityTypes.count), active=\(activeRecords.count), today=\(todayRecords.count)")
        let syncedTypes = activityTypes.map { type in
            WatchSyncManager.SyncedActivityType(
                id: type.id,
                name: type.name,
                iconName: type.iconName,
                color: type.color,
                group: type.group
            )
        }
        
        let syncedActiveRecords = activeRecords.map { record in
            WatchSyncManager.SyncedActivityRecord(
                id: record.id,
                activityTypeId: record.activityType?.id ?? UUID(),
                startTime: record.startTime,
                endTime: record.endTime,
                isActive: record.isActive,
                note: record.note
            )
        }
        
        let syncedCompletedRecords = todayRecords
            .filter { !$0.isActive }
            .map { record in
                WatchSyncManager.SyncedActivityRecord(
                    id: record.id,
                    activityTypeId: record.activityType?.id ?? UUID(),
                    startTime: record.startTime,
                    endTime: record.endTime,
                    isActive: record.isActive,
                    note: record.note
                )
            }
        
        syncManager.sendActivityUpdate(
            types: syncedTypes,
            activeRecords: syncedActiveRecords,
            completedRecords: syncedCompletedRecords
        )
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
