import SwiftUI
import UIKit

/// Reports where an Apple Pencil hovers over the board, in the board's own
/// drawing space, and `nil` the moment it stops hovering there — lifted out of
/// range, moved off the board, or put down on the glass (a touch ends hover).
///
/// Pencil only (`allowedTouchTypes`): a trackpad or mouse pointer resting on
/// the board must not light anything, so pointer hover never reaches this.
///
/// Built on the same pattern as `BoardPreviewZoom`'s tracker — a
/// non-interactive marker view in the layout, with the recognizer on the
/// window — but placed the other way round: that tracker sits outside the zoom
/// transform on purpose, this marker sits *inside* it, so `location(in:)`
/// answers in board space at any magnification.
struct PencilHoverTracker: UIViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeUIView(context: Context) -> MarkerView {
        MarkerView()
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.onHover = onHover
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.detach()
    }

    final class MarkerView: UIView, UIGestureRecognizerDelegate {
        var onHover: ((CGPoint?) -> Void)?

        private var pendingDetach = false
        private var isReporting = false

        private lazy var hover: UIHoverGestureRecognizer = {
            let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            // A marker only: every touch must fall through to SwiftUI.
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else {
                // SwiftUI re-hosts platform views by moving them out of the
                // window and straight back in; only detach if it stays out.
                pendingDetach = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pendingDetach, self.window == nil else { return }
                    self.detach()
                }
                return
            }
            pendingDetach = false
            guard hover.view !== window else { return }
            detach()
            window.addGestureRecognizer(hover)
        }

        /// Called from `dismantleUIView`, i.e. in the middle of a SwiftUI
        /// update, so the final "no longer hovering" is delivered a turn
        /// later: it writes view state, and must still reach the board.
        func detach() {
            hover.view?.removeGestureRecognizer(hover)
            guard isReporting else { return }
            isReporting = false
            let onHover = onHover
            DispatchQueue.main.async { onHover?(nil) }
        }

        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let point = recognizer.location(in: self)
                report(accepts(point) ? point : nil)
            default:
                report(nil)
            }
        }

        /// Repeated `nil`s are dropped: the pencil wandering around the rest
        /// of the window must not keep re-announcing "not over the board".
        private func report(_ point: CGPoint?) {
            guard point != nil || isReporting else { return }
            isReporting = point != nil
            onHover?(point)
        }

        /// Over this board, and over nothing covering it: the same rectangle
        /// under a sheet, a popover or the floating tab bar belongs to
        /// something else.
        private func accepts(_ point: CGPoint) -> Bool {
            guard let window, bounds.contains(point),
                  let hit = window.hitTest(convert(point, to: window), with: nil),
                  let container = hoverContainer else { return false }
            return hit.isDescendant(of: container)
        }

        /// The list cell the board is hosted in; outside a list, the root view
        /// of the nearest view controller — never the whole window.
        private var hoverContainer: UIView? {
            var ancestor = superview
            var controllerRoot: UIView?
            while let view = ancestor {
                if view is UICollectionViewCell || view is UITableViewCell { return view }
                if controllerRoot == nil, view.next is UIViewController { controllerRoot = view }
                ancestor = view.superview
            }
            return controllerRoot
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
