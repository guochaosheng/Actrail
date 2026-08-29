import Foundation
import WatchConnectivity

class WatchSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    
    @Published var isReachable = false
    @Published var lastSyncDate: Date?
    
    private var session: WCSession?
    private var onActivityUpdate: (([SyncedActivityType], [SyncedActivityRecord]) -> Void)?
    
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
    
    override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }
    
    func startActivityUpdateHandler(_ handler: @escaping ([SyncedActivityType], [SyncedActivityRecord]) -> Void) {
        self.onActivityUpdate = handler
    }
    
    func sendActivityUpdate(types: [SyncedActivityType], activeRecords: [SyncedActivityRecord], completedRecords: [SyncedActivityRecord]) {
        guard let session = session else {
            print("[iPhone Sync] WCSession not available")
            return
        }
        
        let message = SyncMessage(
            activityTypes: types,
            activeRecords: activeRecords,
            completedRecords: completedRecords,
            timestamp: Date()
        )
        
        guard let data = try? JSONEncoder().encode(message) else {
            print("[iPhone Sync] Failed to encode")
            return
        }
        
        let userInfo: [String: Any] = ["activityData": data]
        
        if session.isReachable {
            // 前台实时发送
            session.sendMessage(userInfo, replyHandler: { reply in
                print("[iPhone Sync] sendMessage succeeded: \(reply)")
            }, errorHandler: { error in
                print("[iPhone Sync] sendMessage failed: \(error), falling back to transferUserInfo")
                session.transferUserInfo(userInfo)
            })
            print("[iPhone Sync] sendMessage sent (reachable)")
        } else {
            // 后台排队发送
            session.transferUserInfo(userInfo)
            print("[iPhone Sync] transferUserInfo queued")
        }
        
        lastSyncDate = Date()
    }
    
    func sendActivityStart(typeId: UUID) {
        guard let session = session else { return }
        let userInfo: [String: Any] = ["action": "startActivity", "typeId": typeId.uuidString]
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: { _ in
                session.transferUserInfo(userInfo)
            })
        } else {
            session.transferUserInfo(userInfo)
        }
    }
    
    func sendActivityStop(recordId: UUID) {
        guard let session = session else { return }
        let userInfo: [String: Any] = ["action": "stopActivity", "recordId": recordId.uuidString]
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: { _ in
                session.transferUserInfo(userInfo)
            })
        } else {
            session.transferUserInfo(userInfo)
        }
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
        print("[iPhone Sync] WCSession activated: state=\(activationState.rawValue), reachable=\(session.isReachable)")
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("[iPhone Sync] received message: \(message.keys.sorted())")
        handleReceivedPayload(message)
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        print("[iPhone Sync] received userInfo: \(userInfo.keys.sorted())")
        handleReceivedPayload(userInfo)
    }
    
    private func handleReceivedPayload(_ payload: [String: Any]) {
        if let data = payload["activityData"] as? Data {
            do {
                let message = try JSONDecoder().decode(SyncMessage.self, from: data)
                DispatchQueue.main.async {
                    self.lastSyncDate = message.timestamp
                    self.onActivityUpdate?(message.activityTypes, message.activeRecords)
                }
            } catch {
                print("[iPhone Sync] Failed to decode: \(error)")
            }
        } else if let action = payload["action"] as? String {
            print("[iPhone Sync] received action: \(action)")
            if action == "requestData" {
                NotificationCenter.default.post(name: .watchRequestedData, object: nil)
            }
            NotificationCenter.default.post(name: .watchActivityAction, object: nil, userInfo: payload)
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
        print("[iPhone Sync] reachability changed: \(session.isReachable)")
        if session.isReachable {
            NotificationCenter.default.post(name: .watchDidBecomeReachable, object: nil)
        }
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}

extension Notification.Name {
    static let watchActivityAction = Notification.Name("watchActivityAction")
    static let activityDataUpdated = Notification.Name("activityDataUpdated")
    static let watchRequestedData = Notification.Name("watchRequestedData")
    static let watchDidBecomeReachable = Notification.Name("watchDidBecomeReachable")
}
