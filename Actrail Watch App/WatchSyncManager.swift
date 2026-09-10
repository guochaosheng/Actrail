import Foundation
import os
@preconcurrency import WatchConnectivity
import Observation

let watchSyncLog = Logger(subsystem: "com.actrail.app", category: "wake")

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
        let watchPlanID: UUID?
        let plansByDay: [String: String]?
    }

    struct WatchReminderLogEntry: Codable {
        var id: UUID
        var content: String
        var presetTime: Date
        var sentTime: Date
        var sentSuccessfully: Bool
        var source: String
        var reminderID: UUID?
        var planID: UUID?

        init(content: String, presetTime: Date, sentTime: Date, sentSuccessfully: Bool, source: String, reminderID: UUID? = nil, planID: UUID? = nil) {
            self.id = UUID()
            self.content = content
            self.presetTime = presetTime
            self.sentTime = sentTime
            self.sentSuccessfully = sentSuccessfully
            self.source = source
            self.reminderID = reminderID
            self.planID = planID
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
        watchSyncLog.info("WCSession activate() 发起")
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
        watchSyncLog.info("请求向 iPhone 拉取快照（唤醒/轮询入口） reachable=\(reachable, privacy: .public) activated=\(session.activationState.rawValue, privacy: .public)")
        WatchWakeLog.shared.add("请求向 iPhone 拉取快照（轮询） reachable=\(reachable) activated=\(session.activationState.rawValue)")
        let userInfo: [String: Any] = ["action": "requestData"]
        if session.activationState == .activated {
            // 用 replyHandler 同步拿回最新快照，不再依赖 didReceive* 通道（模拟器上不总可靠）
            session.sendMessage(userInfo, replyHandler: { [weak self] reply in
                if let data = reply["activityData"] as? Data {
                    self?.lastSyncDate = Date()
                    watchSyncLog.info("收到 iPhone 最新快照（replyHandler 通道） data=\(data.count, privacy: .public)B")
                    WatchWakeLog.shared.add("收到 iPhone 最新快照（replyHandler 通道） \(data.count)B")
                    Task { @MainActor in
                        WatchAppGroupWriter.apply(data)
                        self?.onDataUpdate?(data)
                    }
                }
            }) { error in
                watchSyncLog.error("请求拉取失败：\(error.localizedDescription, privacy: .public)，改用 transferUserInfo")
                WatchWakeLog.shared.add("请求拉取失败：\(error.localizedDescription)")
                WCSession.default.transferUserInfo(userInfo)
            }
        } else {
            watchSyncLog.error("请求拉取时 WCSession 未激活，改用 transferUserInfo")
            WatchWakeLog.shared.add("请求拉取时 WCSession 未激活，改用 transferUserInfo")
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
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[Watch Sync] startActivity sendMessage failed: \(error)，改用 transferUserInfo 兜底")
                WCSession.default.transferUserInfo(userInfo)
            }
        } else {
            session.transferUserInfo(userInfo)
        }
    }

    func sendActivityStop(recordId: UUID, typeId: UUID) {
        let session = WCSession.default
        let reachable = session.isReachable
        if reachable != isReachable {
            isReachable = reachable
            Task { @MainActor in onReachabilityChange?(reachable) }
        }
        // recordId 是 watch 本地 UUID，iPhone 端匹配不到（iPhone 另生成记录），
        // 因此同时带 typeId，iPhone 端按类型停止对应进行中记录。
        let userInfo: [String: Any] = [
            "action": "stopActivity",
            "recordId": recordId.uuidString,
            "typeId": typeId.uuidString
        ]
        if reachable {
            session.sendMessage(userInfo, replyHandler: nil) { error in
                print("[Watch Sync] stopActivity sendMessage failed: \(error)，改用 transferUserInfo 兜底")
                WCSession.default.transferUserInfo(userInfo)
            }
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
        if let action = payload["action"] as? String, action == "queryWakeLog" {
            WatchWakeLog.shared.flushToPhone()
        }
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
            watchSyncLog.info("收到 iPhone 快照（didReceive 通道） data=\(data.count, privacy: .public)B")
            WatchWakeLog.shared.add("收到 iPhone 快照（didReceive 通道） \(data.count)B")
            Task { @MainActor in
                WatchAppGroupWriter.apply(data)
                onDataUpdate?(data)
            }
        }
    }
}

