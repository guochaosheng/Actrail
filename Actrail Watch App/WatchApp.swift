import SwiftUI

@main
struct WatchApp: App {
    @State private var viewModel = WatchActivityViewModel()
    @State private var syncManager = WatchSyncManager.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView(viewModel: viewModel)
                .onAppear {
                    syncManager.startSession()
                }
        }
    }
}
