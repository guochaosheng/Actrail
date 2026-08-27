import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            VStack {
                Image(systemName: "map.fill")
                    .imageScale(.large)
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("行迹")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("记录每日活动轨迹")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .navigationTitle("活动")
        }
    }
}

#Preview {
    ContentView()
}
