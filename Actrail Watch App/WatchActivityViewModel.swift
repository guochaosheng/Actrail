import Foundation
import WatchConnectivity

@Observable
class WatchActivityViewModel {
    var activityTypes: [WatchActivityType] = []
    var activeRecords: [WatchActivityRecord] = []
    var completedRecords: [WatchActivityRecord] = []
    var isReachable = false

    private let syncManager = WatchSyncManager.shared
    private var syncTimer: Timer?

    init() {
        setupSyncListener()
        setupReachabilityObserver()
        requestInitialData()
    }

    deinit {
        syncTimer?.invalidate()
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

    private func setupSyncListener() {
        syncManager.onDataUpdate = { [weak self] data in
            Task { @MainActor in
                self?.handleSyncData(data)
            }
        }
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

            let active = message.activeRecords.filter { $0.isActive }.map { syncRecord -> WatchActivityRecord in
                let type = types.first(where: { $0.id == syncRecord.activityTypeId })
                return WatchActivityRecord(
                    id: syncRecord.id,
                    activityType: type ?? WatchActivityType(name: "未知", iconName: "questionmark", color: "#8E8E93"),
                    startTime: syncRecord.startTime,
                    endTime: syncRecord.endTime,
                    isActive: syncRecord.isActive
                )
            }

            let completed = message.completedRecords.filter { !$0.isActive }.map { syncRecord -> WatchActivityRecord in
                let type = types.first(where: { $0.id == syncRecord.activityTypeId })
                return WatchActivityRecord(
                    id: syncRecord.id,
                    activityType: type ?? WatchActivityType(name: "未知", iconName: "questionmark", color: "#8E8E93"),
                    startTime: syncRecord.startTime,
                    endTime: syncRecord.endTime,
                    isActive: syncRecord.isActive
                )
            }

            self.activityTypes = types
            self.activeRecords = active
            self.completedRecords = completed
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
