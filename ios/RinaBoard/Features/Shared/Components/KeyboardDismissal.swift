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
        // Walk the responder chain rather than the superviews: it passes
        // through every superview and also through the view controllers that
        // own them, which the alert check below needs.
        var responder: UIResponder? = touch.view
        while let current = responder {
            // Includes secure fields and the inner views used for cursor and
            // selection interaction. Tapping another input should focus it.
            if current is UITextField || current is UITextView { return false }
            // An alert that carries a text field lays itself out above the
            // keyboard, so dismissing the keyboard from under it shifts its
            // buttons down mid-touch and the button the finger is on never
            // fires: 清空用户表情 needed two taps on 取消 (2026-09-17). The
            // alert ends its own editing session when it dismisses, so leave
            // its touches alone.
            if current is UIAlertController { return false }
            responder = current.next
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
