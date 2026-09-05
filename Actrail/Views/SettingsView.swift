import SwiftUI
import UserNotifications
import AlarmKit

struct SettingsView: View {
    var viewModel: ActivityViewModel
    @State private var notificationsEnabled = true
    @State private var hapticFeedback = true
    @State private var autoBackup = false
    @State private var notificationAuthorized = false
    @State private var notificationAuthText = "未知"
    @State private var pendingCountText = "—"
    @State private var alarmKitAuthText = "未知"
    @State private var diagLogs: [DiagnosticLogEntry] = []

    var body: some View {
        NavigationView {
            List {
                Section("通用") {
                    Toggle("启用通知", isOn: $notificationsEnabled)
                    Toggle("触觉反馈", isOn: $hapticFeedback)
                    Toggle("自动备份", isOn: $autoBackup)
                }

                Section("iWatch 提醒") {
                    Button("测试：手表立即提醒") {
                        viewModel.testReminderOnWatch()
                    }
                }

                Section("通知状态") {
                    HStack {
                        Text("通知授权")
                        Spacer()
                        Text(notificationAuthText)
                            .foregroundColor(notificationAuthorized ? .green : .red)
                            .font(.caption)
                    }
                    HStack {
                        Text("已保存提醒")
                        Spacer()
                        Text("\(viewModel.reminders.count) 条")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("待处理通知")
                        Spacer()
                        Text(pendingCountText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button("重排所有提醒") {
                        viewModel.rescheduleAllPhoneNotificationsPublic()
                        refreshNotificationStatus()
                    }
                    Button("查询手表通知状态") {
                        viewModel.requestWatchStatus()
                    }
                    if !viewModel.watchStatusString.isEmpty {
                        Text(viewModel.watchStatusString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("闹钟诊断 (AlarmKit)") {
                    HStack {
                        Text("AlarmKit 授权")
                        Spacer()
                        Text(alarmKitAuthText)
                            .foregroundColor(alarmKitAuthText == "已授权" ? .green : .red)
                            .font(.caption)
                    }
                    // 显示已保存的提醒列表
                    ForEach(viewModel.reminders) { reminder in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(reminder.timeString)
                                    .font(.body.monospacedDigit())
                                Spacer()
                                let alarmLog = viewModel.reminderLogs.first(where: {
                                    $0.reminderID == reminder.id && $0.source == "闹钟计划"
                                })
                                if let log = alarmLog {
                                    Text(log.status == "已取消" ? "已取消" : "计划中")
                                        .font(.caption2)
                                        .foregroundColor(log.status == "已取消" ? .gray : .orange)
                                } else if reminder.alarmEnabled {
                                    Text("待排定")
                                        .font(.caption2)
                                        .foregroundColor(.yellow)
                                }
                                if reminder.alarmEnabled {
                                    Text("闹钟+\(reminder.alarmGraceMinutes)分")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            Text("ID: \(reminder.id.uuidString.prefix(8))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    // 显示闹钟相关的历史记录
                    let alarmLogs = viewModel.reminderLogs.filter {
                        $0.source.contains("闹钟")
                    }
                    if !alarmLogs.isEmpty {
                        Divider()
                        Text("闹钟历史记录")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(alarmLogs) { log in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(log.source)
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                    if !log.status.isEmpty {
                                        Text(log.status)
                                            .font(.caption2)
                                            .foregroundColor(log.status == "已取消" ? .gray : .blue)
                                    }
                                }
                                Text(log.content)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section("闹钟操作日志（持久化）") {
                    if diagLogs.isEmpty {
                        Text("暂无日志")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(diagLogs) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.tag)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.orange)
                                    Spacer()
                                    Text(formatDiagTime(entry.timestamp))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(entry.message)
                                    .font(.caption2)
                                if !entry.callStack.isEmpty {
                                    Text(entry.callStack)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.gray)
                                        .lineLimit(3)
                                }
                            }
                        }
                        Button("清除日志") {
                            DiagnosticLog.clear()
                            diagLogs = []
                        }
                        .foregroundColor(.red)
                    }
                }
                .onAppear {
                    diagLogs = DiagnosticLog.load()
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
            .onAppear {
                refreshNotificationStatus()
                refreshAlarmKitStatus()
            }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.notificationAuthorized = true
                    self.notificationAuthText = "已授权"
                case .notDetermined:
                    self.notificationAuthorized = false
                    self.notificationAuthText = "未请求"
                case .denied:
                    self.notificationAuthorized = false
                    self.notificationAuthText = "已拒绝"
                @unknown default:
                    self.notificationAuthorized = false
                    self.notificationAuthText = "未知"
                }
            }
        }
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            DispatchQueue.main.async {
                self.pendingCountText = "\(requests.count) 条"
            }
        }
    }

    private func refreshAlarmKitStatus() {
        let manager = AlarmKitManager.shared
        switch manager.authorizationState {
        case .authorized:
            alarmKitAuthText = "已授权"
        case .denied:
            alarmKitAuthText = "已拒绝"
        case .notDetermined:
            alarmKitAuthText = "未请求"
        @unknown default:
            alarmKitAuthText = "未知"
        }
    }

    private func formatDiagTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}

#Preview {
    SettingsView(viewModel: ActivityViewModel())
}
