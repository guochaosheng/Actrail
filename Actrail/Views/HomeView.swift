import SwiftUI

struct HomeView: View {
    @EnvironmentObject var viewModel: ActivityViewModel
    @State private var showingAddActivity = false
    @State private var selectedActivity: ActivityType?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 正在进行的活动
                    if !viewModel.activeRecords.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("正在进行")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            ForEach(viewModel.activeRecords) { record in
                                ActiveActivityCard(record: record)
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    // 活动类型网格
                    VStack(alignment: .leading, spacing: 12) {
                        Text("开始新活动")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
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
                    }
                    .padding(.horizontal)
                    
                    // 今日统计
                    VStack(alignment: .leading, spacing: 12) {
                        Text("今日统计")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        TodaySummaryCard(records: viewModel.todayRecords)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("行迹")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddActivity = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddActivity) {
                AddActivityTypeView()
            }
        }
    }
}

struct ActiveActivityCard: View {
    @EnvironmentObject var viewModel: ActivityViewModel
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

struct TodaySummaryCard: View {
    let records: [ActivityRecord]
    
    var completedRecords: [ActivityRecord] {
        records.filter { !$0.isActive }
    }
    
    var totalDuration: TimeInterval {
        completedRecords.reduce(0) { $0 + $1.duration }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("总时长")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(formatDuration(totalDuration))
                        .font(.title)
                        .fontWeight(.bold)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("活动次数")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("\(completedRecords.count)")
                        .font(.title)
                        .fontWeight(.bold)
                }
            }
            
            if !completedRecords.isEmpty {
                Divider()
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(groupedRecords, id: \.0) { type, duration in
                            VStack(spacing: 4) {
                                Text(type.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatDuration(duration))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
    
    var groupedRecords: [(ActivityType, TimeInterval)] {
        let grouped = Dictionary(grouping: completedRecords) { $0.activityType! }
        return grouped.map { (type, records) in
            (type, records.reduce(0) { $0 + $1.duration })
        }.sorted { $0.1 > $1.1 }
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)小时\(minutes)分钟"
        } else {
            return "\(minutes)分钟"
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(ActivityViewModel())
}
