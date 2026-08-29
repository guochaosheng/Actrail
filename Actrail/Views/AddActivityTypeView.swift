import SwiftUI

struct AddActivityTypeView: View {
    @EnvironmentObject var viewModel: ActivityViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var name = ""
    @State private var selectedIcon = "star.fill"
    @State private var selectedColor = "#007AFF"
    @State private var group = "默认"
    
    let icons = [
        "star.fill", "heart.fill", "book.fill", "figure.run",
        "briefcase.fill", "moon.fill", "sun.min.fill", "cloud.fill",
        "music.note", "gamecontroller.fill", "cart.fill", "house.fill",
        "car.fill", "airplane", "bicycle", "figure.walk"
    ]
    
    let colors = [
        "#007AFF", "#34C759", "#FF9500", "#FF2D55",
        "#5856D6", "#AF52DE", "#FF3B30", "#FFCC00"
    ]
    
    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("活动名称", text: $name)
                    TextField("分组", text: $group)
                }
                
                Section("选择图标") {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.title2)
                                .foregroundColor(selectedIcon == icon ? Color(hex: selectedColor) : .gray)
                                .frame(width: 50, height: 50)
                                .background(selectedIcon == icon ? Color(hex: selectedColor).opacity(0.2) : Color(.systemGray6))
                                .clipShape(Circle())
                                .onTapGesture {
                                    selectedIcon = icon
                                }
                        }
                    }
                    .padding(.vertical)
                }
                
                Section("选择颜色") {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(colors, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .stroke(selectedColor == color ? Color.primary : Color.clear, lineWidth: 3)
                                )
                                .onTapGesture {
                                    selectedColor = color
                                }
                        }
                    }
                    .padding(.vertical)
                }
                
                Section {
                    Button(action: saveActivity) {
                        HStack {
                            Spacer()
                            Text("保存")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
            .navigationTitle("添加活动类型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    func saveActivity() {
        viewModel.addActivityType(
            name: name,
            iconName: selectedIcon,
            color: selectedColor,
            group: group
        )
        dismiss()
    }
}

#Preview {
    AddActivityTypeView()
        .environmentObject(ActivityViewModel())
}
