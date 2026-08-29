import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject var viewModel: ActivityViewModel
    @State private var selectedPeriod = "今日"
    let periods = ["今日", "本周", "本月"]
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 时间段选择
                    Picker("时间段", selection: $selectedPeriod) {
                        ForEach(periods, id: \.self) { period in
                            Text(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    // 总时长卡片
                    SummaryCard(
                        title: "总时长",
                        value: "8小时30分钟",
                        subtitle: "比昨天多2小时",
                        icon: "clock.fill",
                        color: .blue
                    )
                    .padding(.horizontal)
                    
                    // 活动分布
                    VStack(alignment: .leading, spacing: 12) {
                        Text("活动分布")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        ActivityDistributionChart()
                            .frame(height: 200)
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                            .padding(.horizontal)
                    }
                    
                    // 活动排行
                    VStack(alignment: .leading, spacing: 12) {
                        Text("活动排行")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        ActivityRankingList()
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("统计")
        }
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
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

struct ActivityDistributionChart: View {
    var body: some View {
        VStack {
            // 简单的饼图示例
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 100)
                Rectangle()
                    .fill(Color.green)
                    .frame(width: 60)
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 40)
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: 20)
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // 图例
            HStack(spacing: 16) {
                LegendItem(color: .blue, text: "工作 50%")
                LegendItem(color: .green, text: "运动 30%")
                LegendItem(color: .orange, text: "阅读 20%")
            }
            .font(.caption)
        }
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
    var body: some View {
        VStack(spacing: 12) {
            ActivityRankingRow(name: "工作", duration: "4小时", percentage: 50, color: .blue)
            ActivityRankingRow(name: "运动", duration: "2小时", percentage: 30, color: .green)
            ActivityRankingRow(name: "阅读", duration: "1小时", percentage: 20, color: .orange)
        }
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
    StatisticsView()
        .environmentObject(ActivityViewModel())
}
