import SwiftUI
import SwiftData

struct ContentView: View {
    @Bindable var viewModel: ActivityViewModel

    var body: some View {
        MainTabView(viewModel: viewModel)
    }
}

#Preview {
    ContentView(viewModel: ActivityViewModel())
}
