import SwiftUI

struct StatisticsView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var selectedPeriod = "今日"
    @State private var showCalendar = false
    let periods = ["今日", "本周", "本月"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 大标题（固定）
            HStack {
                Text("统计")
                    .font(.system(size: 34, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // 分段切换（固定）：日历 ↔ 趋势
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
                // 日历视图（日期栏固定，时间线独立滚动）
                CalendarHistorySection(viewModel: viewModel)
            } else {
                // 趋势视图（内容独立滚动）
                TrendStatsSection(viewModel: viewModel, selectedPeriod: $selectedPeriod, periods: periods)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - 日历历史视图
struct CalendarHistorySection: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var selectedDate = Date()
    @State private var calendarExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 日期栏（默认收缩，点击自顶向下滑出日历）
            Button {
                withAnimation(.spring(duration: 0.35)) {
                    calendarExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.blue)
                    Text(dateText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(calendarExpanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            .onChange(of: selectedDate) { _ in
                viewModel.selectedCalendarDate = selectedDate
                viewModel.fetchTodayRecords()
            }
            // 日期展开区域（条件渲染 + 以日期栏为顶点的下拉生长动画）
            if calendarExpanded {
                DatePicker("选择日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.7, anchor: .top).combined(with: .opacity)
                    ))
            }

            // 当日记录 → 时间线（仅此区域滚动，其余固定）
            ScrollViewReader { proxy in
                ScrollView {
                    ActivityTimelineView(records: viewModel.todayRecords, date: selectedDate)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .padding(.top, 8)
                }
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("nowScroller", anchor: .center)
                        }
                    }
                }
                .onChange(of: selectedDate) { _, _ in
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("nowScroller", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: selectedDate)
    }
}

// MARK: - 活动时间线（倒序、时间比例定位、重合分列）
struct ActivityTimelineView: View {
    struct Event: Identifiable {
        let id: UUID
        let start: Date
        let end: Date
        let name: String
        let color: String
        let isActive: Bool
        let duration: TimeInterval
        var top: CGFloat
        let height: CGFloat
        var endY: CGFloat
        let col: Int
        let colCount: Int
    }

    struct OverflowBlock: Identifiable {
        let id = UUID()
        let top: CGFloat
        let height: CGFloat
        let count: Int
        let col: Int
        let colCount: Int
    }

    struct TimeLabel: Identifiable {
        let id = UUID()
        let time: Date
        var y: CGFloat
    }

    let records: [ActivityRecord]
    let date: Date

    @State private var now = Date()

    private let hourHeight: CGFloat = 64
    private let topPad: CGFloat = 14
    private let bottomPad: CGFloat = 24
    private let minCardHeight: CGFloat = 56
    private let timeW: CGFloat = 42
    private let lineX: CGFloat = 46
    private let laneGap: CGFloat = 4
    private let maxLanes = 3
    private let minBlockGap: CGFloat = 3

    private var spanStart: Date? { records.map(\.startTime).min() }
    private var spanEnd: Date? { records.map { $0.endTime ?? now }.max() }

    private var hourRange: (first: Date, count: Int) {
        let cal = Calendar.current
        let first = cal.date(from: cal.dateComponents([.year, .month, .day], from: date))!
        return (first, 25)
    }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private func yForHour(_ t: Date) -> CGFloat {
        topPad + CGFloat(t.timeIntervalSince(hourRange.first) / 3600) * hourHeight
    }

    private var contentHeight: CGFloat {
        max(topPad + CGFloat(hourRange.count - 1) * hourHeight + bottomPad, 100)
    }

    private var layout: (events: [Event], overflow: [OverflowBlock], labels: [TimeLabel]) {
        guard spanStart != nil, spanEnd != nil else { return ([], [], []) }

        func yFor(_ t: Date) -> CGFloat {
            yForHour(t)
        }

        let asc = records.sorted { $0.startTime < $1.startTime }

        var groups: [[ActivityRecord]] = []
        var current: [ActivityRecord] = []
        var runningEnd: Date?
        for r in asc {
            let end = r.endTime ?? now
            if let re = runningEnd, r.startTime <= re {
                current.append(r)
                if end > re { runningEnd = end }
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [r]
                runningEnd = end
            }
        }
        if !current.isEmpty { groups.append(current) }

        var result: [Event] = []
        var overflowBlocks: [OverflowBlock] = []
        for group in groups {
            var colEnds: [Date] = []
            var placed: [(record: ActivityRecord, col: Int, end: Date)] = []
            var overflow: [(record: ActivityRecord, end: Date)] = []

            for r in group {
                let end = r.endTime ?? now
                var col = -1
                for i in 0..<colEnds.count where i < maxLanes {
                    if colEnds[i] <= r.startTime {
                        col = i
                        break
                    }
                }
                if col < 0 && colEnds.count < maxLanes {
                    col = colEnds.count
                    colEnds.append(end)
                } else if col >= 0 {
                    colEnds[col] = end
                } else {
                    overflow.append((r, end))
                    continue
                }
                placed.append((r, col, end))
            }

            let totalLanes = overflow.isEmpty ? max(colEnds.count, 1) : maxLanes + 1

            for (r, col, end) in placed {
                let top = yFor(r.startTime)
                let bottom = yFor(end)
                let h = max(bottom - top, minCardHeight)
                result.append(Event(
                    id: r.id,
                    start: r.startTime,
                    end: end,
                    name: r.activityType?.name ?? "未知",
                    color: r.activityType?.color ?? "9E9E9E",
                    isActive: r.isActive,
                    duration: r.isActive ? now.timeIntervalSince(r.startTime) : end.timeIntervalSince(r.startTime),
                    top: top,
                    height: h,
                    endY: r.isActive ? bottom : top + h,
                    col: col,
                    colCount: totalLanes
                ))
            }

            if !overflow.isEmpty {
                var clusters: [(top: Date, bottom: Date, count: Int)] = []
                var curTop = overflow[0].record.startTime
                var curBottom = overflow[0].end
                var count = 1
                for item in overflow.dropFirst() {
                    if item.record.startTime <= curBottom {
                        curBottom = max(curBottom, item.end)
                        count += 1
                    } else {
                        clusters.append((curTop, curBottom, count))
                        curTop = item.record.startTime
                        curBottom = item.end
                        count = 1
                    }
                }
                clusters.append((curTop, curBottom, count))
                for c in clusters {
                    let top = yFor(c.top)
                    let bottom = yFor(c.bottom)
                    let h = max(bottom - top, minCardHeight)
                    overflowBlocks.append(OverflowBlock(top: top, height: h, count: c.count, col: maxLanes, colCount: totalLanes))
                }
            }
        }

        // 同列活动块不得重叠：按开始时间顺序解算，必要时将其下移，再贴块顶部边框确定时间虚线
        let ordered = result.sorted { $0.start < $1.start }
        var colBottom: [Int: CGFloat] = [:]
        var resolved: [Event] = []
        for var ev in ordered {
            let bump = colBottom[ev.col] ?? 0
            let finalTop = max(ev.top, bump)
            ev.top = finalTop
            if !ev.isActive {
                ev.endY = finalTop + ev.height
            }
            colBottom[ev.col] = finalTop + ev.height + minBlockGap
            resolved.append(ev)
        }

        return (resolved, overflowBlocks, [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if layout.events.isEmpty {
                Text("暂无记录")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                scheduleBody
            }
        }
        .onAppear {
            now = Date()
        }
    }

    private var scheduleBody: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let lanesLeft = lineX + 6
            let lanesW = totalW - lanesLeft
            let dashW = totalW - lineX
            let overflowSlotW: CGFloat = 35
            let laneW: (Int) -> CGFloat = { colCount in
                if colCount > maxLanes {
                    return (lanesW - overflowSlotW - laneGap * CGFloat(colCount - 1)) / CGFloat(maxLanes)
                }
                return (lanesW - laneGap * CGFloat(colCount - 1)) / CGFloat(colCount)
            }
            let centerX: (Int, Int) -> CGFloat = { col, colCount in
                let w = laneW(colCount)
                if colCount > maxLanes {
                    if col >= maxLanes {
                        return lanesLeft + CGFloat(maxLanes) * (w + laneGap) + overflowSlotW / 2
                    }
                    return lanesLeft + CGFloat(col) * (w + laneGap) + w / 2
                }
                return lanesLeft + CGFloat(col) * (w + laneGap) + w / 2
            }

            ZStack(alignment: .topLeading) {
                // 全高竖线（时间轴）
                Rectangle()
                    .fill(Color(.systemGray4))
                    .frame(width: 1.5)
                    .position(x: lineX, y: contentHeight / 2)

                // 当前时间定位标记（透明，仅供 ScrollView 默认滚动对位）
                Color.clear
                    .frame(width: 1, height: 1)
                    .position(x: lineX, y: isToday ? yForHour(now) : topPad)
                    .id("nowScroller")

                // 整点网格：每小时一条水平虚线 + 左侧 "HH:00" 标签
                ForEach(Array(0..<hourRange.count), id: \.self) { i in
                    let y = topPad + CGFloat(i) * hourHeight
                    DashLine()
                        .stroke(Color(.systemGray5), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .frame(width: dashW, height: 1)
                        .position(x: lineX + dashW / 2, y: y)
                    let hourDate = hourRange.first.addingTimeInterval(TimeInterval(i) * 3600)
                    Text(Self.hourLabel(hourDate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: timeW, alignment: .trailing)
                        .position(x: timeW / 2, y: y)
                }

                ForEach(layout.events) { ev in
                    let w = laneW(ev.colCount)
                    let cx = centerX(ev.col, ev.colCount)

                    // 记录卡片（顶部边框贴合起点水平线）
                    eventCard(ev)
                        .frame(width: w, height: ev.height, alignment: .topLeading)
                        .position(x: cx, y: ev.top + ev.height / 2)
                }

                // 溢出（超过 3 列）用小块 +N 表示
                ForEach(layout.overflow) { ob in
                    let w = laneW(ob.colCount)
                    let cx = centerX(ob.col, ob.colCount)
                    moreBlock(count: ob.count)
                        .frame(width: min(w, overflowSlotW), height: ob.height)
                        .position(x: cx, y: ob.top + ob.height / 2)
                }
            }
            .frame(width: totalW, height: contentHeight)
        }
        .frame(height: contentHeight)
    }

    private func eventCard(_ ev: Event) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ev.name)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(2)
            Text("\(Self.timeString(ev.start))（\(Int(ev.duration / 60))分）")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(hex: ev.color).opacity(0.18))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: ev.color).opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func moreBlock(count: Int) -> some View {
        VStack(spacing: 2) {
            Text("···")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text("+\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGray5).opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray5), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static func hourLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:00"
        return f.string(from: date)
    }

    static func durationString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// 水平虚线
private struct DashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
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
        ScrollView {
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

            Spacer(minLength: 80)
            }
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
