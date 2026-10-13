#if targetEnvironment(macCatalyst)
import SwiftUI

/// Catalyst can keep a regular width class even in a narrow window. Share
/// the measured window decision with the pages and their control placement.
enum MacWindowLayoutPolicy {
    // Catalyst layout points are scaled for Mac controls. Leave enough room
    // for both columns instead of reusing the iPad's unscaled threshold.
    static let splitMinimumWidth: CGFloat = 1024

    static func sizeClass(forWidth width: CGFloat) -> UserInterfaceSizeClass {
        width >= splitMinimumWidth ? .regular : .compact
    }
}

private struct MacWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var macWindowWidth: CGFloat? {
        get { self[MacWindowWidthKey.self] }
        set { self[MacWindowWidthKey.self] = newValue }
    }
}

struct MacWindowLayout: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            // Keep Catalyst's native top tabs. Overriding the system width
            // class would turn them into a phone-style bottom tab bar.
            content.environment(\.macWindowWidth, proxy.size.width)
        }
        .background(MacWindowSize())
    }
}

/// Allow the window to become narrow enough to use the compact layout.
private struct MacWindowSize: UIViewRepresentable {
    func makeUIView(context: Context) -> SizeView { SizeView() }
    func updateUIView(_ view: SizeView, context: Context) {}

    final class SizeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 520, height: 600)
        }
    }
}
#endif
