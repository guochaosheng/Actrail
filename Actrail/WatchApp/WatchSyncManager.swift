import Foundation
import WatchConnectivity

class WatchSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    
    @Published var isReachable = false
    @Published var lastSyncDate: Date?
    
    private var session: WCSession?
    private var onDataUpdate: ((Data) -> Void)?
    
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
    
    func startDataUpdateHandler(_ handler: @escaping (Data) -> Void) {
        self.onDataUpdate = handler
    }
    
    func requestDataFromiPhone() {
        guard let session = session else {
            print("[Watch Sync] No session available")
            return
        }
        let userInfo: [String: Any] = ["action": "requestData"]
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: { reply in
                print("[Watch Sync] requestData sendMessage reply: \(reply)")
            }, errorHandler: { error in
                print("[Watch Sync] requestData sendMessage failed: \(error)")
                session.transferUserInfo(userInfo)
            })
            print("[Watch Sync] requestData sent via sendMessage (reachable=\(session.isReachable))")
        } else {
            session.transferUserInfo(userInfo)
            print("[Watch Sync] requestData queued via transferUserInfo")
        }
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
        print("[Watch Sync] WCSession activated: state=\(activationState.rawValue), reachable=\(session.isReachable)")
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("[Watch Sync] received message: \(message.keys.sorted())")
        handleReceivedPayload(message)
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        print("[Watch Sync] received userInfo: \(userInfo.keys.sorted())")
        handleReceivedPayload(userInfo)
    }
    
    private func handleReceivedPayload(_ payload: [String: Any]) {
        if let data = payload["activityData"] as? Data {
            DispatchQueue.main.async {
                self.lastSyncDate = Date()
                self.onDataUpdate?(data)
            }
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
        print("[Watch Sync] reachability changed: \(session.isReachable)")
    }
}
