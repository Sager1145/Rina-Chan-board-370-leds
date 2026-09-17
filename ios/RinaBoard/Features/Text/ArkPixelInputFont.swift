import CoreText
import SwiftUI

/// The WebUI's scroll-text input font (`ark12.woff2`, "Ark Pixel 12px
/// Monospaced", copied from `legacy/webui_v1/data/resources/fonts/`). It is the
/// vector twin of the `ark12.json` bitmap table `ScrollRasterizer` turns into
/// frames, so the editor shows the same glyphs the board will scroll.
enum ArkPixelInputFont {
    /// One em of the font is 12 font pixels.
    static let gridSize: CGFloat = 12

    private static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "ark12", withExtension: "woff2"),
              let data = try? Data(contentsOf: url),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }()

    /// The font near `size`, snapped so every font pixel covers a whole number
    /// of device pixels at `displayScale` (4 pt steps on 3×, 6 pt on 2×), or
    /// the system body font if the bundled file is missing.
    static func font(size: CGFloat, displayScale: CGFloat) -> Font {
        guard let descriptor else { return .body }
        let step = gridSize / max(1, displayScale.rounded())
        let snapped = max(gridSize, (size / step).rounded() * step)
        return Font(CTFontCreateWithFontDescriptor(descriptor, snapped, nil))
    }

    /// Forces `descriptor`'s one-time load (the 843 KB woff2 read plus
    /// `CTFontManagerCreateFontDescriptorsFromData`) off the Text tab's first
    /// body evaluation (perf PR-9). `static let` initialization is
    /// thread-safe, so this can run from a background task started at boot;
    /// the result is unchanged either way.
    nonisolated static func prewarm() {
        _ = descriptor
    }
}
