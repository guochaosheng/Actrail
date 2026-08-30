import SwiftUI
import SwiftData
import UserNotifications

@main
struct ActrailApp: App {
    @State private var viewModel = ActivityViewModel()
    @State private var syncManager = WatchSyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    syncManager.startSession()
                }
        }
        .modelContainer(for: [ActivityType.self, ActivityRecord.self, ActivityReminder.self])
    }
}
