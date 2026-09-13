import SwiftUI

struct HomeView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var showingAddActivity = false
    @State private var showingTypeManage = false
    @State private var isEditMode = false
    @State private var activityToDelete: ActivityType?
    @State private var showDeleteConfirm = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 编辑/+ 按钮
                HStack {
                    Button(action: { isEditMode.toggle() }) {
                        Text(isEditMode ? "完成" : "编辑")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color(.systemBackground))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    Button(action: { showingAddActivity = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                            .background(Color(.systemBackground))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // 大标题
                Text("行迹")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                // 正在进行的活动
                if !viewModel.activeRecords.isEmpty {
                    Text("正在进行")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 10)

                    ForEach(viewModel.activeRecords) { record in
                        ActiveActivityCard(viewModel: viewModel, record: record)
                            .padding(.horizontal, 16)
                    }
                }

                // 活动类型网格
                Text("记录活动")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 20) {
                    ForEach(viewModel.activityTypes) { type in
                        ActivityTypeButton(type: type, isEditMode: isEditMode, onDelete: {
                            activityToDelete = type
                            showDeleteConfirm = true
                        }, action: {
                            if !isEditMode {
                                HapticFeedback.impact(.light)
                                viewModel.startActivity(type)
                            }
                        })
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 80)
            }
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingTypeManage) {
            ActivityTypeManageView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingAddActivity) {
            AddActivityTypeView(viewModel: viewModel)
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                if let type = activityToDelete {
                    viewModel.deleteActivityType(type)
                    activityToDelete = nil
                }
            }
        } message: {
            Text("确定要删除「\(activityToDelete?.name ?? "")」吗？此操作不可撤销。")
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
                HapticFeedback.impact(.medium)
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
    var isEditMode: Bool = false
    var onDelete: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                Image(systemName: type.iconName)
                    .font(.title2)
                    .foregroundColor(Color(hex: type.color))
                    .frame(width: 64, height: 64)
                    .background(Color(hex: type.color).opacity(0.2))
                    .clipShape(Circle())

                if isEditMode {
                    Button(action: { onDelete?() }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 22))
                    }
                    .offset(x: -4, y: -4)
                }
            }

            Text(type.name)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditMode {
                action()
            }
        }
    }
}

#Preview {
    HomeView(viewModel: ActivityViewModel())
}
