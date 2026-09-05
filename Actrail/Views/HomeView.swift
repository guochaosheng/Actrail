import SwiftUI

struct HomeView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var showingAddActivity = false
    @State private var showingTypeManage = false
    @State private var showingAddReminder = false
    @State private var selectedActivity: ActivityType?
    
    var body: some View {
        NavigationView {
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
                    Text("开始新活动")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                // 活动提醒
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
                        Text("活动提醒")
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
                        ForEach(viewModel.reminderLogs) { log in
                            ReminderLogRow(log: log)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.deleteReminderLog(log)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("提醒历史")
                        .font(.headline)
                        .foregroundColor(.secondary)
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
                Text(reminder.timeString)
                    .font(.title3)
                    .fontWeight(.bold)
                    .monospacedDigit()
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

struct ReminderLogRow: View {
    let log: ReminderLogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if log.source == "闹钟计划" || log.source == "闹钟已取消" {
                    Image(systemName: "alarm")
                        .foregroundColor(log.sentSuccessfully ? .blue : .red)
                } else {
                    Image(systemName: log.source.contains("iWatch") ? "applewatch" : "iphone")
                        .foregroundColor(log.sentSuccessfully ? .green : .red)
                }
                Text(log.source)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if log.status.isEmpty {
                    Text(log.sentSuccessfully ? "发送成功" : "发送失败")
                        .font(.caption)
                        .foregroundColor(log.sentSuccessfully ? .green : .red)
                } else {
                    Text(log.status)
                        .font(.caption)
                        .foregroundColor(log.status == "已取消" ? .gray : .blue)
                }
            }

            Text(log.content)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("预设 \(Self.timeFormatter.string(from: log.presetTime))")
                Text("·")
                Text("发出 \(Self.timeFormatter.string(from: log.sentTime))")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
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

    var body: some View {
        NavigationView {
            Form {
                Section("提醒时间") {
                    DatePicker(
                        "选择日期和时间",
                        selection: $reminderDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .foregroundColor(.blue)
                        Image(systemName: "applewatch")
                            .foregroundColor(.blue)
                        Text("到点后在 iPhone 与 iWatch 各发送本地通知，提醒复检当前正在进行的活动是否正确")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
            alarmGraceMinutes: alarmGraceMinutes
        )
        dismiss()
    }
}

#Preview {
    HomeView(viewModel: ActivityViewModel())
}
