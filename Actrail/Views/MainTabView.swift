import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = ActivityViewModel()
    
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("活动", systemImage: "timer")
                }
            
            ActivityListView()
                .tabItem {
                    Label("历史", systemImage: "calendar")
                }
            
            StatisticsView()
                .tabItem {
                    Label("统计", systemImage: "chart.pie")
                }
            
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .environmentObject(viewModel)
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
    }
}

#Preview {
    MainTabView()
}
