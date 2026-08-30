import SwiftUI

struct SettingsView: View {
    var viewModel: ActivityViewModel
    @State private var notificationsEnabled = true
    @State private var hapticFeedback = true
    @State private var autoBackup = false
    
    var body: some View {
        NavigationView {
            List {
                Section("通用") {
                    Toggle("启用通知", isOn: $notificationsEnabled)
                    Toggle("触觉反馈", isOn: $hapticFeedback)
                    Toggle("自动备份", isOn: $autoBackup)
                }
                
                Section("外观") {
                    NavigationLink("主题颜色") {
                        Text("主题颜色设置")
                    }
                    NavigationLink("深色模式") {
                        Text("深色模式设置")
                    }
                }
                
                Section("数据") {
                    NavigationLink("导出数据") {
                        Text("导出数据")
                    }
                    NavigationLink("导入数据") {
                        Text("导入数据")
                    }
                    NavigationLink("清除数据") {
                        Text("清除数据")
                    }
                }
                
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    NavigationLink("使用条款") {
                        Text("使用条款")
                    }
                    
                    NavigationLink("隐私政策") {
                        Text("隐私政策")
                    }
                }
                
                Section("支持") {
                    NavigationLink("帮助中心") {
                        Text("帮助中心")
                    }
                    
                    NavigationLink("联系我们") {
                        Text("联系我们")
                    }
                    
                    Button("给个好评") {
                        // 打开App Store评分
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

#Preview {
    SettingsView(viewModel: ActivityViewModel())
}
