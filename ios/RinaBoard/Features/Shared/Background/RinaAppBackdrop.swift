import SwiftUI

/// The app-wide ground: a pink/lavender gradient with rising stars.
///
/// Attached per screen through `rinaScrollBackground()` rather than once under
/// the `TabView`: each tab's hosting controller paints an opaque system
/// background, so a layer behind the tabs never shows. Star positions derive
/// from wall-clock time, so a pushed screen's stars line up with the ones
/// under it.
struct RinaAppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Optional so previews without the app environment still render.
    @Environment(BootLoaderModel.self) private var bootLoader: BootLoaderModel?

    /// `-disableStarAnimation YES` holds the stars at their time-zero layout
    /// so automated screenshots are pixel-stable.
    private static let isFrozen = UserDefaults.standard.bool(forKey: "disableStarAnimation")

    var body: some View {
        let palette = RinaPalette.resolve(for: colorScheme)
        ZStack {
            LinearGradient(colors: [palette.backgroundTop, palette.backgroundMiddle, palette.backgroundBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [palette.ambientPink.opacity(palette.ambientPinkOpacity), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 520)
            // A cooler second glow keeps the ground from going uniformly pink.
            RadialGradient(colors: [palette.ambientLavender.opacity(palette.ambientLavenderOpacity), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 580)
            // Held still while the boot loader plays: it is tuned to keep the
            // main thread quiet during launch.
            RinaStarfield(palette: palette,
                          isPaused: bootLoader?.isVisible ?? false,
                          isFrozen: Self.isFrozen)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Replaces a `List` / `Form`'s opaque grouped background with the Rina
    /// backdrop, visible between sections; rows keep their system cell
    /// surface. Only for screens inside the tabs' navigation stacks: pass
    /// `false` where the same view is shown in a sheet, which keeps its
    /// system presentation background (the navigation container background
    /// would otherwise replace it).
    @ViewBuilder
    func rinaScrollBackground(_ isEnabled: Bool = true) -> some View {
        if !isEnabled {
            self
        } else if #available(iOS 18.0, *) {
            // A plain `.background` is covered by the navigation container's
            // own opaque ground whenever the navigation bar is visible.
            scrollContentBackground(.hidden)
                .containerBackground(for: .navigation) { RinaAppBackdrop() }
        } else {
            scrollContentBackground(.hidden)
                .background { RinaAppBackdrop() }
        }
    }
}
