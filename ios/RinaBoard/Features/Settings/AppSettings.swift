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
