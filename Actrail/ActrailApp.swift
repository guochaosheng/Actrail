import SwiftUI
import SwiftData

@main
struct ActrailApp: App {
    let syncManager = WatchSyncManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [ActivityType.self, ActivityRecord.self])
    }
}
