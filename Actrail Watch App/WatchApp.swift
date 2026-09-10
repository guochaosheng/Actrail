import ClockKit
import SwiftUI

@main
struct WatchApp: App {
    @State private var viewModel = WatchActivityViewModel()
    @State private var syncManager = WatchSyncManager.shared

    init() {
        // 必须在 App 初始化时就激活 WCSession：系统后台拉起进程处理表盘消息（TCCUI）
        // 时不会渲染 UI、不触发 onAppear，若仅在前台调用 startSession 会错过后台投递。
        WatchSyncManager.shared.startSession()
        UserDefaults.standard.set(Date(), forKey: "appLaunchTime")
        // 观测：watchOS 是否识别并挂载了 CLK complication（区分“表盘没挂复杂功能”与“注册未生效”）
        let server = CLKComplicationServer.sharedInstance()
        let active = server.activeComplications ?? []
        UserDefaults.standard.set(active.count, forKey: "clkActiveComplicationsCount")
        if let encoded = try? JSONEncoder().encode(active.map { "\($0.identifier)/\($0.family.rawValue)" }) {
            UserDefaults.standard.set(encoded, forKey: "clkActiveComplications")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView(viewModel: viewModel)
                .onAppear {
                    syncManager.startSession()
                }
        }
    }
}