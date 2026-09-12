import SwiftUI

@Observable @MainActor
final class AppRouter {
    var selectedTab: AppTab = .initialSelection()
}
