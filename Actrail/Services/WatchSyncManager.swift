import Foundation
import WatchConnectivity
import Observation

@Observable
class WatchSyncManager {
    static let shared = WatchSyncManager()

    var isReachable = false
    var lastSyncDate: Date?

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

        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[iPhone Sync] sendMessage failed: \(error)")
            }
        } else {
            session.transferUserInfo(userInfo)
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

    func handleReceivedPayload(_ payload: [String: Any]) {
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
