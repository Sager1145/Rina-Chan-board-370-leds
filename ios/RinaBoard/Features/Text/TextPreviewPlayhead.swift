import Foundation
import RinaCore

/// Mirrors the per-tick fields of `TextViewModel`'s `ScrollPreviewController`
/// (perf PR-9): a small `@Observable` on its own, separate from
/// `TextViewModel`, so a SwiftUI body that only needs the running preview
/// index/rate/lock state can depend on *this* object instead of the model.
///
/// `ScrollPreviewController` itself stays a plain, `@ObservationIgnored`
/// value type on `TextViewModel` — untouched semantics, including its
/// adaptive `nextDelayMs` slewing — so nothing about the PLL's behaviour or
/// its unit tests changes. `TextViewModel` copies the fields views actually
/// read into this object after every mutation, and only assigns a field when
/// its value actually changed, so a tick that only advances `displayIndex`
/// does not also invalidate anything observing `measuredFps` or `lockState`.
@Observable
@MainActor
final class TextPreviewPlayhead {
    private(set) var displayIndex: Int = 0
    /// Raw PLL measurement; `TextViewModel.measuredFps` applies the
    /// "nothing playing" nil-gate on top of this.
    private(set) var measuredFps: Double = 0
    private(set) var lockState: ScrollPreviewController.LockState = .free

    func update(displayIndex: Int, measuredFps: Double, lockState: ScrollPreviewController.LockState) {
        if self.displayIndex != displayIndex { self.displayIndex = displayIndex }
        if self.measuredFps != measuredFps { self.measuredFps = measuredFps }
        if self.lockState != lockState { self.lockState = lockState }
    }
}
