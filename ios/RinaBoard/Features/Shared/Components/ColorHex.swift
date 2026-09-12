import SwiftUI
import RinaCore

extension Color {
    /// Parses "#RRGGBB" / "RRGGBB" (case-insensitive).
    init?(hex: String) {
        guard let (r, g, b) = RGBHex.parseHex(hex) else { return nil }
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// "#rrggbb" for an sRGB colour.
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBHex.formatHex(r: Int((r * 255).rounded()),
                                g: Int((g * 255).rounded()),
                                b: Int((b * 255).rounded()))
    }
}

/// The board's fallback colour when a hex string can't be parsed.
extension Color {
    static let rinaPink = Color(hex: "#ec3fc7") ?? .pink
}
