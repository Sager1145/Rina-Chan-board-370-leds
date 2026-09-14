import SwiftUI

@Observable @MainActor
final class AppRouter {
    var selectedTab: AppTab = .initialSelection()

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
