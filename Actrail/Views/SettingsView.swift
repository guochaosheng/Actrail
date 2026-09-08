import SwiftUI
import UserNotifications
import AlarmKit

struct SettingsView: View {
    var viewModel: ActivityViewModel
    @State private var notificationsEnabled = true
    @State private var hapticFeedback = true
    @State private var autoBackup = false

    var body: some View {
        NavigationStack {
            List {
                Section("通用") {
                    Toggle("启用通知", isOn: $notificationsEnabled)
                    Toggle("触觉反馈", isOn: $hapticFeedback)
                    Toggle("自动备份", isOn: $autoBackup)
                }

Section("开发者") {
                    NavigationLink("调试") {
                        DebugView(viewModel: viewModel)
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
        }
    }
}

struct DebugView: View {
    var viewModel: ActivityViewModel
    @State private var notificationAuthorized = false
    @State private var notificationAuthText = "未知"
    @State private var pendingCountText = "—"
    @State private var alarmKitAuthText = "未知"
    @State private var diagLogs: [DiagnosticLogEntry] = []
    @State private var iphonePendingStatus = ""
    @State private var alarmKitScheduledStatus = ""
    @State private var alarmList: [(id: UUID, timeText: String)] = []

    @State private var showClearConfirm = false
    @State private var showResetConfirm = false

    var body: some View {
        List {
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

            Section("通知排定状态") {
                Button("iPhone 通知排定状态") {
                    queryiPhonePendingStatus()
                }
                if !iphonePendingStatus.isEmpty {
                    Text(iphonePendingStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Button("iWatch 通知排定状态") {
                    viewModel.requestWatchStatus()
                }
                if viewModel.watchStatusString != "尚未查询" && viewModel.watchStatusString != "查询中…" {
                    Text(viewModel.watchStatusString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Button("闹钟通知排定状态") {
                    queryAlarmKitScheduledStatus()
                }
                if !alarmList.isEmpty {
                    ForEach(alarmList, id: \.id) { item in
                        HStack {
                            Text("\(item.timeText)  #\(item.id.uuidString.prefix(8))")
                                .font(.caption2)
                            Spacer()
                            Button("取消") {
                                AlarmKitManager.shared.cancelAlarms(ids: [item.id])
                                queryAlarmKitScheduledStatus()
                            }
                            .font(.caption2)
                        }
                    }
                }
                if !alarmKitScheduledStatus.isEmpty {
                    Text(alarmKitScheduledStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("开发者") {
                Button("清空记录提醒与提醒历史", role: .destructive) {
                    showClearConfirm = true
                }
                .confirmationDialog("将清空所有记录提醒与提醒历史（含已排定闹钟），此操作不可恢复", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("清空", role: .destructive) {
                        viewModel.clearRemindersAndLogs()
                        refreshNotificationStatus()
                    }
                    Button("取消", role: .cancel) {}
                }
                Button("应用初始化重置", role: .destructive) {
                    showResetConfirm = true
                }
                .confirmationDialog("将删除 iPhone / iWatch / 闹钟排定计划、记录提醒、提醒历史、全部活动历史记录，活动类型恢复默认，正在进行活动全部清除，此操作不可恢复", isPresented: $showResetConfirm, titleVisibility: .visible) {
                    Button("重置", role: .destructive) {
                        viewModel.resetAllAppData()
                        refreshNotificationStatus()
                    }
                    Button("取消", role: .cancel) {}
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
        }
        .navigationTitle("调试")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshNotificationStatus()
            refreshAlarmKitStatus()
        }
    }

    private func queryiPhonePendingStatus() {
        iphonePendingStatus = "查询中…"
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd HH:mm"
            let reminderRequests = requests.filter { $0.identifier.hasPrefix("reminder-") }
            let lines = reminderRequests
                .sorted { a, b in
                    let da = (a.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                    let db = (b.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                    return da < db
                }
                .compactMap { r -> String? in
                    guard let next = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { return nil }
                    let mid = r.identifier
                        .replacingOccurrences(of: "reminder-", with: "")
                        .prefix(8)
                    return "  \(mid): \(formatter.string(from: next))"
                }
            DispatchQueue.main.async {
                if reminderRequests.isEmpty {
                    self.iphonePendingStatus = "无排定的提醒通知"
                } else {
                    self.iphonePendingStatus = "\(reminderRequests.count) 条待处理：\n" + lines.joined(separator: "\n")
                }
            }
        }
    }

    private func queryAlarmKitScheduledStatus() {
        alarmKitScheduledStatus = "查询中…"
        DispatchQueue.main.async {
            let manager = AlarmKitManager.shared
            let authText: String
            switch manager.authorizationState {
            case .authorized: authText = "已授权"
            case .denied: authText = "已拒绝"
            case .notDetermined: authText = "未请求"
            @unknown default: authText = "未知"
            }
            guard let alarms = manager.queryAlarms() else {
                self.alarmKitScheduledStatus = "授权：\(authText)\n系统 AlarmKit 查询失败"
                return
            }
            let appIDs = Set(self.viewModel.reminders.flatMap { $0.scheduledAlarmIDs.values }.map(\.uuidString))
            var cacheLines: [String] = []
            for reminder in self.viewModel.reminders {
                for (dayKey, alarmID) in reminder.scheduledAlarmIDs.sorted(by: { $0.key < $1.key }) {
                    cacheLines.append("  \(dayKey) #\(alarmID.uuidString.prefix(8)) 提醒\(reminder.timeString)")
                }
            }
            let mine = alarms.filter { appIDs.contains($0.id.uuidString) }
            let lines = alarms.map { alarm in
                let tag = appIDs.contains(alarm.id.uuidString) ? "本app" : "外部"
                return "  \(self.formatAlarmTime(alarm.schedule))  [\(self.formatAlarmState(alarm.state))]  #\(alarm.id.uuidString.prefix(8))  (\(tag))"
            }
            let cacheText = cacheLines.isEmpty ? "  （空）" : cacheLines.joined(separator: "\n")
            self.alarmList = alarms.map { alarm in
                let text: String
                switch alarm.schedule {
                case .fixed(let date)?:
                    let f = DateFormatter()
                    f.dateFormat = "MM/dd HH:mm"
                    text = f.string(from: date)
                case .relative(let rel)?:
                    text = String(format: "%02d:%02d", rel.time.hour, rel.time.minute)
                case nil:
                    text = "无时刻"
                }
                return (alarm.id, text)
            }
            if alarms.isEmpty {
                self.alarmKitScheduledStatus = "授权：\(authText)\n系统已排定：无\n本地缓存 scheduledAlarmIDs：\n\(cacheText)"
            } else {
                self.alarmKitScheduledStatus = "授权：\(authText)\n系统已排定 \(alarms.count) 个（本app \(mine.count) 个）：\n" + lines.joined(separator: "\n") + "\n本地缓存 scheduledAlarmIDs：\n\(cacheText)"
            }
        }
    }

    private func formatAlarmTime(_ schedule: AlarmKit.Alarm.Schedule?) -> String {
        switch schedule {
        case .fixed(let date)?:
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm"
            return f.string(from: date)
        case .relative(let relative)?:
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "相对 \(f.string(from: Calendar.current.date(bySettingHour: relative.time.hour, minute: relative.time.minute, second: 0, of: Date()) ?? Date()))"
        case nil:
            return "无时间"
        }
    }

    private func formatAlarmState(_ state: AlarmKit.Alarm.State) -> String {
        switch state {
        case .scheduled: return "已排定"
        case .countdown: return "倒计时"
        case .paused: return "已暂停"
        case .alerting: return "响铃中"
        @unknown default: return "未知"
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
