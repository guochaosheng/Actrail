import SwiftUI

struct HomeView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var showingAddActivity = false
    @State private var showingTypeManage = false
    @State private var isEditMode = false
    @State private var activityToDelete: ActivityType?
    @State private var showDeleteConfirm = false
    @State private var draggingTypeID: UUID?
    @State private var dragOrder: [ActivityType]?
    @State private var dragLocation: CGPoint = .zero
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var wiggleTick: Date = Date()
    private let wiggleTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
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
                    .padding(.bottom, 16)

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
                    .padding(.top, viewModel.activeRecords.isEmpty ? 0 : 32)
                    .padding(.bottom, 12)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 20) {
                    ForEach(Array(currentOrder.enumerated()), id: \.element.id) { index, type in
                        let cell = ActivityTypeButton(
                            type: type,
                            isEditMode: isEditMode,
                            isWiggling: isEditMode,
                            wigglePhase: Double(index) * 0.8,
                            wiggleDate: wiggleTick,
                            onDelete: {
                                activityToDelete = type
                                showDeleteConfirm = true
                            },
                            action: {
                                if !isEditMode {
                                    HapticFeedback.impact(.light)
                                    viewModel.startActivity(type)
                                }
                            }
                        )
                        if isEditMode {
                            cell
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CellCenterPreferenceKey.self,
                                            value: [CellCenterEntry(id: type.id, frame: geo.frame(in: .global))]
                                        )
                                    }
                                )
                                .opacity(draggingTypeID == type.id ? 0.15 : 1)
                                .scaleEffect(draggingTypeID == type.id ? 0.9 : 1)
                                .animation(.easeInOut(duration: 0.2), value: draggingTypeID)
                                .gesture(dragGesture(for: type))
                        } else {
                            cell
                        }
                    }
                }
                .onPreferenceChange(CellCenterPreferenceKey.self) { entries in
                    for entry in entries {
                        cellFrames[entry.id] = entry.frame
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 80)
            }
        }

            if isEditMode, let draggingType = currentOrder.first(where: { $0.id == draggingTypeID }),
               let frame = cellFrames[draggingType.id] {
                GeometryReader { geo in
                    let origin = geo.frame(in: .global).origin
                    ActivityTypeButton(
                        type: draggingType,
                        isEditMode: true,
                        isWiggling: false,
                        onDelete: {},
                        action: {}
                    )
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(1.1)
                    .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)
                    .position(x: dragLocation.x - origin.x, y: dragLocation.y - origin.y)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                .allowsHitTesting(false)
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
        .onChange(of: isEditMode) { _, newValue in
            if !newValue {
                draggingTypeID = nil
                dragOrder = nil
                dragLocation = .zero
            }
        }
        .onReceive(wiggleTimer) { date in
            guard isEditMode else { return }
            wiggleTick = date
        }
        .onAppear {
            if CommandLine.arguments.contains("-ACTRAIL_EDITMODE") {
                isEditMode = true
            }
        }
    }

    private var currentOrder: [ActivityType] {
        dragOrder ?? viewModel.activityTypes
    }

    private func dragGesture(for type: ActivityType) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    withAnimation(.spring(duration: 0.25)) {
                        draggingTypeID = type.id
                        if let frame = cellFrames[type.id] {
                            dragLocation = CGPoint(x: frame.midX, y: frame.midY)
                        }
                    }
                    HapticFeedback.impact(.medium)
                case .second(true, let dragValue?):
                    dragLocation = dragValue.location
                    updateDragTarget(at: dragValue.location)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, _) = value, let ordered = dragOrder {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.reorderActivityTypes(ordered)
                    }
                }
                withAnimation(.spring(duration: 0.25)) {
                    draggingTypeID = nil
                    dragOrder = nil
                    dragLocation = .zero
                }
            }
    }

    private func updateDragTarget(at location: CGPoint) {
        guard let draggingID = draggingTypeID else { return }
        guard let nearest = cellFrames.min(by: {
            Self.distance(CGPoint(x: $0.value.midX, y: $0.value.midY), location)
                < Self.distance(CGPoint(x: $1.value.midX, y: $1.value.midY), location)
        }), nearest.key != draggingID else { return }
        let current = currentOrder
        guard let fromIndex = current.firstIndex(where: { $0.id == draggingID }),
              let toIndex = current.firstIndex(where: { $0.id == nearest.key }),
              fromIndex != toIndex else { return }
        var newOrder = current
        newOrder.move(fromOffsets: IndexSet(integer: fromIndex),
                      toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        guard newOrder.map(\.id) != current.map(\.id) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dragOrder = newOrder
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
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
    var isWiggling: Bool = false
    var wigglePhase: Double = 0
    var wiggleDate: Date = Date()
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
        .background(Color.clear)
        .iconWiggle(isWiggling, date: wiggleDate, phase: wigglePhase)
        .onTapGesture {
            if !isEditMode {
                action()
            }
        }
    }
}

struct IconWiggleModifier: ViewModifier {
    let date: Date
    let phase: Double

    func body(content: Content) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let main = sin(t * 15.6 + phase) * 2.2
        let secondary = sin(t * 20.8 + phase * 1.3) * 0.7
        return content.rotationEffect(.degrees(main + secondary))
    }
}

extension View {
    @ViewBuilder
    func iconWiggle(_ enabled: Bool, date: Date, phase: Double) -> some View {
        if enabled {
            modifier(IconWiggleModifier(date: date, phase: phase))
        } else {
            self
        }
    }
}

struct CellCenterEntry: Equatable {
    let id: UUID
    let frame: CGRect
}

struct CellCenterPreferenceKey: PreferenceKey {
    static var defaultValue: [CellCenterEntry] = []
    static func reduce(value: inout [CellCenterEntry], nextValue: () -> [CellCenterEntry]) {
        value.append(contentsOf: nextValue())
    }
}

#Preview {
    HomeView(viewModel: ActivityViewModel())
}
