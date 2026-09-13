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

            StatisticsView(viewModel: viewModel)
                .tabItem {
                    Label("统计", systemImage: "chart.pie")
                }

            ReminderView(viewModel: viewModel)
                .tabItem {
                    Label("提醒", systemImage: "bell")
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
