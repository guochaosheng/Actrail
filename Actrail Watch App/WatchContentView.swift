import SwiftUI
import WatchKit

struct WatchContentView: View {
    @Bindable var viewModel: WatchActivityViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("行迹")
                            .font(.title3)
                            .fontWeight(.bold)
                        HStack(spacing: 3) {
                            Circle()
                                .fill(viewModel.isReachable ? .green : .orange)
                                .frame(width: 6, height: 6)
                            Text(viewModel.isReachable ? "已连接" : "未连接")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !viewModel.activeRecords.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("正在进行")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ForEach(viewModel.activeRecords) { record in
                                WatchActiveActivityCard(viewModel: viewModel, record: record)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("开始新活动")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(viewModel.activityTypes) { type in
                                WatchActivityTypeButton(type: type) {
                                    viewModel.startActivity(type)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationBarHidden(true)
            .overlay {
                if let reminder = viewModel.firingReminder {
                    WatchReminderLockView(
                        reminder: reminder,
                        activeRecords: viewModel.activeRecords,
                        onUnlock: { viewModel.unlockReminder() }
                    )
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
        }
    }
}

struct WatchReminderLockView: View {
    let reminder: WatchReminder
    let activeRecords: [WatchActivityRecord]
    let onUnlock: () -> Void

    @State private var holdProgress: Double = 0
    @State private var isHolding = false
    @State private var holdTimer: Timer?
    @State private var hapticTimer: Timer?
    @State private var pulseOpacity: Double = 1.0

    private let requiredHoldDuration: TimeInterval = 3.0
    private let tickInterval: TimeInterval = 0.05

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [.black, .red.opacity(0.45), .black]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.red)
                    .shadow(color: .red.opacity(pulseOpacity), radius: 8)
                    .padding(.top, 10)

                Text("该检查活动了")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))

                Text("请确认当前活动是否正确")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                currentActivitySection

                holdToUnlockView
                    .padding(.vertical, 6)

                Text("松开可取消 · 长按解锁回到主页")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 8)
        }
        .onAppear {
            startHaptics()
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.3
            }
        }
        .onDisappear {
            stopHaptics()
            resetHold()
        }
    }

    private var currentActivitySection: some View {
        VStack(spacing: 2) {
            Text("检查当前活动是否正确")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))

            if let current = activeRecords.first {
                HStack(spacing: 4) {
                    Image(systemName: current.activityType.iconName)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: current.activityType.color))
                    Text("正在进行：\(current.activityType.name) \(format(current.duration))")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            } else {
                Text("当前没有进行中的活动")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var holdToUnlockView: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 6)
                    .frame(width: 92, height: 92)

                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: tickInterval), value: holdProgress)

                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 76, height: 76)

                VStack(spacing: 0) {
                    Image(systemName: isHolding ? "hand.pinch.fill" : "lock.fill")
                        .font(.system(size: 18))
                        .foregroundColor(isHolding ? .cyan : .white)
                    Text(isHolding ? "\(Int(ceil(requiredHoldDuration * (1 - holdProgress))))" : "长按解锁")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                if pressing {
                    startHold()
                } else {
                    resetHold()
                }
            }, perform: {})
        }
    }

    private func startHold() {
        holdTimer?.invalidate()
        withAnimation(.easeIn) { isHolding = true }
        holdTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { timer in
            holdProgress += tickInterval / requiredHoldDuration
            if holdProgress >= 1.0 {
                timer.invalidate()
                holdTimer = nil
                WKInterfaceDevice.current().play(.success)
                onUnlock()
            }
        }
    }

    private func resetHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        withAnimation(.easeOut(duration: 0.25)) {
            isHolding = false
            holdProgress = 0
        }
    }

    private func startHaptics() {
        hapticTimer?.invalidate()
        WKInterfaceDevice.current().play(.notification)
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func stopHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
    }

    private func format(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct WatchActivityTypeButton: View {
    let type: WatchActivityType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: type.iconName)
                    .font(.body)
                    .foregroundColor(Color(hex: type.color))
                    .frame(width: 40, height: 40)
                    .background(Color(hex: type.color).opacity(0.2))
                    .clipShape(Circle())

                Text(type.name)
                    .font(.caption2)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
    }
}

struct WatchActiveActivityCard: View {
    @Bindable var viewModel: WatchActivityViewModel
    let record: WatchActivityRecord
    @State private var elapsedTime: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Image(systemName: record.activityType.iconName)
                .font(.title3)
                .foregroundColor(Color(hex: record.activityType.color))
                .frame(width: 36, height: 36)
                .background(Color(hex: record.activityType.color).opacity(0.2))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(record.activityType.name)
                    .font(.caption)
                    .fontWeight(.medium)

                Text(viewModel.formatDuration(elapsedTime))
                    .font(.body)
                    .fontWeight(.bold)
                    .monospacedDigit()
            }

            Spacer()

            Button(action: {
                viewModel.stopActivity(record)
            }) {
                Image(systemName: "stop.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(width: 28, height: 28)
                    .background(Color.red.opacity(0.2))
                    .clipShape(Circle())
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onReceive(timer) { _ in
            elapsedTime = Date().timeIntervalSince(record.startTime)
        }
        .onAppear {
            elapsedTime = Date().timeIntervalSince(record.startTime)
        }
    }
}

#Preview {
    WatchContentView(viewModel: WatchActivityViewModel())
}
