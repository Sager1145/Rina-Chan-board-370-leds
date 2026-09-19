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

    /// Tracks whether this instance's page is actually on screen: a page
    /// covered by a `NavigationStack` push stays mounted (its `onAppear` has
    /// already fired and does not fire again on the pop back to it), but
    /// should not keep drawing star frames while hidden underneath. Starts
    /// `false` so a freshly pushed page does not draw a frame before its own
    /// `onAppear` runs.
    @State private var isPageVisible = false

    /// `-disableStarAnimation YES` freezes the stars at a fixed point in
    /// their cycle (`RinaStarfieldSourceSpec.snapshotTime`), generated from a
    /// fixed seed, so automated screenshots are pixel-stable.
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
            RinaStarfield(isPaused: bootLoader?.isVisible ?? false,
                          isFrozen: Self.isFrozen,
                          isPageVisible: isPageVisible)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isPageVisible = true }
        .onDisappear { isPageVisible = false }
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
        if isEnabled {
            modifier(RinaScrollBackground())
        } else {
            self
        }
    }

    /// See-through cards, so the backdrop's stars show under the rows like
    /// they do under the pill buttons. Apply to a `List`'s content: set on
    /// the `List` itself the row background never reaches its rows. A row
    /// with its own `listRowBackground` (a pill row, the board preview) keeps
    /// it. Pass the same flag as `rinaScrollBackground(_:)`, so a sheet keeps
    /// its system cells.
    @ViewBuilder
    func rinaTranslucentRows(_ isEnabled: Bool = true) -> some View {
        if isEnabled {
            listRowBackground(Color(.secondarySystemGroupedBackground).opacity(0.75))
        } else {
            self
        }
    }
}

extension EnvironmentValues {
    /// Set by a container that draws one `RinaAppBackdrop` under several
    /// columns (Settings' two-column layout): screens inside it only clear
    /// their own ground instead of drawing a second backdrop over part of it.
    @Entry var rinaBackdropIsShared = false
}

private struct RinaScrollBackground: ViewModifier {
    @Environment(\.rinaBackdropIsShared) private var isShared

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // A plain `.background` is covered by the navigation container's
            // own opaque ground whenever the navigation bar is visible.
            if isShared {
                content.scrollContentBackground(.hidden)
                    .containerBackground(.clear, for: .navigation)
            } else {
                content.scrollContentBackground(.hidden)
                    .containerBackground(for: .navigation) { RinaAppBackdrop() }
            }
        } else if isShared {
            content.scrollContentBackground(.hidden)
        } else {
            content.scrollContentBackground(.hidden)
                .background { RinaAppBackdrop() }
        }
    }
}
