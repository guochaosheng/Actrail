import SwiftUI
import SwiftData
import UserNotifications

@main
struct ActrailApp: App {
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
                .onAppear {
                    syncManager.startSession()
                    viewModel.setupNotifications()
                }
        }
        .modelContainer(modelContainer)
    }
}
