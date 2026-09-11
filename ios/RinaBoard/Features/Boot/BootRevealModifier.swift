import SwiftUI

/// Card waterfall reveal (docs/BOOT_ANIMATION_SPEC.md "Card waterfall").
/// Cards start hidden (opacity 0, translateY 10px) and are revealed
/// top-to-bottom, one every 115ms, driven by `BootLoaderModel`.
private struct BootRevealModifier: ViewModifier {
    @Environment(BootLoaderModel.self) private var model
    let index: Int

    func body(content: Content) -> some View {
        let revealed = model.revealedCount > index
        content
            .offset(y: revealed ? 0 : 10)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.36), value: revealed)
            .opacity(revealed ? 1 : 0)
            .animation(.easeOut(duration: 0.32), value: revealed)
    }
}

extension View {
    /// Attach to a top-level card in the first page's waterfall. `index`
    /// is the card's zero-based position (top-to-bottom).
    func bootReveal(index: Int) -> some View {
        modifier(BootRevealModifier(index: index))
    }
}
