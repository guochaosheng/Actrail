import Foundation
import WatchConnectivity
import Observation

@Observable
class WatchSyncManager {
    static let shared = WatchSyncManager()

    var isReachable = false
    var lastSyncDate: Date?

    var onDataUpdate: ((Data) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?

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

    struct SyncMessage: Codable {
        let activityTypes: [SyncedActivityType]
        let activeRecords: [SyncedActivityRecord]
        let completedRecords: [SyncedActivityRecord]
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

    func handleReceivedPayload(_ payload: [String: Any]) {
        if let data = payload["activityData"] as? Data {
            lastSyncDate = Date()
            Task { @MainActor in
                onDataUpdate?(data)
            }
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
        print("[Watch Sync] WCSession activated: state=\(activationState.rawValue), reachable=\(session.isReachable)")
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("[Watch Sync] received message: \(message.keys.sorted())")
        syncManager?.handleReceivedPayload(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        print("[Watch Sync] received userInfo: \(userInfo.keys.sorted())")
        syncManager?.handleReceivedPayload(userInfo)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            syncManager?.isReachable = session.isReachable
            syncManager?.onReachabilityChange?(session.isReachable)
        }
        print("[Watch Sync] reachability changed: \(session.isReachable)")
    }
}
