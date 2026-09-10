import SwiftUI
import SwiftData

@main
struct ActrailApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = ActivityViewModel()
    @State private var syncManager = WatchSyncManager.shared

    private var modelContainer: ModelContainer = {
        let schema = Schema([ActivityType.self, ActivityRecord.self])
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let fm = FileManager.default
        let names = ["ActrailV2.sqlite", "ActrailMain.sqlite"]
        for name in names {
            let url = appSupport.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let config = ModelConfiguration(schema: schema, url: url)
            if let container = try? ModelContainer(for: schema, configurations: [config]) {
                if name != "ActrailV2.sqlite" {
                    try? fm.removeItem(at: appSupport.appendingPathComponent("ActrailMain.sqlite"))
                    try? fm.removeItem(at: appSupport.appendingPathComponent("ActrailMain.sqlite-shm"))
                    try? fm.removeItem(at: appSupport.appendingPathComponent("ActrailMain.sqlite-wal"))
                }
                return container
            }
            print("[ActrailApp] \(name) is corrupt, removing")
            try? fm.removeItem(at: url)
            try? fm.removeItem(atPath: url.path + "-shm")
            try? fm.removeItem(atPath: url.path + "-wal")
        }

        let freshUrl = appSupport.appendingPathComponent("ActrailV2.sqlite")
        let config = ModelConfiguration(schema: schema, url: freshUrl)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onOpenURL { url in
                    // 调试通道：actrail://debug?stop=1 或 actrail://debug?add=1
                    UserDefaults.standard.set(url.absoluteString, forKey: "DebugLastURL")
                    UserDefaults.standard.set(Date(), forKey: "DebugLastURLTime")
                    guard url.scheme == "actrail", url.host == "debug" else { return }
                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    if items.contains(where: { $0.name == "stop" }) {
                        viewModel.stopAllActiveForDebug()
                    }
                    if items.contains(where: { $0.name == "add" }) {
                        viewModel.autoStartActivityForDebug()
                    }
                }
                .onAppear {
                    syncManager.startSession()
                    viewModel.setupReminderNotifications()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        viewModel.stopAlarmIfActiveActivity()
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
