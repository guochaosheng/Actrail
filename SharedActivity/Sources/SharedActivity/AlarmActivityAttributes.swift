import Foundation
import ActivityKit

public struct AlarmActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var countdownEndDate: Date
        
        public init(countdownEndDate: Date) {
            self.countdownEndDate = countdownEndDate
        }
    }

    public var activityName: String
    public var activityIconName: String
    public var activityColor: String
    public var reminderId: String

    public init(activityName: String, activityIconName: String, activityColor: String, reminderId: String) {
        self.activityName = activityName
        self.activityIconName = activityIconName
        self.activityColor = activityColor
        self.reminderId = reminderId
    }
}
