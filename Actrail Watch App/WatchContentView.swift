import SwiftUI

struct WatchContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "map.fill")
                .imageScale(.large)
                .font(.system(size: 40))
                .foregroundColor(.blue)
            
            Text("行迹")
                .font(.headline)
                .fontWeight(.bold)
            
            Text("记录每日活动")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    WatchContentView()
}
