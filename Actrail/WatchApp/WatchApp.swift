import SwiftUI

@main
struct WatchApp: App {
    @StateObject private var viewModel = WatchActivityViewModel()
    
    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(viewModel)
        }
    }
}
