import SwiftUI

struct StatisticsView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var selectedPeriod = "今日"
    @State private var showCalendar = false
    let periods = ["今日", "本周", "本月"]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 大标题
                HStack {
                    Text("统计")
                        .font(.system(size: 34, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                // 分段切换：日历 ↔ 趋势
                HStack(spacing: 12) {
                    Button(action: { showCalendar = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .font(.system(size: 17))
                            Text("日历")
                                .font(.body)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(showCalendar ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            showCalendar
                                ? Color.blue.opacity(0.12)
                                : Color(.systemGray6),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: { showCalendar = false }) {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.pie")
                                .font(.system(size: 17))
                            Text("趋势")
                                .font(.body)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(!showCalendar ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            !showCalendar
                                ? Color.blue.opacity(0.12)
                                : Color(.systemGray6),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                
                if showCalendar {
                    // 日历视图
                    CalendarHistorySection(viewModel: viewModel)
                } else {
                    // 趋势视图
                    TrendStatsSection(viewModel: viewModel, selectedPeriod: $selectedPeriod, periods: periods)
                }
                
                Spacer(minLength: 80)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - 日历历史视图
struct CalendarHistorySection: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var selectedDate = Date()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 日期选择器
            DatePicker("选择日期", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onChange(of: selectedDate) { _ in
                    viewModel.selectedCalendarDate = selectedDate
                    viewModel.fetchTodayRecords()
                }
            
            // 当日记录
            VStack(alignment: .leading, spacing: 0) {
                Text("历史记录")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                
                if viewModel.todayRecords.isEmpty {
                    Text("暂无记录")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(viewModel.todayRecords) { record in
                        ActivityRecordRow(record: record)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        
                        if record.id != viewModel.todayRecords.last?.id {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

// MARK: - 趋势统计视图
struct TrendStatsSection: View {
    @Bindable var viewModel: ActivityViewModel
    @Binding var selectedPeriod: String
    let periods: [String]

    private var dateRange: DateInterval { viewModel.dateRange(for: selectedPeriod) }
    private var stats: (totalSeconds: Int, recordCount: Int) {
        viewModel.getAggregatedStats(from: dateRange.start, to: dateRange.end)
    }
    private var distribution: [(type: String, seconds: Int, color: String)] {
        viewModel.getActivityDistribution(from: dateRange.start, to: dateRange.end)
    }
    private var ranking: [(name: String, seconds: Int, color: String)] {
        viewModel.getActivityRanking(from: dateRange.start, to: dateRange.end)
    }

    var body: some View {
        VStack(spacing: 20) {
            // 时间段选择
            HStack(spacing: 2) {
                ForEach(periods, id: \.self) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        Text(period)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedPeriod == period ? Color(.systemBackground) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundColor(selectedPeriod == period ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 总时长卡片
            SummaryCard(
                title: "总时长",
                value: viewModel.formatDurationHuman(stats.totalSeconds),
                subtitle: summarySubtitle,
                icon: "clock.fill",
                color: .blue
            )
            .padding(.horizontal, 16)

            // 活动分布
            VStack(alignment: .leading, spacing: 12) {
                Text("活动分布")
                    .font(.headline)

                ActivityDistributionChart(distribution: distribution)
                    .frame(height: 200)
                    .padding()
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            }
            .padding(.horizontal, 16)

            // 活动排行
            VStack(alignment: .leading, spacing: 12) {
                Text("活动排行")
                    .font(.headline)

                ActivityRankingList(ranking: ranking, totalSeconds: stats.totalSeconds)
                    .padding()
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            }
            .padding(.horizontal, 16)
        }
    }

    private var summarySubtitle: String {
        let calendar = Calendar.current
        let now = Date()
        let range = dateRange
        var previousEnd = range.start
        var previousStart: Date
        switch selectedPeriod {
        case "本周":
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: previousEnd)!
            previousStart = weekInterval.start
            previousEnd = range.start
        case "本月":
            let monthInterval = calendar.dateInterval(of: .month, for: previousEnd)!
            previousStart = monthInterval.start
            previousEnd = range.start
        default:
            previousEnd = range.start
            previousStart = calendar.date(byAdding: .day, value: -1, to: range.start)!
        }
        let prev = viewModel.getAggregatedStats(from: previousStart, to: previousEnd)
        let diff = stats.totalSeconds - prev.totalSeconds
        if diff > 0 { return "比上期多\(viewModel.formatDurationHuman(diff))" }
        if diff < 0 { return "比上期少\(viewModel.formatDurationHuman(abs(diff)))" }
        return "与上期持平"
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.green)
            }

            Spacer()

            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(color)
                .frame(width: 60, height: 60)
                .background(color.opacity(0.2))
                .clipShape(Circle())
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

struct ActivityDistributionChart: View {
    let distribution: [(type: String, seconds: Int, color: String)]

    private var totalSeconds: Int {
        distribution.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        VStack(spacing: 12) {
            if distribution.isEmpty {
                Spacer()
                Text("暂无记录")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    ForEach(distribution, id: \.type) { item in
                        let fraction = totalSeconds > 0 ? Double(item.seconds) / Double(totalSeconds) : 0
                        Rectangle()
                            .fill(Color(hex: item.color))
                            .frame(maxWidth: .infinity)
                            .frame(width: 300 * fraction)
                    }
                }
                .frame(height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 16) {
                    ForEach(distribution.prefix(4), id: \.type) { item in
                        let pct = totalSeconds > 0 ? Int(Double(item.seconds) / Double(totalSeconds) * 100) : 0
                        LegendItem(color: Color(hex: item.color), text: "\(item.type) \(pct)%")
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }
}

struct ActivityRankingList: View {
    let ranking: [(name: String, seconds: Int, color: String)]
    let totalSeconds: Int

    var body: some View {
        if ranking.isEmpty {
            Text("暂无记录")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                ForEach(ranking, id: \.name) { item in
                    let pct = totalSeconds > 0 ? Int(Double(item.seconds) / Double(totalSeconds) * 100) : 0
                    ActivityRankingRow(
                        name: item.name,
                        duration: Self.fmtDuration(item.seconds),
                        percentage: pct,
                        color: Color(hex: item.color)
                    )
                }
            }
        }
    }

    private static func fmtDuration(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 { return "\(totalSeconds)秒" }
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        if h > 0 && m > 0 { return "\(h)小时\(m)分钟" }
        if h > 0 { return "\(h)小时" }
        return "\(m)分钟"
    }
}

struct ActivityRankingRow: View {
    let name: String
    let duration: String
    let percentage: Int
    let color: Color

    var body: some View {
        HStack {
            Text(name)
                .font(.subheadline)
                .frame(width: 60, alignment: .leading)

            ProgressView(value: Double(percentage), total: 100)
                .tint(color)

            Text(duration)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}


#Preview {
    StatisticsView(viewModel: ActivityViewModel())
}
