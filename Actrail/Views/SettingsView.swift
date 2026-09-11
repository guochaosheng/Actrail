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
    @State private var iphonePendingStatus = ""
    @State private var alarmKitScheduledStatus = ""
    @State private var alarmList: [(id: UUID, timeText: String)] = []

    @State private var showResetConfirm = false

    var body: some View {
        List {
            Section {
                ForEach(viewModel.reminderLogGroups()) { group in
                    NavigationLink {
                        ReminderPlansListView(
                            group: group,
                            reminders: viewModel.reminders,
                            deleteLog: { viewModel.deleteReminderLog($0) }
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.displayID)
                                .font(.caption)
                                .monospaced()
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            Text(group.reminderLabel)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                HStack {
                    Text("提醒事件")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(viewModel.reminderLogs.count) 条")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("iWatch 提醒") {
                Button("测试：手表立即提醒") {
                    viewModel.testReminderOnWatch()
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
                Button("应用初始化重置", role: .destructive) {
                    showResetConfirm = true
                }
                .confirmationDialog("将删除 iPhone / iWatch / 闹钟排定计划、记录提醒、提醒历史、全部活动历史记录，活动类型恢复默认，正在进行活动全部清除，此操作不可恢复", isPresented: $showResetConfirm, titleVisibility: .visible) {
                    Button("重置", role: .destructive) {
                        viewModel.resetAllAppData()
                    }
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .navigationTitle("调试")
        .navigationBarTitleDisplayMode(.inline)
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
}

struct ReminderPlansListView: View {
    let group: ReminderLogGroup
    let reminders: [ActivityReminder]
    let deleteLog: (ReminderLogEntry) -> Void

    var body: some View {
        List {
            Section {
                ForEach(group.sections.sorted { a, b in
                    (a.kind == .other ? 1 : 0) < (b.kind == .other ? 1 : 0)
                }) { kindSection in
                    NavigationLink {
                        KindDetailView(
                            title: "\(group.displayID) · \(kindSection.kind.title)",
                            kindSection: kindSection,
                            reminders: reminders,
                            deleteLog: deleteLog
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: kindSection.kind.icon)
                                .foregroundColor(.blue)
                                .frame(width: 22)
                            Text(kindSection.kind.title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            let total = kindSection.rows.reduce(0) { $0 + $1.logs.count }
                            Text("\(total) 条")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if kindSection.kind == .other {
                                Text(kindSection.rows.first?.finalStatus ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(kindSection.rows.count) 个时段")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .navigationTitle(group.displayID)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct KindDetailView: View {
    let title: String
    let kindSection: ReminderLogKindSection
    let reminders: [ActivityReminder]
    let deleteLog: (ReminderLogEntry) -> Void

    var body: some View {
        List {
            ForEach(kindSection.rows) { section in
                NavigationLink {
                    ReminderPlanDetailView(
                        title: section.kind == .other ? "其它事件" : "\(section.kind.title) · \(section.slotLabel)",
                        logs: section.logs,
                        reminders: reminders,
                        deleteLog: deleteLog
                    )
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .foregroundColor(.blue)
                            .frame(width: 22)
                        Text(section.slotLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(section.logs.count) 条")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(section.finalStatus)
                            .font(.caption)
                            .foregroundColor(section.logs.contains { !$0.sentSuccessfully } ? .red : .secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.plain)
    }
}

struct ReminderPlanDetailView: View {
    let title: String
    let logs: [ReminderLogEntry]
    let reminders: [ActivityReminder]
    let deleteLog: (ReminderLogEntry) -> Void

    var body: some View {
        List {
            ForEach(logs) { log in
                ReminderPlanLogRow(log: log, reminders: reminders)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteLog(log)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReminderPlanLogRow: View {
    let log: ReminderLogEntry
    let reminders: [ActivityReminder]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f
    }()

    private static let presetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(log.content)
                .font(.subheadline)
            HStack {
                if log.source == "闹钟计划",
                   let reminder = reminders.first(where: { $0.id == log.reminderID }) {
                    let grace = reminder.alarmGraceMinutes
                    let calendar = Calendar.current
                    let slot = reminder.scheduledDates.first(where: {
                        calendar.isDate($0, inSameDayAs: log.presetTime)
                    }) ?? calendar.date(
                        bySettingHour: calendar.component(.hour, from: log.presetTime),
                        minute: calendar.component(.minute, from: log.presetTime),
                        second: 0,
                        of: log.presetTime
                    ) ?? log.presetTime
                    Text("提醒预设 \(Self.presetFormatter.string(from: slot)) 稍后提醒间隔预设 \(grace) 分钟，发出 \(Self.timeFormatter.string(from: log.sentTime))")
                } else {
                    Text("预设 \(Self.timeFormatter.string(from: log.presetTime))")
                    Text("·")
                    Text("发出 \(Self.timeFormatter.string(from: log.sentTime))")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            HStack {
                Text(log.source)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(log.status.isEmpty ? (log.sentSuccessfully ? "成功" : "失败") : log.status)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(log.sentSuccessfully ? (["已取消", "取消成功"].contains(log.status) ? .gray : .green) : .red)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView(viewModel: ActivityViewModel())
}
