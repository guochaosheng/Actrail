import SwiftUI

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
