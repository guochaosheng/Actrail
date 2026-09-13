import SwiftUI

enum AppSettings {
    static let notificationsEnabledKey = "settings.notificationsEnabled"
    static let hapticFeedbackKey = "settings.hapticFeedback"
    static let autoBackupKey = "settings.autoBackup"
    static let accentColorKey = "settings.accentColor"
    static let colorSchemeKey = "settings.colorScheme"
    static let lastAutoBackupDateKey = "settings.lastAutoBackupDate"
    static let lastAutoBackupURLKey = "settings.lastAutoBackupURL"

    static let defaultAccentColorHex = "#007AFF"

    static var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: notificationsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: notificationsEnabledKey) }
    }

    static var hapticFeedbackEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hapticFeedbackKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hapticFeedbackKey) }
    }

    static var autoBackupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoBackupKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: autoBackupKey) }
    }

    static var accentColorHex: String {
        get { UserDefaults.standard.string(forKey: accentColorKey) ?? defaultAccentColorHex }
        set { UserDefaults.standard.set(newValue, forKey: accentColorKey) }
    }

    static var colorSchemeMode: String {
        get { UserDefaults.standard.string(forKey: colorSchemeKey) ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: colorSchemeKey) }
    }

    static var resolvedColorScheme: ColorScheme? {
        switch colorSchemeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static var lastAutoBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: lastAutoBackupDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastAutoBackupDateKey) }
    }

    static var lastAutoBackupURL: String? {
        get { UserDefaults.standard.string(forKey: lastAutoBackupURLKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastAutoBackupURLKey) }
    }
}