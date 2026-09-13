import SwiftUI

struct ReminderView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var showingAddReminder = false
    @State private var isEditMode = false
    @State private var reminderToEdit: ActivityReminder?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 编辑/+ 按钮
                HStack {
                    Button(action: { isEditMode.toggle() }) {
                        Text(isEditMode ? "完成" : "编辑")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color(.systemBackground))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    if !isEditMode {
                        Button(action: {
                            reminderToEdit = nil
                            showingAddReminder = true
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.primary)
                                .frame(width: 44, height: 44)
                                .background(Color(.systemBackground))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                }
                
                // 大标题
                Text("提醒")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                
                if viewModel.reminders.isEmpty {
                    // 空状态
                    VStack(spacing: 12) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无提醒")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("点击右上角 + 添加新提醒")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    // 提醒卡片列表
                    ForEach(viewModel.reminders) { reminder in
                        ReminderCard(
                            reminder: reminder,
                            viewModel: viewModel,
                            isEditMode: isEditMode,
                            onTap: {
                                reminderToEdit = reminder
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
                
                Spacer(minLength: 80)
            }
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingAddReminder) {
            AddReminderView(viewModel: viewModel, reminder: nil)
        }
        .sheet(item: $reminderToEdit) { reminder in
            AddReminderView(viewModel: viewModel, reminder: reminder)
        }
    }
}

struct ReminderCard: View {
    let reminder: ActivityReminder
    @Bindable var viewModel: ActivityViewModel
    var isEditMode: Bool = false
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 8) {
            if isEditMode {
                Button(action: { viewModel.deleteReminder(reminder) }) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .frame(width: 28)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reminder.timeString)
                        .font(.system(size: 48, weight: .thin))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("通知")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if reminder.alarmEnabled {
                            Image(systemName: "alarm.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text("闹钟・等待 \(reminder.alarmGraceMinutes) 分钟")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { reminder.isEnabled },
                    set: { _ in viewModel.toggleReminder(reminder) }
                ))
                .tint(.green)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditMode {
                onTap?()
            }
        }
    }
}

struct AddReminderView: View {
    @Bindable var viewModel: ActivityViewModel
    var reminder: ActivityReminder? = nil
    @Environment(\.dismiss) var dismiss

    @State private var reminderDate = Date()
    @State private var alarmEnabled = false
    @State private var alarmGraceMinutes = 5
    @State private var alarmSound = "default"

    init(viewModel: ActivityViewModel, reminder: ActivityReminder? = nil) {
        self.viewModel = viewModel
        self.reminder = reminder
        _reminderDate = State(initialValue: reminder?.date ?? Date())
        _alarmEnabled = State(initialValue: reminder?.alarmEnabled ?? false)
        _alarmGraceMinutes = State(initialValue: reminder?.alarmGraceMinutes ?? 5)
        _alarmSound = State(initialValue: reminder?.alarmSound ?? "default")
    }

    private var isEditing: Bool { reminder != nil }

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
                    Toggle("未打开/记录时闹钟提醒", isOn: $alarmEnabled)
                        .tint(.blue)
                    if alarmEnabled {
                        HStack {
                            Text("等待时长")
                            Spacer()
                            Picker(selection: $alarmGraceMinutes) {
                                ForEach(1...30, id: \.self) { n in
                                    Text("\(n) 分钟").tag(n)
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.menu)
                        }
                        HStack {
                            Text("闹钟铃声")
                            Spacer()
                            Picker(selection: $alarmSound) {
                                Text("默认").tag("default")
                                Text("无").tag("none")
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.menu)
                        }
                        Text("通知发出后，若 \(alarmGraceMinutes) 分钟内未打开 iPhone 且存在进行中的活动，iPhone 将持续振动提醒，直到打开确认")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑提醒" : "添加提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { saveReminder() }
                }
            }
        }
    }

    func saveReminder() {
        if let reminder = reminder {
            // 检查各项配置是否有变化；有变化则删除旧提醒并生成新提醒
            let calendar = Calendar.current
            let timeChanged = calendar.component(.hour, from: reminder.date) != calendar.component(.hour, from: reminderDate)
                || calendar.component(.minute, from: reminder.date) != calendar.component(.minute, from: reminderDate)
            let changed = timeChanged
                || reminder.alarmEnabled != alarmEnabled
                || reminder.alarmGraceMinutes != alarmGraceMinutes
                || reminder.alarmSound != alarmSound
            if changed {
                viewModel.deleteReminder(reminder)
                viewModel.addReminder(
                    date: reminderDate,
                    alarmEnabled: alarmEnabled,
                    alarmGraceMinutes: alarmGraceMinutes,
                    alarmSound: alarmSound
                )
            }
        } else {
            viewModel.addReminder(
                date: reminderDate,
                alarmEnabled: alarmEnabled,
                alarmGraceMinutes: alarmGraceMinutes,
                alarmSound: alarmSound
            )
        }
        dismiss()
    }
}

#Preview {
    ReminderView(viewModel: ActivityViewModel())
}
