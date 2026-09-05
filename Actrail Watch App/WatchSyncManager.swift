import Foundation
@preconcurrency import WatchConnectivity
import Observation

@Observable
class WatchSyncManager {
    static let shared = WatchSyncManager()

    var isReachable = false
    var lastSyncDate: Date?

    var onDataUpdate: ((Data) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onReminderTest: (() -> Void)?
    var onQueryWatchStatus: (() -> Void)?

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
    }

    struct WatchReminderLogEntry: Codable {
        var id: UUID
        var content: String
        var presetTime: Date
        var sentTime: Date
        var sentSuccessfully: Bool
        var source: String

        init(content: String, presetTime: Date, sentTime: Date, sentSuccessfully: Bool, source: String) {
            self.id = UUID()
            self.content = content
            self.presetTime = presetTime
            self.sentTime = sentTime
            self.sentSuccessfully = sentSuccessfully
            self.source = source
        }
    }

    struct SyncMessage: Codable {
        let activityTypes: [SyncedActivityType]
        let activeRecords: [SyncedActivityRecord]
        let completedRecords: [SyncedActivityRecord]
        let reminders: [SyncedReminder]
        let timestamp: Date
    }

    private nonisolated let delegateBox = DelegateBox()

    private init() {
        delegateBox.syncManager = self
    }

    func startSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = delegateBox
        session.activate()
    }

    func startDataUpdateHandler(_ handler: @escaping (Data) -> Void) {
        self.onDataUpdate = handler
    }

    func requestDataFromiPhone() {
        let session = WCSession.default
        let reachable = session.isReachable
        if reachable != isReachable {
            isReachable = reachable
            Task { @MainActor in onReachabilityChange?(reachable) }
        }
        let userInfo: [String: Any] = ["action": "requestData"]
        if reachable {
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[Watch Sync] requestData failed: \(error)")
            }
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func sendActivityStart(typeId: UUID) {
        let session = WCSession.default
        let reachable = session.isReachable
        if reachable != isReachable {
            isReachable = reachable
            Task { @MainActor in onReachabilityChange?(reachable) }
        }
        let userInfo: [String: Any] = ["action": "startActivity", "typeId": typeId.uuidString]
        if reachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func sendActivityStop(recordId: UUID) {
        let session = WCSession.default
        let reachable = session.isReachable
        if reachable != isReachable {
            isReachable = reachable
            Task { @MainActor in onReachabilityChange?(reachable) }
        }
        let userInfo: [String: Any] = ["action": "stopActivity", "recordId": recordId.uuidString]
        if reachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func sendReminderLog(_ log: WatchReminderLogEntry) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        let session = WCSession.default
        let userInfo: [String: Any] = ["action": "reminderLog", "log": data]
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func sendWatchStatus(_ status: [String: Any]) {
        let session = WCSession.default
        let payload: [String: Any] = ["watchStatus": status]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
    }

    func handleReceivedPayload(_ payload: [String: Any]) {
        if let action = payload["action"] as? String, action == "reminderTest" {
            Task { @MainActor in
                onReminderTest?()
            }
        }
        if let action = payload["action"] as? String, action == "queryWatchStatus" {
            Task { @MainActor in
                onQueryWatchStatus?()
            }
        }
        if let data = payload["activityData"] as? Data {
            lastSyncDate = Date()
            Task { @MainActor in
                onDataUpdate?(data)
            }
        }
    }
}

class DelegateBox: NSObject, WCSessionDelegate, @unchecked Sendable {
    weak var syncManager: WatchSyncManager?

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            syncManager?.isReachable = session.isReachable
            syncManager?.onReachabilityChange?(session.isReachable)
        }
        print("[Watch Sync] WCSession activated: state=\(activationState.rawValue), reachable=\(session.isReachable)")
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("[Watch Sync] received message: \(message.keys.sorted())")
        syncManager?.handleReceivedPayload(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        print("[Watch Sync] received userInfo: \(userInfo.keys.sorted())")
        syncManager?.handleReceivedPayload(userInfo)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            syncManager?.isReachable = session.isReachable
            syncManager?.onReachabilityChange?(session.isReachable)
        }
        print("[Watch Sync] reachability changed: \(session.isReachable)")
    }

}
