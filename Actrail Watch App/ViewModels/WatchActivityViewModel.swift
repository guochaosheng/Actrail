import Foundation

class WatchActivityViewModel: ObservableObject {
    @Published var activityTypes: [WatchActivityType] = []
    @Published var activeRecords: [WatchActivityRecord] = []
    @Published var completedRecords: [WatchActivityRecord] = []
    
    private let syncManager = WatchSyncManager.shared
    
    init() {
        loadSampleData()
        setupSyncListener()
    }
    
    private func setupSyncListener() {
        syncManager.startDataUpdateHandler { [weak self] data in
            Task { @MainActor in
                self?.handleSyncData(data)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .watchActivityAction,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAction(notification: notification)
            }
        }
    }
    
    private func handleSyncData(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(WatchSyncManager.SyncMessage.self, from: data)
            
            self.activityTypes = message.activityTypes.map { syncType in
                WatchActivityType(
                    id: syncType.id,
                    name: syncType.name,
                    iconName: syncType.iconName,
                    color: syncType.color
                )
            }
            
            self.activeRecords = message.activeRecords.filter { $0.isActive }.map { syncRecord in
                let type = activityTypes.first(where: { $0.id == syncRecord.activityTypeId })
                return WatchActivityRecord(
                    id: syncRecord.id,
                    activityType: type ?? WatchActivityType(name: "未知", iconName: "questionmark", color: "#8E8E93"),
                    startTime: syncRecord.startTime,
                    endTime: syncRecord.endTime,
                    isActive: syncRecord.isActive
                )
            }
            
            self.completedRecords = message.completedRecords.filter { !$0.isActive }.map { syncRecord in
                let type = activityTypes.first(where: { $0.id == syncRecord.activityTypeId })
                return WatchActivityRecord(
                    id: syncRecord.id,
                    activityType: type ?? WatchActivityType(name: "未知", iconName: "questionmark", color: "#8E8E93"),
                    startTime: syncRecord.startTime,
                    endTime: syncRecord.endTime,
                    isActive: syncRecord.isActive
                )
            }
            
            lastSyncDate = message.timestamp
        } catch {
            print("Failed to decode sync data: \(error)")
        }
    }
    
    private func handleAction(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let action = userInfo["action"] as? String else { return }
        
        // 处理来自 iPhone 的操作
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
    
    func loadSampleData() {
        activityTypes = [
            WatchActivityType(name: "工作", iconName: "briefcase.fill", color: "#007AFF"),
            WatchActivityType(name: "运动", iconName: "figure.run", color: "#34C759"),
            WatchActivityType(name: "阅读", iconName: "book.fill", color: "#FF9500"),
            WatchActivityType(name: "睡眠", iconName: "moon.fill", color: "#5856D6"),
            WatchActivityType(name: "用餐", iconName: "fork.knife", color: "#FF2D55"),
            WatchActivityType(name: "通勤", iconName: "car.fill", color: "#8E8E93")
        ]
    }
    
    func startActivity(_ type: WatchActivityType) {
        if activeRecords.contains(where: { $0.activityType.id == type.id && $0.isActive }) {
            return
        }
        
        let record = WatchActivityRecord(activityType: type)
        activeRecords.append(record)
        
        // 同步到 iPhone
        syncManager.sendActivityStart(typeId: type.id)
    }
    
    func stopActivity(_ record: WatchActivityRecord) {
        if let index = activeRecords.firstIndex(where: { $0.id == record.id }) {
            var updatedRecord = record
            updatedRecord.stop()
            activeRecords.remove(at: index)
            completedRecords.insert(updatedRecord, at: 0)
            
            // 同步到 iPhone
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
    
    private var lastSyncDate: Date?
}

// 使用新的类型名称避免与 iPhone 端冲突
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