class DelegateBox: NSObject, WCSessionDelegate, @unchecked Sendable {
    weak var syncManager: WatchSyncManager?

    private func mark(_ source: String) {
        let ud = UserDefaults.standard
        ud.set(source, forKey: "lastWakeSource")
        ud.set(Date(), forKey: "lastWakeTime")
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        mark("activation")
        Task { @MainActor in
            syncManager?.isReachable = session.isReachable
            syncManager?.onReachabilityChange?(session.isReachable)
        }
        watchSyncLog.info("WCSession 激活完成 state=\(activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public)")
        WatchWakeLog.shared.add("WCSession 激活完成 state=\(activationState.rawValue) reachable=\(session.isReachable)")
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        mark("message")
        watchSyncLog.info("didReceiveMessage 通道收到消息")
        WatchWakeLog.shared.add("didReceiveMessage 通道收到消息")
        syncManager?.handleReceivedPayload(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        mark("message-reply")
        watchSyncLog.info("didReceiveMessage(replyHandler) 通道收到消息")
        WatchWakeLog.shared.add("didReceiveMessage(replyHandler) 通道收到消息")
        syncManager?.handleReceivedPayload(message)
        replyHandler([:])
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        mark("userInfo")
        watchSyncLog.info("didReceiveUserInfo 通道收到数据（含后台唤醒触发）")
        WatchWakeLog.shared.add("didReceiveUserInfo 通道收到数据（含后台唤醒触发）")
        syncManager?.handleReceivedPayload(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        mark("context")
        watchSyncLog.info("didReceiveApplicationContext 通道收到数据")
        WatchWakeLog.shared.add("didReceiveApplicationContext 通道收到数据")
        syncManager?.handleReceivedPayload(applicationContext)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        mark("reachability")
        Task { @MainActor in
            syncManager?.isReachable = session.isReachable
            syncManager?.onReachabilityChange?(session.isReachable)
        }
        watchSyncLog.info("reachability changed: \(session.isReachable, privacy: .public)")
        WatchWakeLog.shared.add("reachability changed: \(session.isReachable)")
    }

}

let watchWakeLogForward = Logger(subsystem: "com.actrail.app", category: "wakeLog")

// iWatch 系统调度唤醒日志：收集唤醒/拉取/写表盘事件，每 2 秒批量经 WCSession 推给 iPhone 调试页展示。
final class WatchWakeLog {
    static let shared = WatchWakeLog()

    struct Entry: Codable {
        let id: UUID
        let t: Date
        let msg: String
        init(_ msg: String) {
            self.id = UUID()
            self.t = Date()
            self.msg = msg
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var lastSentAt = Date.distantPast

    private init() {}

    func add(_ msg: String) {
        var payload: Data?
        lock.lock()
        entries.append(Entry(msg))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        if Date().timeIntervalSince(lastSentAt) >= 2 {
            payload = encoded()
            lastSentAt = Date()
        }
        lock.unlock()
        guard let payload else { return }
        sendToPhone(payload)
    }

    func flushToPhone() {
        var payload: Data?
        lock.lock()
        payload = encoded()
        lock.unlock()
        guard let payload else { return }
        sendToPhone(payload)
    }

    private func encoded() -> Data? {
        try? JSONEncoder().encode(entries)
    }

    private func sendToPhone(_ data: Data) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            watchWakeLogForward.info("wakeLog 跳过转发 activation=\(session.activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public)")
            return
        }
        watchWakeLogForward.info("wakeLog 转发中 \(data.count, privacy: .public)B")
        session.sendMessage(["wakeLog": data], replyHandler: nil) { error in
            watchWakeLogForward.error("wakeLog 转发失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
