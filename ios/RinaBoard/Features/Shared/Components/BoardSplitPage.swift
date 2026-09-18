import SwiftUI

/// Whether a board page shows its preview and its controls side by side.
///
/// iPad only, and only while the window is actually regular-width: a Split
/// View slide-over is a phone-shaped window and gets the phone's single
/// column. A landscape iPhone Max reports a regular width class too, which is
/// why the idiom is checked as well — the board and a full control panel do
/// not fit beside each other in 430 pt.
enum BoardPageColumns {
    /// Width class only, never orientation: portrait and landscape iPad
    /// windows are both regular-width, so the two columns hold in every
    /// orientation and only a genuinely narrow window (Slide Over, a thin
    /// Split View pane) drops back to one.
    static func isSplit(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }
}

/// The shared skeleton of every page that has a board preview: one `List` on
/// a phone, two columns on iPad.
///
/// A page hands over the board and its status line separately. On a phone
/// they become the list's first section (`Section { board } footer: { status }`),
/// exactly as the pages used to build it themselves. On iPad they are pinned
/// at the top of the preview column — the board never scrolls away — and only
/// the Control Center under it scrolls (§5–§11), so the board-global controls
/// are reachable from every page without the tab-bar accessory the phone
/// layout uses. Settings has no preview and therefore no such column — it
/// has its own adaptive layout (`SettingsView`).
///
/// The caller keeps its own list modifiers (`listSectionSpacing`,
/// `rinaScrollBackground`, `contentMargins`, `scrollDisabled`, alerts): all of
/// them propagate through this view to both lists, so a page reads the same as
/// it did when it built the `List` itself. What a page must *not* do any more
/// is apply `rinaTranslucentRows()` — this view applies it to both columns.
struct BoardSplitPage<Board: View, Status: View, Controls: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let board: Board
    private let status: Status
    private let controls: Controls

    init(@ViewBuilder board: () -> Board,
         @ViewBuilder status: () -> Status,
         @ViewBuilder controls: () -> Controls) {
        self.board = board()
        self.status = status()
        self.controls = controls()
    }

    var body: some View {
        if BoardPageColumns.isSplit(horizontalSizeClass) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    pinnedPreview
                    List {
                        Group {
                            BoardControlCenterView(isEmbedded: true)
                        }
                        .rinaTranslucentRows()
                    }
                    .modifier(SharedControlCenterScroll())
                }
                // Equal halves, measured against the page rather than laid
                // out by the stack, so rotating keeps them equal.
                .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 0)

                List {
                    Group {
                        controls
                    }
                    .rinaTranslucentRows()
                }
            }
        } else {
            List {
                Group {
                    Section {
                        board
                    } footer: {
                        status
                    }
                    controls
                }
                .rinaTranslucentRows()
            }
        }
    }

    /// The board and its status line outside any list, laid out to match the
    /// list cells beside and below it: the board spans a cell's width (the
    /// inset-grouped margin), the status line sits where a section footer's
    /// text would.
    private var pinnedPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            board
            status
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

/// The scroll offset of the Control Center under the preview, shared by every
/// tab in one window.
///
/// Each tab builds its own `BoardSplitPage`, so each has its own copy of the
/// panel's list. Without this, switching tabs lands on a copy scrolled
/// somewhere else and the left column visibly jumps; with it the panel reads
/// as one fixed column that the tabs only change the right side of.
@Observable
final class ControlCenterColumnScroll {
    /// Distance scrolled from the top of the content, insets excluded.
    var offset: CGFloat = 0
}

/// Keeps one copy of the Control Center list in step with the window's
/// `ControlCenterColumnScroll`: the copy on screen records the user's
/// scrolling, and a copy that comes on screen is moved to the stored offset
/// before its first frame.
///
/// Reaches the list's `UIScrollView` directly. SwiftUI's `ScrollPosition`
/// cannot do this on a `List`: it is applied before a newly shown tab's list
/// has laid out, and re-assigning the same offset later is not a change, so
/// the copy stays where it was. A no-op when no `ControlCenterColumnScroll` is
/// in the environment (unit-test hosts).
private struct SharedControlCenterScroll: ViewModifier {
    @Environment(ControlCenterColumnScroll.self) private var shared: ControlCenterColumnScroll?

    func body(content: Content) -> some View {
        if let shared {
            content.background(ScrollViewLink(shared: shared))
        } else {
            content
        }
    }
}

/// A zero-content view laid out exactly over the list, used to find the list's
/// scroll view and to learn when this tab's copy enters or leaves the window.
private struct ScrollViewLink: UIViewRepresentable {
    let shared: ControlCenterColumnScroll

    func makeUIView(context: Context) -> LinkView {
        let view = LinkView()
        view.isUserInteractionEnabled = false
        view.shared = shared
        return view
    }

    func updateUIView(_ view: LinkView, context: Context) {
        view.shared = shared
    }

    final class LinkView: UIView {
        var shared: ControlCenterColumnScroll?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            restore()
            // A tab shown for the first time has not laid its list out yet.
            DispatchQueue.main.async { [weak self] in self?.restore() }
        }

        private func restore() {
            guard window != nil, let shared, let scrollView = linkScrollView() else { return }
            let top = -scrollView.adjustedContentInset.top
            let bottom = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
            let target = min(max(top, top + shared.offset), max(top, bottom))
            guard abs(scrollView.contentOffset.y - target) > 0.5 else { return }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target),
                                        animated: false)
        }

        private func linkScrollView() -> UIScrollView? {
            if let scrollView, scrollView.window != nil { return scrollView }
            guard let found = findScrollView() else { return nil }
            scrollView = found
            // Only the user's own scrolling is recorded. Offsets UIKit sets —
            // a restore clamped on a shorter page, a relayout — would
            // otherwise overwrite the position every other tab should show.
            observation = found.observe(\.contentOffset) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil,
                          scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
                    else { return }
                    self.shared?.offset = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
                }
            }
            return found
        }

        /// The scroll view that occupies the same frame as this background:
        /// the list's own. Searched outward from here, nearest first.
        private func findScrollView() -> UIScrollView? {
            let frame = convert(bounds, to: nil)
            var ancestor = superview
            while let container = ancestor {
                if let match = Self.scrollView(in: container, matching: frame, excluding: self) {
                    return match
                }
                ancestor = container.superview
            }
            return nil
        }

        private static func scrollView(in view: UIView, matching frame: CGRect,
                                       excluding link: UIView) -> UIScrollView? {
            for subview in view.subviews where subview !== link {
                if let scrollView = subview as? UIScrollView,
                   sameFrame(scrollView.convert(scrollView.bounds, to: nil), frame) {
                    return scrollView
                }
                if subview is UIScrollView { continue }
                if let match = scrollView(in: subview, matching: frame, excluding: link) {
                    return match
                }
            }
            return nil
        }

        /// Height is left out: a list's scroll view can run on under the
        /// home indicator while its SwiftUI frame stops at the safe area.
        private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1
        }
    }
}
