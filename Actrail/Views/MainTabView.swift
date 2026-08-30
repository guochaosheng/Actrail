import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: ActivityViewModel

    var body: some View {
        TabView {
            HomeView(viewModel: viewModel)
                .tabItem {
                    Label("活动", systemImage: "timer")
                }

            ActivityListView(viewModel: viewModel)
                .tabItem {
                    Label("历史", systemImage: "calendar")
                }

            StatisticsView(viewModel: viewModel)
                .tabItem {
                    Label("统计", systemImage: "chart.pie")
                }

            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
    }
}

#Preview {
    MainTabView(viewModel: ActivityViewModel())
}
