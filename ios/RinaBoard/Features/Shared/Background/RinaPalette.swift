import SwiftUI

/// Decorative colours for the app backdrop. Interactive tint stays on the
/// `AccentColor` asset and text stays on `.primary` / `.secondary`; these
/// tokens only paint behind the system lists.
struct RinaPalette {
    let backgroundTop: Color
    let backgroundMiddle: Color
    let backgroundBottom: Color

    let ambientPink: Color
    let ambientPinkOpacity: Double
    let ambientLavender: Color
    let ambientLavenderOpacity: Double

    /// Appearance follows the system; there is no in-app light/dark switch.
    static func resolve(for colorScheme: ColorScheme) -> RinaPalette {
        colorScheme == .dark ? .dark : .light
    }

    static let light = RinaPalette(
        backgroundTop: hex("#FFF9FD"),
        backgroundMiddle: hex("#F8F4FF"),
        backgroundBottom: hex("#EDF7FF"),
        ambientPink: hex("#FFCFE9"),
        ambientPinkOpacity: 0.38,
        ambientLavender: hex("#DDD8FF"),
        ambientLavenderOpacity: 0.34
    )

    static let dark = RinaPalette(
        backgroundTop: hex("#0D0F1B"),
        backgroundMiddle: hex("#151329"),
        backgroundBottom: hex("#211329"),
        ambientPink: hex("#6B235B"),
        ambientPinkOpacity: 0.25,
        ambientLavender: hex("#342E6A"),
        ambientLavenderOpacity: 0.28
    )

    private static func hex(_ value: String) -> Color {
        Color(hex: value) ?? .clear
    }
}
