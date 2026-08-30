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
            .overlay {
                if let alert = viewModel.activeVibrationAlert {
                    VibrationAlertView(
                        activityName: alert.activityName,
                        reminderType: alert.reminderType,
                        onDismiss: { viewModel.stopVibration() }
                    )
                }
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
                HStack {
                    Text(reminder.activityType?.name ?? "未知活动")
                        .font(.subheadline)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(reminder.reminderType.displayName)
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

struct VibrationAlertView: View {
    let activityName: String
    let reminderType: ReminderType
    let onDismiss: () -> Void
    @State private var holdProgress: CGFloat = 0
    @State private var isHolding = false
    @State private var holdTimer: Timer?
    @State private var elapsedHoldTime: TimeInterval = 0
    private let requiredHoldTime: TimeInterval = 5.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.red)
                    .symbolEffect(.pulse)

                Text("提醒")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("该开始 \(activityName) 了")
                    .font(.title2)
                    .foregroundColor(.white)

                if reminderType == .vibration {
                    Button(action: onDismiss) {
                        Text("确认")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(16)
                    }
                    .padding(.horizontal, 40)
                } else {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 8)
                                .frame(width: 80, height: 80)

                            Circle()
                                .trim(from: 0, to: holdProgress)
                                .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .frame(width: 80, height: 80)
                                .rotationEffect(.degrees(-90))

                            Text("\(Int(requiredHoldTime - elapsedHoldTime))")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }

                        Text("长按5秒确认关闭")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))

                        Text("按住不放...")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .frame(height: 180)
                    .onLongPressGesture(minimumDuration: requiredHoldTime, pressing: { pressing in
                        isHolding = pressing
                        if pressing {
                            startHoldTimer()
                        } else {
                            resetHoldTimer()
                        }
                    }, perform: {
                        onDismiss()
                    })
                }

                Text("时间：\(Date.now, style: .time)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .onAppear {
            if reminderType == .vibration {
                startVibrationPattern()
            }
        }
        .onDisappear {
            holdTimer?.invalidate()
        }
    }

    private func startVibrationPattern() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if reminderType == .vibration {
                generator.notificationOccurred(.error)
            }
        }
    }

    private func startHoldTimer() {
        elapsedHoldTime = 0
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            elapsedHoldTime += 0.1
            holdProgress = CGFloat(elapsedHoldTime / requiredHoldTime)

            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()

            if elapsedHoldTime >= requiredHoldTime {
                timer.invalidate()
                onDismiss()
            }
        }
    }

    private func resetHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdProgress = 0
        elapsedHoldTime = 0
    }
}

struct AddReminderView: View {
    @Bindable var viewModel: ActivityViewModel
    @Environment(\.dismiss) var dismiss

    @State private var selectedTypeIndex = 0
    @State private var hour = 9
    @State private var minute = 0
    @State private var selectedReminderType: ReminderType = .notification

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

                Section("提醒方式") {
                    ForEach(ReminderType.allCases, id: \.self) { type in
                        Button(action: { selectedReminderType = type }) {
                            HStack {
                                Image(systemName: type.iconName)
                                    .frame(width: 30)
                                VStack(alignment: .leading) {
                                    Text(type.displayName)
                                        .foregroundColor(.primary)
                                    Text(reminderTypeDescription(type))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedReminderType == type {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
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

    func reminderTypeDescription(_ type: ReminderType) -> String {
        switch type {
        case .notification:
            return "到点时推送通知"
        case .vibration:
            return "弹出提示框并持续振动，点击确认关闭"
        case .vibrationWithLongPress:
            return "弹出提示框并持续振动，长按5秒确认关闭"
        }
    }

    func saveReminder() {
        guard selectedTypeIndex < viewModel.activityTypes.count else { return }
        viewModel.addReminder(
            activityType: viewModel.activityTypes[selectedTypeIndex],
            hour: hour,
            minute: minute,
            reminderType: selectedReminderType
        )
        dismiss()
    }
}

#Preview {
    HomeView(viewModel: ActivityViewModel())
}
