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
    
    func sendActivityStart(typeId: UUID) {
        guard let session = session else { return }
        
        let userInfo: [String: Any] = [
            "action": "startActivity",
            "typeId": typeId.uuidString
        ]
        session.transferUserInfo(userInfo)
    }
    
    func sendActivityStop(recordId: UUID) {
        guard let session = session else { return }
        
        let userInfo: [String: Any] = [
            "action": "stopActivity",
            "recordId": recordId.uuidString
        ]
        session.transferUserInfo(userInfo)
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["activityData"] as? Data {
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
    }
}
