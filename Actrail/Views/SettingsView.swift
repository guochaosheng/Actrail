import SwiftUI

struct SettingsView: View {
    var viewModel: ActivityViewModel
    @State private var notificationsEnabled = true
    @State private var hapticFeedback = true
    @State private var autoBackup = false
    
    @State private var alarmKitAuthState = "未知"
    @State private var showTestAlert = false
    @State private var testAlertMessage = ""
    
    var body: some View {
        NavigationView {
            List {
                Section("通用") {
                    Toggle("启用通知", isOn: $notificationsEnabled)
                    Toggle("触觉反馈", isOn: $hapticFeedback)
                    Toggle("自动备份", isOn: $autoBackup)
                }
                
                if #available(iOS 26.0, *) {
                    Section("闹钟 (AlarmKit)") {
                        HStack {
                            Text("授权状态")
                            Spacer()
                            Text(alarmKitAuthState)
                                .foregroundColor(alarmKitAuthState == "已授权" ? .green : .red)
                                .font(.caption)
                        }
                        
                        if alarmKitAuthState == "已拒绝（需到系统设置中开启）" {
                            Text("请前往「设置 > 行迹 > 闹钟」手动开启")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        
                        Button("请求 AlarmKit 授权") {
                            Task {
                                let authorized = await AlarmKitManager.shared.requestAuthorization()
                                alarmKitAuthState = authorized ? "已授权" : AlarmKitManager.shared.authorizationStateDescription
                                testAlertMessage = authorized ? "授权成功！" : "授权失败：\(AlarmKitManager.shared.authorizationStateDescription)"
                                showTestAlert = true
                            }
                        }
                        
                        Button("测试：1分钟后闹钟") {
                            Task {
                                await testAlarmKit()
                            }
                        }
                    }
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
                    }
                }
            }
            .navigationTitle("设置")
            .alert("AlarmKit", isPresented: $showTestAlert) {
                Button("确定") {}
            } message: {
                Text(testAlertMessage)
            }
            .task {
                if #available(iOS 26.0, *) {
                    let manager = AlarmKitManager.shared
                    if manager.isAuthorized {
                        alarmKitAuthState = "已授权"
                    } else {
                        alarmKitAuthState = "未授权"
                    }
                }
            }
        }
    }
    
    private func testAlarmKit() async {
        guard #available(iOS 26.0, *) else {
            testAlertMessage = "需要 iOS 26+"
            showTestAlert = true
            return
        }
        
        let manager = AlarmKitManager.shared
        let authorized = await manager.ensureAuthorized()
        guard authorized else {
            testAlertMessage = "AlarmKit 未授权"
            showTestAlert = true
            return
        }
        
        let calendar = Calendar.current
        let fireDate = calendar.date(byAdding: .minute, value: 1, to: Date()) ?? Date()
        let components = calendar.dateComponents([.hour, .minute], from: fireDate)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        
        do {
            try await manager.scheduleAlarm(
                id: UUID(),
                hour: hour,
                minute: minute,
                activityName: "测试活动",
                activityIconName: "bell.fill",
                activityColor: "#FF3B30",
                reminderId: UUID().uuidString
            )
            testAlertMessage = "闹钟已设置，将在 \(hour):\(String(format: "%02d", minute)) 响起"
        } catch {
            testAlertMessage = "设置失败: \(error)"
        }
        showTestAlert = true
    }
}

#Preview {
    SettingsView(viewModel: ActivityViewModel())
}
