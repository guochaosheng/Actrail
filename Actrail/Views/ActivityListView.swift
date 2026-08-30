import SwiftUI

struct ActivityListView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var selectedDate = Date()
    
    var body: some View {
        NavigationView {
            VStack {
                DatePicker("选择日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                
                List {
                    ForEach(viewModel.todayRecords) { record in
                        ActivityRecordRow(record: record)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.deleteRecord(record)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
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

struct ActivityTypeManageView: View {
    @Bindable var viewModel: ActivityViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showingAddType = false
    @State private var typeToDelete: ActivityType?
    @State private var showingDeleteConfirm = false
    
    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.activityTypes) { type in
                    HStack {
                        Image(systemName: type.iconName)
                            .foregroundColor(Color(hex: type.color))
                            .frame(width: 30)
                        Text(type.name)
                        Spacer()
                        Text(type.group)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            typeToDelete = type
                            showingDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("活动类型管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddType = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddType) {
                AddActivityTypeView(viewModel: viewModel)
            }
            .alert("确认删除", isPresented: $showingDeleteConfirm) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    if let type = typeToDelete {
                        viewModel.deleteActivityType(type)
                    }
                }
            } message: {
                if let type = typeToDelete {
                    Text("确定要删除「\(type.name)」吗？此操作不可撤销。")
                }
            }
        }
    }
}

#Preview {
    ActivityListView(viewModel: ActivityViewModel())
}
