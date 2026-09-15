import SwiftUI
import UserNotifications
import AlarmKit
import UniformTypeIdentifiers

struct DataExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    var viewModel: ActivityViewModel
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = true
    @AppStorage(AppSettings.hapticFeedbackKey) private var hapticFeedback = true
    @AppStorage(AppSettings.autoBackupKey) private var autoBackup = false
    @AppStorage(AppSettings.activitySortModeKey) private var activitySortMode = "normal"

    @State private var showClearConfirm = false
    @State private var showImportPicker = false
    @State private var importURL: URL?
    @State private var showImportConfirm = false
    @State private var statusMessage = ""
    @State private var showStatusAlert = false
    @State private var exportDocument: DataExportDocument?
    @State private var showExporter = false

    private static let backupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                Section("通用") {
                    Toggle("启动通知", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, newValue in
                            viewModel.setNotificationsEnabled(newValue)
                        }
                    Toggle("触觉反馈", isOn: $hapticFeedback)
                        .onChange(of: hapticFeedback) { _, newValue in
                            if newValue { HapticFeedback.impact(.light) }
                        }
                    Toggle("自动备份", isOn: $autoBackup)
                        .onChange(of: autoBackup) { _, newValue in
                            if newValue {
                                viewModel.performAutoBackupIfNeeded()
                            }
                        }
                    if autoBackup, let name = AppSettings.lastAutoBackupURL {
                        HStack {
                            Text("上次备份")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(AppSettings.lastAutoBackupDate.map { Self.backupDateFormatter.string(from: $0) } ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Picker("活动排序", selection: $activitySortMode) {
                        Text("普通排序").tag("normal")
                        Text("智能排序").tag("smart")
                    }
                    .onChange(of: activitySortMode) { _, _ in
                        viewModel.fetchActivityTypes()
                    }
                }

                Section("外观") {
                    NavigationLink("主题颜色") {
                        ThemeColorView()
                    }
                    NavigationLink("深色模式") {
                        DarkModeView()
                    }
                }

                Section("数据") {
                    Button("导出数据") { exportData() }
                    Button("导入数据") { showImportPicker = true }
                    Button("清除数据", role: .destructive) { showClearConfirm = true }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    NavigationLink("使用条款") {
                        TermsView()
                    }

                    NavigationLink("隐私政策") {
                        PrivacyView()
                    }
                }

                Section("支持") {
                    NavigationLink("帮助中心") {
                        HelpView()
                    }

                    NavigationLink("联系我们") {
                        ContactView()
                    }
                }

                Section("开发者") {
                    NavigationLink("调试") {
                        DebugView(viewModel: viewModel)
                    }
                }
            }
            .navigationTitle("设置")
            .confirmationDialog("将删除 iPhone / iWatch / 闹钟排定计划、记录提醒、提醒历史、全部活动历史记录，活动类型恢复默认，正在进行活动全部清除，此操作不可恢复", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清除数据", role: .destructive) {
                    viewModel.resetAllAppData()
                    HapticFeedback.success()
                }
                Button("取消", role: .cancel) {}
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "行迹数据") { _ in }
            .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    importURL = url
                    showImportConfirm = true
                case .failure(let error):
                    statusMessage = "导入失败：\(error.localizedDescription)"
                    showStatusAlert = true
                }
            }
            .alert("确认导入", isPresented: $showImportConfirm, presenting: importURL) { url in
                Button("覆盖导入", role: .destructive) { performImport(url) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("导入将清空当前全部数据（含 iPhone / iWatch / 闹钟排定计划），替换为备份文件内容，此操作不可恢复。")
            }
            .alert("提示", isPresented: $showStatusAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(statusMessage)
            }
        }
    }

    private func exportData() {
        do {
            let data = try viewModel.exportAllData()
            exportDocument = DataExportDocument(data: data)
            showExporter = true
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
            showStatusAlert = true
        }
    }

    private func performImport(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try viewModel.importAllData(data)
            statusMessage = "导入成功"
            HapticFeedback.success()
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
            HapticFeedback.error()
        }
        showStatusAlert = true
    }
}

struct ThemeColorView: View {
    @AppStorage(AppSettings.accentColorKey) private var accentHex = AppSettings.defaultAccentColorHex

    private let colors = [
        "#007AFF", "#34C759", "#FF9500", "#FF2D55",
        "#5856D6", "#AF52DE", "#FF3B30", "#FFCC00",
        "#5AC8FA", "#00C7BE", "#FF2D55", "#8E8E93"
    ]

