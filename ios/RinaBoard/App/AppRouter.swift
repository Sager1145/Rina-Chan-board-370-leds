import SwiftUI

@Observable @MainActor
final class AppRouter {
    var selectedTab: AppTab = .initialSelection()

    /// One-shot launch gate (user requirement: "刚打开app同步时，完成同步再显示预览画面，不要
    /// 让预览画面闪一下"): the boot loader never waits for the board, and
    /// `autoReconnect` only starts after drafts restore, so every board
    /// preview would otherwise draw a local frame first — a default face, a
    /// restored draft, or the Text tab's stitched-draft/caption preview — and
    /// then visibly swap to the board's real frame once `BoardSyncCoordinator`
    /// finishes. While this is `true`, preview rows hold a blank frame
    /// instead. Armed once at launch (only when a board is known, so a
    /// fresh install with nothing to reconnect to never gates anything), and
    /// released the first time that first sync ends, fails, or times out —
    /// never re-armed later in the run.
    private(set) var launchPreviewPending = false
    private var launchGateUsed = false

    /// Arms the gate for at most `timeout` before releasing it unconditionally,
    /// so a board that never answers (out of range, powered off) cannot leave
    /// every preview blank for the rest of the session. No-op if the gate is
    /// already armed, or was already used and released earlier this launch.
    func armLaunchPreviewGate(timeout: Duration = .seconds(8)) {
        guard !launchGateUsed, !launchPreviewPending else { return }
        launchGateUsed = true
        launchPreviewPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.releaseLaunchPreviewGate()
        }
    }

    /// Idempotent: safe to call from every early-return path that should open
    /// the gate, and safe to call again once the timeout races a real release.
    func releaseLaunchPreviewGate() {
        launchPreviewPending = false
    }

    func showBoardMode(_ mode: BoardResumeMode) {
        switch mode {
        case .control: selectedTab = .control
        case .text: selectedTab = .text
        case .lipSync: selectedTab = .lipSync
        case .performance, .video:
            let page: PerformanceTabMode = mode == .video ? .video : .performance
            UserDefaults.standard.set(page.rawValue, forKey: PerformanceTabMode.storageKey)
            selectedTab = .presetLive
        }
    }
}
