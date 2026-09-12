import SwiftUI

/// Card waterfall reveal (docs/BOOT_ANIMATION_SPEC.md "Card waterfall").
/// Cards start hidden (opacity 0, 10 pt below their place) and are revealed
/// top-to-bottom, one every 115 ms, driven by `BootLoaderModel`.
private struct BootRevealModifier: ViewModifier {
    @Environment(BootLoaderModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int

    /// `.boot-reveal-item { transition: opacity 320ms ease, transform 360ms
    /// cubic-bezier(.16,1,.3,1) }` — the two properties ride different
    /// curves, so each gets its own scoped `animation(_:value:)`.
    private static let fade = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32)
    private static let rise = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)

    func body(content: Content) -> some View {
        let revealed = model.isCardRevealed(index: index)
        content
            .opacity(revealed ? 1 : 0)
            .animation(reduceMotion ? nil : Self.fade, value: revealed)
            // Reduced motion: `transition-duration: 1ms; transform: none`.
            .offset(y: revealed || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? nil : Self.rise, value: revealed)
    }
}

extension View {
    /// Attach to a top-level card in the first page's waterfall. `index`
    /// is the card's zero-based position (top-to-bottom).
    func bootReveal(index: Int) -> some View {
        modifier(BootRevealModifier(index: index))
    }
}