    var body: some View {
        List {
            Section("主题颜色") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                    ForEach(colors, id: \.self) { hex in
                        ZStack {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle()
                                        .stroke(accentHex == hex ? Color.primary : Color.clear, lineWidth: 3)
                                )
                            if accentHex == hex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .contentShape(Circle())
                        .onTapGesture {
                            accentHex = hex
                            HapticFeedback.selection()
                        }
                    }
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                Text("所选主题色将作为 Tab 栏高亮、按钮、开关等全局强调色。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("主题颜色")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DarkModeView: View {
    @AppStorage(AppSettings.colorSchemeKey) private var mode = "system"

    private var currentModeText: String {
        switch mode {
        case "light": return "浅色"
        case "dark": return "深色"
        default: return "跟随系统"
        }
    }

    var body: some View {
        List {
            Section("显示方式") {
                Picker("显示方式", selection: $mode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.inline)
                .listRowBackground(Color.clear)
            }
            Section {
                Text("已切换为「\(currentModeText)」，即时生效。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("深色模式")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TermsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("使用条款")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("欢迎使用「行迹」。使用本应用即表示您同意以下条款：")
                bullet("1. 服务说明", "「行迹」是一款用于记录日常活动、统计时间分配并设置提醒的工具应用，所提供功能仅用于个人时间管理。")
                bullet("2. 用户责任", "您应自行对使用本应用过程中产生的活动记录、提醒设置等内容负责。应用不保证提醒通知一定送达，请勿将其用于医疗、安全等关键场景。")
                bullet("3. 数据存储", "您的数据默认仅保存在本机。若开启自动备份，备份文件存储于本机应用文档目录，请妥善保管。")
                bullet("4. 通知权限", "提醒功能依赖系统通知与闹钟权限；未授权时相关功能不可用，您可随时在系统设置中调整。")
                bullet("5. 服务变更", "我们可能随时更新或调整功能与条款，更新后继续使用即视为接受新条款。")
                Text("如对本条款有疑问，请通过「设置 → 联系我们」与我们联系。")
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("使用条款")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(body)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("隐私政策")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("您的隐私对我们很重要。本政策说明了「行迹」如何对待您的数据：")
                bullet("1. 本地存储", "活动记录、提醒设置、提醒历史等数据全部存储于您的设备本地（SwiftData 与系统偏好设置），不会上传到任何服务器。")
                bullet("2. 网络与同步", "若您使用 iWatch 联动，活动数据会在你的 iOS 设备与已配对的 Apple Watch 之间通过系统能力同步，仅存于您的设备。")
                bullet("3. 通知与闹钟", "提醒功能仅在本地排定系统通知与闹钟，不会收集您的使用行为。")
                bullet("4. 导出与备份", "导出的 JSON 备份文件由您主动控制存放位置；请自行妥善保管，避免泄露给他人。")
                bullet("5. 第三方服务", "本应用不接入第三方广告或统计 SDK，不会收集、共享任何个人数据。")
                Text("如需删除全部数据，可在「设置 → 清除数据」中操作（会连同排定计划一并清空）。")
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(body)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("活动记录") {
                Text("在「活动」页点击类型图标即可开始计时，再次点击或点按卡片上的停止按钮结束计时。")
            }
            Section("统计") {
                Text("「统计」页展示今日、本周、本月的时长汇总与活动分布，点日历可查看指定日期的记录。")
            }
            Section("提醒") {
                Text("在「提醒」页点击 + 添加每日提醒；开启闹钟后，到点若未打开或记录活动，等待时长过后将强烈提醒。关闭提醒会取消 iPhone / iWatch / 闹钟已排定计划。")
            }
            Section("数据") {
                Text("可在「设置 → 数据」中导出 / 导入 JSON 备份，或清除全部数据。")
            }
        }
        .navigationTitle("帮助中心")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ContactView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "envelope.fill")
                        .foregroundColor(.accentColor)
                    Text("support@actrail.app")
                        .textSelection(.enabled)
                }
            } header: {
                Text("邮箱")
            } footer: {
                Text("如需帮助或反馈问题，请发送邮件至上方邮箱，我们会在 3 个工作日内回复。")
            }
        }
        .navigationTitle("联系我们")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DebugView: View {
    var viewModel: ActivityViewModel
    @State private var iphonePendingStatus = ""
    @State private var alarmKitScheduledStatus = ""
    @State private var alarmList: [(id: UUID, timeText: String)] = []

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
