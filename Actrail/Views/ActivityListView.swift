import SwiftUI

struct ActivityListView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var selectedDate = Date()
    @State private var showingDatePicker = false
    
    var body: some View {
        NavigationView {
            VStack {
                // 日期选择器
                DatePicker("选择日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                
                // 活动记录列表
                List {
                    ForEach(viewModel.todayRecords) { record in
                        ActivityRecordRow(record: record)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("历史记录")
            .onChange(of: selectedDate) { _ in
                viewModel.fetchTodayRecords()
            }
        }
    }
}

struct ActivityRecordRow: View {
    let record: ActivityRecord
    
    var body: some View {
        HStack {
            if let type = record.activityType {
                Image(systemName: type.iconName)
                    .foregroundColor(Color(hex: type.color))
                    .frame(width: 30)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(record.activityType?.name ?? "未知活动")
                    .font(.headline)
                
                Text(record.startTime, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                if record.isActive {
                    Text("进行中")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text(formatDuration(record.duration))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.vertical, 4)
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

#Preview {
    ActivityListView(viewModel: ActivityViewModel())
}
