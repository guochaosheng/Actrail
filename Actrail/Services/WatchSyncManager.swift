import Foundation
import WatchConnectivity
import Observation
import os

let iphoneSyncLog = Logger(subsystem: "com.actrail.app", category: "iphoneSync")

@Observable
class WatchSyncManager {
    static let shared = WatchSyncManager()

    var isReachable = false
    var lastSyncDate: Date?
    fileprivate var lastActivityData: Data?

    var onActivityUpdate: (([SyncedActivityType], [SyncedActivityRecord]) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onReminderLogReceived: ((ReminderLogEntry) -> Void)?
    var onWatchStatusReceived: (([String: Any]) -> Void)?

    struct SyncedActivityType: Codable, Identifiable {
        let id: UUID
        let name: String
        let iconName: String
        let color: String
        let group: String
    }

    struct SyncedActivityRecord: Codable, Identifiable {
        let id: UUID
        let activityTypeId: UUID
        let startTime: Date
        let endTime: Date?
        let isActive: Bool
        let note: String
    }

    struct SyncedReminder: Codable, Identifiable {
        let id: UUID
        let date: Date
        let watchPlanID: UUID?
        let plansByDay: [String: String]?
    }

    struct SyncMessage: Codable {
        let activityTypes: [SyncedActivityType]
        let activeRecords: [SyncedActivityRecord]
        let completedRecords: [SyncedActivityRecord]
        let reminders: [SyncedReminder]
        let timestamp: Date
    }

    private let delegateBox = DelegateBox()

    private init() {
        delegateBox.syncManager = self
    }

    func startSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = delegateBox
        session.activate()
    }

    func startActivityUpdateHandler(_ handler: @escaping ([SyncedActivityType], [SyncedActivityRecord]) -> Void) {
        self.onActivityUpdate = handler
    }

    private var lastComplicationCount: Int?

    func sendActivityUpdate(types: [SyncedActivityType], activeRecords: [SyncedActivityRecord], completedRecords: [SyncedActivityRecord], reminders: [SyncedReminder]) {
        let message = SyncMessage(
            activityTypes: types,
            activeRecords: activeRecords,
            completedRecords: completedRecords,
            reminders: reminders,
            timestamp: Date()
        )

        guard let data = try? JSONEncoder().encode(message) else {
            print("[iPhone Sync] Failed to encode")
            return
        }

        let userInfo: [String: Any] = ["activityData": data]
        let session = WCSession.default

        lastActivityData = data

        print("[iPhone Sync] sendActivityUpdate: active=\(activeRecords.filter(\.isActive).count), completed=\(completedRecords.count), activated=\(session.activationState == .activated)")

        if session.activationState == .activated {
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[iPhone Sync] sendMessage failed: \(error)，改用 transferUserInfo 兜底")
                WCSession.default.transferUserInfo(userInfo)
            }
            // applicationContext 兜底：即使 watch app 未运行也保留最新快照，
            // watch 端 didReceiveApplicationContext 收到后会立即更新 AppGroup 与 widget。
            try? session.updateApplicationContext(userInfo)
            print("[iPhone Sync] applicationContext updated")
        } else {
            session.transferUserInfo(userInfo)
        }

        // 表盘专用通道：仅在进行中活动数变化时发送。
        // transferCurrentComplicationUserInfo 是 iOS→watchOS 官方机制：
        // 即使 watch app 未运行，watch 系统也会后台启动它处理并刷新表盘。
        let activeCount = activeRecords.filter(\.isActive).count
        if session.activationState == .activated, activeCount != lastComplicationCount {
            lastComplicationCount = activeCount
            session.transferCurrentComplicationUserInfo(["activityData": data])
            print("[iPhone Sync] sent complication user info (activeCount=\(activeCount))")
        }

