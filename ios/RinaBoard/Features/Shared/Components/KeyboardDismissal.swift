import SwiftUI
import UIKit

/// Observe taps in this scene's window, including presented sheets, without
/// consuming the controls' own gestures or interrupting text selection.
struct KeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDismissalView {
        KeyboardDismissalView()
    }

    func updateUIView(_ uiView: KeyboardDismissalView, context: Context) {}

    static func dismantleUIView(_ uiView: KeyboardDismissalView, coordinator: ()) {
        uiView.detachGesture()
    }
}

final class KeyboardDismissalView: UIView, UIGestureRecognizerDelegate {
    private weak var observedWindow: UIWindow?
    private lazy var dismissalTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditingOutsideInput))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detachGesture()
        observedWindow = window
        window?.addGestureRecognizer(dismissalTap)
    }

    func detachGesture() {
        observedWindow?.removeGestureRecognizer(dismissalTap)
        observedWindow = nil
    }

    @objc private func endEditingOutsideInput() {
        observedWindow?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touchedView = touch.view
        while let view = touchedView {
            // Includes secure fields and the inner views used for cursor and
            // selection interaction. Tapping another input should focus it.
            if view is UITextField || view is UITextView { return false }
            touchedView = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
