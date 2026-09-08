import SwiftUI

private enum HistoryRow: Identifiable {
    case groupHeader(ReminderLogGroup)
    case kindRow(ReminderLogGroup, ReminderLogKindSection)

    var id: String {
        switch self {
        case .groupHeader(let group):
            return "group-\(group.id?.uuidString ?? group.displayID)"
        case .kindRow(let group, let kindSection):
            return "kind-\(group.id?.uuidString ?? group.displayID)-\(kindSection.kind.rawValue)"
        }
    }
}

struct HomeView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var showingAddActivity = false
    @State private var showingTypeManage = false
    @State private var showingAddReminder = false
    @State private var selectedActivity: ActivityType?
    
    var body: some View {
        NavigationStack {
            List {
                // 标题行
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("行迹")
                        .font(.title2)
                        .fontWeight(.bold)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.isWatchReachable ? .green : .orange)
                            .frame(width: 7, height: 7)
                        Text(viewModel.isWatchReachable ? "已连接" : "未连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // 正在进行的活动
                if !viewModel.activeRecords.isEmpty {
                    Section {
                        ForEach(viewModel.activeRecords) { record in
                            ActiveActivityCard(viewModel: viewModel, record: record)
                        }
                    } header: {
                        Text("正在进行")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 活动类型网格
                Section {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(viewModel.activityTypes) { type in
                            ActivityTypeButton(type: type) {
                                viewModel.startActivity(type)
                            }
                        }
                    }
                } header: {
                    Text("记录活动")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                // 记录提醒
                Section {
                    if viewModel.reminders.isEmpty {
                        Text("暂无提醒")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    } else {
                        ForEach(viewModel.reminders) { reminder in
                            ReminderRow(reminder: reminder, viewModel: viewModel)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.deleteReminder(reminder)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack {
                        Text("记录提醒")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { showingAddReminder = true }) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                }

                // 提醒历史
                Section {
                    if viewModel.reminderLogs.isEmpty {
                        Text("暂无提醒记录")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    } else {
                        let rows = viewModel.reminderLogGroups().flatMap { group -> [HistoryRow] in
                            var r: [HistoryRow] = [.groupHeader(group)]
                            for kindSection in group.sections {
                                r.append(.kindRow(group, kindSection))
                            }
                            return r
                        }
                        ForEach(rows) { row in
                            switch row {
                            case .groupHeader(let group):
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
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .listRowSeparator(.hidden)

                            case .kindRow(let group, let kindSection):
                                NavigationLink {
                                    KindDetailView(
                                        title: "\(group.displayID) · \(kindSection.kind.title)",
                                        kindSection: kindSection,
                                        deleteLog: { viewModel.deleteReminderLog($0) }
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
                } header: {
                    HStack {
                        Text("提醒历史")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(viewModel.reminderLogs.count) 条")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingTypeManage = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingTypeManage) {
                ActivityTypeManageView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingAddReminder) {
                AddReminderView(viewModel: viewModel)
            }
        }
    }
}

struct ActiveActivityCard: View {
    @Bindable var viewModel: ActivityViewModel
    let record: ActivityRecord
    @State private var elapsedTime: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack {
            if let type = record.activityType {
                Image(systemName: type.iconName)
                    .font(.title2)
                    .foregroundColor(Color(hex: type.color))
                    .frame(width: 50, height: 50)
                    .background(Color(hex: type.color).opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(record.activityType?.name ?? "未知活动")
                    .font(.headline)
                
                Text(viewModel.formatDuration(elapsedTime))
                    .font(.title2)
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            
            Spacer()
            
            Button(action: {
                viewModel.stopActivity(record)
            }) {
                Image(systemName: "stop.fill")
                    .font(.title2)
                    .foregroundColor(.red)
                    .frame(width: 50, height: 50)
                    .background(Color.red.opacity(0.2))
                    .clipShape(Circle())
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        .onReceive(timer) { _ in
            elapsedTime = Date().timeIntervalSince(record.startTime)
        }
        .onAppear {
            elapsedTime = Date().timeIntervalSince(record.startTime)
        }
    }
}

struct ActivityTypeButton: View {
    let type: ActivityType
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: type.iconName)
                    .font(.title2)
                    .foregroundColor(Color(hex: type.color))
                    .frame(width: 60, height: 60)
                    .background(Color(hex: type.color).opacity(0.2))
                    .clipShape(Circle())
                
                Text(type.name)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ReminderRow: View {
    let reminder: ActivityReminder
    @Bindable var viewModel: ActivityViewModel

    var body: some View {
        HStack {
            Image(systemName: "bell.badge.fill")
                .foregroundColor(.red)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("提醒")
                        .font(.subheadline)
                    Text("·")
                        .foregroundColor(.secondary)
                    Label("iPhone + iWatch 本地通知", systemImage: "applewatch")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(reminder.timeString)
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Spacer()
                    Text("#\(reminder.shortID)")
                        .font(.caption2)
                        .monospaced()
                        .foregroundColor(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                Text(reminder.scheduledDatesString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { reminder.isEnabled },
                set: { _ in viewModel.toggleReminder(reminder) }
            ))
            .tint(.green)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

struct AddReminderView: View {
    @Bindable var viewModel: ActivityViewModel
    @Environment(\.dismiss) var dismiss

    @State private var reminderDate = Date()
    @State private var alarmEnabled = false
    @State private var alarmGraceMinutes = 5
    @State private var alarmSound = "default"

    var body: some View {
        NavigationView {
            Form {
                Section("每天提醒时间") {
                    DatePicker(
                        "选择时间",
                        selection: $reminderDate,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.wheel)
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .foregroundColor(.blue)
                        Image(systemName: "applewatch")
                            .foregroundColor(.blue)
                        Text("每天该时刻在 iPhone 与 iWatch 各发送本地通知，提醒复检当前正在进行的活动是否正确")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("智能延续：每次打开 iPhone 或 iWatch 行迹，自动将排定延续到未来 3 天；连续 3 天未打开则停止提醒。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("闹钟持续提醒", isOn: $alarmEnabled)
                        .tint(.blue)
                    if alarmEnabled {
                        HStack {
                            Text("未打开等待时间")
                            Spacer()
                            Picker("分钟", selection: $alarmGraceMinutes) {
                                ForEach(1...30, id: \.self) { n in
                                    Text("\(n) 分钟").tag(n)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        HStack {
                            Text("闹钟铃声")
                            Spacer()
                            Picker("铃声", selection: $alarmSound) {
                                Text("默认").tag("default")
                                Text("无").tag("none")
                            }
                            .pickerStyle(.menu)
                        }
                        Text("通知发出后，若 \(alarmGraceMinutes) 分钟内未打开 iPhone 且存在进行中的活动，iPhone 将持续振动提醒，直到打开确认")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button(action: saveReminder) {
                        HStack {
                            Spacer()
                            Text("保存")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("添加提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    func saveReminder() {
        viewModel.addReminder(
            date: reminderDate,
            alarmEnabled: alarmEnabled,
            alarmGraceMinutes: alarmGraceMinutes,
            alarmSound: alarmSound
        )
        dismiss()
    }
}

struct KindDetailView: View {
    let title: String
    let kindSection: ReminderLogKindSection
    let deleteLog: (ReminderLogEntry) -> Void

    var body: some View {
        List {
            ForEach(kindSection.rows) { section in
                NavigationLink {
                    ReminderPlanDetailView(
                        title: section.kind == .other ? "其它事件" : "\(section.kind.title) · \(section.slotLabel)",
                        logs: section.logs,
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
    let deleteLog: (ReminderLogEntry) -> Void

    var body: some View {
        List {
            ForEach(logs) { log in
                ReminderPlanLogRow(log: log)
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(log.content)
                .font(.subheadline)
            HStack {
                Text("预设 \(Self.timeFormatter.string(from: log.presetTime))")
                Text("·")
                Text("发出 \(Self.timeFormatter.string(from: log.sentTime))")
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
                    .foregroundColor(log.sentSuccessfully ? (log.status == "已取消" ? .gray : .green) : .red)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    HomeView(viewModel: ActivityViewModel())
}