        lastSyncDate = Date()
    }

    func sendActivityStart(typeId: UUID) {
        let userInfo: [String: Any] = ["action": "startActivity", "typeId": typeId.uuidString]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func sendActivityStop(recordId: UUID) {
        let userInfo: [String: Any] = ["action": "stopActivity", "recordId": recordId.uuidString]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func sendReminderTest() {
        let userInfo: [String: Any] = ["action": "reminderTest"]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[iPhone Sync] reminderTest failed: \(error)")
            }
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func requestWatchStatus() {
        let userInfo: [String: Any] = ["action": "queryWatchStatus"]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[iPhone Sync] queryWatchStatus failed: \(error)")
            }
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func requestWatchWakeLog() {
        let userInfo: [String: Any] = ["action": "queryWakeLog"]
        let session = WCSession.default
        if session.isReachable {
            iphoneSyncLog.info("请求 iWatch 全量唤醒日志")
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[iPhone Sync] queryWakeLog failed: \(error)")
            }
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func handleReceivedPayload(_ payload: [String: Any]) {
        if let data = payload["wakeLog"] as? Data,
           let entries = try? JSONDecoder().decode([WatchWakeLogEntry].self, from: data) {
            print("[iPhone Sync] 收到 iWatch 唤醒日志 \(entries.count) 条")
            iphoneSyncLog.info("收到 iWatch 唤醒日志 \(entries.count, privacy: .public) 条，最新：\(entries.last?.msg ?? "-", privacy: .public)")
            WakeLogStore.shared.merge(entries)
            return
        }
        if let action = payload["action"] as? String, action == "reminderLog" {
            if let data = payload["log"] as? Data,
               let log = try? JSONDecoder().decode(ReminderLogEntry.self, from: data) {
                Task { @MainActor in
                    onReminderLogReceived?(log)
                }
            }
        }
        if let status = payload["watchStatus"] as? [String: Any] {
            Task { @MainActor in
                onWatchStatusReceived?(status)
            }
        }
        if let data = payload["activityData"] as? Data {
            let message = try? JSONDecoder().decode(SyncMessage.self, from: data)
            if let message {
                lastSyncDate = message.timestamp
                Task { @MainActor in
                    onActivityUpdate?(message.activityTypes, message.activeRecords)
                }
            }
        } else if let action = payload["action"] as? String {
            if action == "requestData" {
                NotificationCenter.default.post(name: .watchRequestedData, object: nil)
            }
            NotificationCenter.default.post(name: .watchActivityAction, object: nil, userInfo: payload)
        }
    }
}

class DelegateBox: NSObject, WCSessionDelegate {
    weak var syncManager: WatchSyncManager?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            syncManager?.isReachable = session.isReachable
            syncManager?.onReachabilityChange?(session.isReachable)
        }
        print("[iPhone Sync] WCSession activated: state=\(activationState.rawValue), reachable=\(session.isReachable)")
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("[iPhone Sync] received message: \(message.keys.sorted())")
        syncManager?.handleReceivedPayload(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        print("[iPhone Sync] received message(reply): \(message.keys.sorted())")
        // 手表主动拉取请求 → 立即用最新快照同步回复，保证模拟器/真机都能即时拿到数据
        if let action = message["action"] as? String, action == "requestData" {
            if let data = syncManager?.lastActivityData {
                replyHandler(["activityData": data])
            } else {
                replyHandler([:])
            }
        } else {
            syncManager?.handleReceivedPayload(message)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        print("[iPhone Sync] received userInfo: \(userInfo.keys.sorted())")
        syncManager?.handleReceivedPayload(userInfo)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            syncManager?.isReachable = session.isReachable
            syncManager?.onReachabilityChange?(session.isReachable)
        }
        print("[iPhone Sync] reachability changed: \(session.isReachable)")
        if session.isReachable {
            NotificationCenter.default.post(name: .watchDidBecomeReachable, object: nil)
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif
}

extension Notification.Name {
    static let watchActivityAction = Notification.Name("watchActivityAction")
    static let activityDataUpdated = Notification.Name("activityDataUpdated")
    static let watchRequestedData = Notification.Name("watchRequestedData")
    static let watchDidBecomeReachable = Notification.Name("watchDidBecomeReachable")
}

struct WatchWakeLogEntry: Codable, Identifiable {
    let id: UUID
    let t: Date
    let msg: String
}

@Observable
final class WakeLogStore {
    static let shared = WakeLogStore()
    private(set) var entries: [WatchWakeLogEntry] = []
    private let lock = NSLock()
    private static let storeKey = "wakeLogStore"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([WatchWakeLogEntry].self, from: data) {
            entries = saved
        }
    }

    func merge(_ incoming: [WatchWakeLogEntry]) {
        lock.lock()
        defer { lock.unlock() }
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: incoming.filter { !known.contains($0.id) })
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        persistLocked()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
