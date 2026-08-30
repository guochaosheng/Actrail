import SwiftUI

struct WatchContentView: View {
    @Bindable var viewModel: WatchActivityViewModel
    @State private var showingActivityList = false

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
                            Text("进行中")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ForEach(viewModel.activeRecords) { record in
                                WatchActiveActivityCard(viewModel: viewModel, record: record)
                            }
                        }
                    }

                    Button(action: { showingActivityList = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("开始活动")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if !viewModel.completedRecords.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已完成")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ForEach(viewModel.completedRecords.prefix(3)) { record in
                                WatchCompletedActivityRow(record: record)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingActivityList) {
                WatchActivityListView(viewModel: viewModel)
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

struct WatchCompletedActivityRow: View {
    let record: WatchActivityRecord

    var body: some View {
        HStack {
            Image(systemName: record.activityType.iconName)
                .font(.caption)
                .foregroundColor(Color(hex: record.activityType.color))
                .frame(width: 24, height: 24)

            Text(record.activityType.name)
                .font(.caption2)

            Spacer()

            Text(formatDuration(record.duration))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

struct WatchActivityListView: View {
    @Bindable var viewModel: WatchActivityViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List(viewModel.activityTypes) { type in
                Button(action: {
                    viewModel.startActivity(type)
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: type.iconName)
                            .foregroundColor(Color(hex: type.color))
                            .frame(width: 30)

                        Text(type.name)
                    }
                }
            }
            .navigationTitle("选择活动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    WatchContentView(viewModel: WatchActivityViewModel())
}
