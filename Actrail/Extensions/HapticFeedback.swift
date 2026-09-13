import UIKit

enum HapticFeedback {
    static func enabled() -> Bool {
        AppSettings.hapticFeedbackEnabled
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard enabled() else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        guard enabled() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard enabled() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        guard enabled() else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}