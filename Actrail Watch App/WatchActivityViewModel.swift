import Foundation
import WatchConnectivity
import Combine

@MainActor
class WatchActivityViewModel: ObservableObject {
    @Published var activityTypes: [WatchActivityType] = []
    @Published var activeRecords: [WatchActivityRecord] = []
    @Published var completedRecords: [WatchActivityRecord] = []
    @Published var isReachable = false
    
    private let syncManager = WatchSyncManager.shared
    private var retryCount = 0
    private let maxRetries = 20
    private var retryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupSyncListener()
        setupReachabilityObserver()
        requestInitialData()
        tryLoadApplicationContext()
    }

    deinit {
        retryTimer?.invalidate()
    }

    private func tryLoadApplicationContext() {
        if let data = syncManager.loadApplicationContextData() {
            print("[Watch VM] Loading applicationContext on launch")
            handleSyncData(data)
        }
    }

    private func setupReachabilityObserver() {
        syncManager.$isReachable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reachable in
                guard let self else { return }
                self.isReachable = reachable
                if reachable {
                    print("[Watch VM] Watch became reachable, requesting data")
                    self.retryCount = 0
                    self.requestData()
                }
            }
            .store(in: &cancellables)
    }

    private func requestInitialData() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            print("[Watch VM] Initial data request (retry \(self.retryCount), reachable=\(self.syncManager.isReachable))")
            self.syncManager.requestDataFromiPhone()
            self.startRetryTimer()
        }
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if self.retryCount >= self.maxRetries {
                    print("[Watch VM] Stopping retry after max attempts")
                    timer.invalidate()
                    return
                }
                self.retryCount += 1
                print("[Watch VM] Retrying data request (\(self.retryCount)/\(self.maxRetries))")
                self.syncManager.requestDataFromiPhone()
            }
        }
    }

    private func requestData() {
        print("[Watch VM] Requesting data from iPhone")
        syncManager.requestDataFromiPhone()
    }

    private func setupSyncListener() {
        syncManager.startDataUpdateHandler { [weak self] data in
            Task { @MainActor in
                self?.handleSyncData(data)
            }
        }
    }

    private func handleSyncData(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(WatchSyncManager.SyncMessage.self, from: data)
            print("[Watch VM] Received sync: types=\(message.activityTypes.count), active=\(message.activeRecords.count), completed=\(message.completedRecords.count)")

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
            self.retryCount = self.maxRetries
            retryTimer?.invalidate()
            print("[Watch VM] Updated UI: \(active.count) active, \(completed.count) completed, \(types.count) types")
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
