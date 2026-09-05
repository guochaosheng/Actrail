import WidgetKit
import SwiftUI
import ActivityKit
import SharedActivity

@main
struct ActrailWidgetBundle: WidgetBundle {
    var body: some Widget {
        AlarmLiveActivity()
    }
}

struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmActivityAttributes.self) { context in
            LockScreenAlarmView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.activityIconName)
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.activityName)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AlarmCountdownText(context: context)
                        .font(.title3.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Label {
                        Text("按住以停止")
                    } icon: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.attributes.activityIconName)
                    .foregroundStyle(.blue)
            } compactTrailing: {
                AlarmCountdownText(context: context)
                    .frame(width: 44)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: context.attributes.activityIconName)
                    .foregroundStyle(.blue)
            }
            .keylineTint(.blue)
        }
    }
}

struct LockScreenAlarmView: View {
    let context: ActivityViewContext<AlarmActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: context.attributes.activityIconName)
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.activityName)
                    .font(.headline)
                Text("提醒进行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            AlarmCountdownText(context: context)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(.red)
        }
        .padding()
    }
}

struct AlarmCountdownText: View {
    let context: ActivityViewContext<AlarmActivityAttributes>

    var body: some View {
        Text(context.state.countdownEndDate, style: .timer)
            .monospacedDigit()
    }
}
