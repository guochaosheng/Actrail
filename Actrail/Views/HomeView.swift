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
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                viewModel.deleteReminder(viewModel.reminders[index])
                            }
                        }
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
        }
    }
}

struct ReminderRow: View {
    let reminder: ActivityReminder
    @Bindable var viewModel: ActivityViewModel

    var body: some View {
        HStack {
            if let type = reminder.activityType {
                Image(systemName: type.iconName)
                    .foregroundColor(Color(hex: type.color))
                    .frame(width: 30)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.activityType?.name ?? "未知活动")
                    .font(.subheadline)
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

struct AddReminderView: View {
    @Bindable var viewModel: ActivityViewModel
    @Environment(\.dismiss) var dismiss

    @State private var selectedTypeIndex = 0
    @State private var hour = 9
    @State private var minute = 0

    var body: some View {
        NavigationView {
            Form {
                Section("选择活动") {
                    Picker("活动类型", selection: $selectedTypeIndex) {
                        ForEach(Array(viewModel.activityTypes.enumerated()), id: \.offset) { index, type in
                            HStack {
                                Image(systemName: type.iconName)
                                    .foregroundColor(Color(hex: type.color))
                                Text(type.name)
                            }
                            .tag(index)
                        }
                    }
                    .pickerStyle(.wheel)
                }

                Section("提醒时间") {
                    HStack {
                        Picker("时", selection: $hour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).tag(h)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 80)

                        Text(":")
                            .font(.title)
                            .fontWeight(.bold)

                        Picker("分", selection: $minute) {
                            ForEach(0..<60, id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 80)
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
                    .disabled(viewModel.activityTypes.isEmpty)
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
        guard selectedTypeIndex < viewModel.activityTypes.count else { return }
        viewModel.addReminder(
            activityType: viewModel.activityTypes[selectedTypeIndex],
            hour: hour,
            minute: minute
        )
        dismiss()
    }
}

#Preview {
    HomeView(viewModel: ActivityViewModel())
}
