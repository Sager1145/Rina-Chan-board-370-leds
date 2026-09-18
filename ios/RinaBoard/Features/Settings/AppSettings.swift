import SwiftUI

/// Keys for app-only preferences (design guide §34). Stored in
/// `UserDefaults` via `@AppStorage` so the views that consume them stay in
/// sync without another observable object.
///
/// Deliberately absent: an in-app light/dark switch. The UI follows system
/// appearance (§34, §57).
enum AppSettingsKey {
    /// Draw the photo of the physical board behind the LED matrix.
    static let showBoardPhoto = "showBoardPhoto"
    /// Sensory feedback on LED toggles, face steps and mode changes (§42).
    static let hapticsEnabled = "hapticsEnabled"
    /// Keep the screen awake while the app is in the foreground.
    static let keepScreenAwake = "keepScreenAwake"
    /// Reopen the tab that was selected last launch.
    static let restoreLastTab = "restoreLastTab"
    /// Persisted selection for `restoreLastTab`.
    static let lastSelectedTab = "lastSelectedTab"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showBoardPhoto: true,
            hapticsEnabled: true,
            keepScreenAwake: false,
            restoreLastTab: false,
        ])
    }
}

/// The app's display language, chosen in Settings.
///
/// Stored as the per-app `AppleLanguages` override — the same value iOS
/// writes when the user picks a language for this app in the system Settings
/// app — so the two stay in sync and there is no second key to reconcile.
/// Bundles resolve their localization once per launch, so a change takes
/// effect the next time the app is opened.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case english = "en"

    private static let preferenceKey = "AppleLanguages"

    var id: String { rawValue }

    /// The language's name in that language, so it can be found whatever
    /// language the UI is currently in. `nil` for `.system`.
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }

    /// The saved choice. Only the app's persistent domain counts: an
    /// `-AppleLanguages` launch argument (UI tests) is not a user choice.
    static var saved: AppLanguage {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?[preferenceKey] as? [String],
              let first = languages.first,
              let match = Bundle.preferredLocalizations(
                  from: allCases.filter { $0 != .system }.map(\.rawValue),
                  forPreferences: [first]
              ).first
        else { return .system }
        return AppLanguage(rawValue: match) ?? .system
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.preferenceKey)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.preferenceKey)
        }
    }

    /// Whether choosing this language changes what the running app shows,
    /// i.e. whether the user has to reopen the app to see it.
    var needsRelaunch: Bool {
        let preferences: [String]
        if self == .system {
            preferences = CFPreferencesCopyValue(
                Self.preferenceKey as CFString, kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            ) as? [String] ?? Locale.preferredLanguages
        } else {
            preferences = [rawValue]
        }
        let target = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
        return target != Bundle.main.preferredLocalizations.first
    }
}
