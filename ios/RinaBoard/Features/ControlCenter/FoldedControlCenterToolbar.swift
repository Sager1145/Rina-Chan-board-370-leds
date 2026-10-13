import SwiftUI

enum FoldedBoardControl: CaseIterable {
    case mode, previous, next, color, status
}

struct BoardControlCenterLauncher: Sendable {
    let namespace: Namespace.ID
    let canExpand: Bool
    let isFolded: Bool
    let isPresented: Binding<Bool>
    let open: @MainActor @Sendable () -> Void
}
private struct BoardToolbarVerticalKey: EnvironmentKey {
    static let defaultValue = false
}
private struct ControlCenterLauncherKey: EnvironmentKey {
    static let defaultValue: BoardControlCenterLauncher? = nil
}
extension EnvironmentValues {
    var boardToolbarIsVertical: Bool {
        get { self[BoardToolbarVerticalKey.self] }
        set { self[BoardToolbarVerticalKey.self] = newValue }
    }
    var boardControlCenterLauncher: BoardControlCenterLauncher? {
        get { self[ControlCenterLauncherKey.self] }
        set { self[ControlCenterLauncherKey.self] = newValue }
    }
}

/// Folded: mode, color, expand. Expanded: mode, previous, next, color.
/// Other phones retain their existing navigation-bar visibility.
struct FoldedControlCenterToolbar: ViewModifier {
    @Environment(\.boardControlCenterLauncher) private var launcher
    var hidesNavigationBar = true

    func body(content: Content) -> some View {
        content
            .modifier(BoardToolbarTitleVisibility(isHidden: launcher != nil))
            .toolbarTitleDisplayMode(.inline)
            .toolbar(launcher == nil && hidesNavigationBar ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if #available(iOS 27.1, *), let launcher {
                    ForEach(launcher.isFolded ? [FoldedBoardControl.mode, .color, .status] : [.mode, .previous, .next, .color], id: \.self) { control in
                        ToolbarItem(placement: .topBarTrailing) {
                            BoardControlCenterAccessory(transitionSourceID: "controlCenter",
                                                        transitionNamespace: launcher.namespace,
                                                        toolbarControl: control,
                                                        foldedPresentation: launcher.canExpand ? launcher.isPresented : nil,
                                                        onExpand: launcher.open)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        #if !targetEnvironment(macCatalyst)
                        .axisBehavior(.verticalPreferred)
                        #endif
                        .visibilityPriority(.high)
                    }
                }
            }
    }
}

private struct BoardToolbarTitleVisibility: ViewModifier {
    let isHidden: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), isHidden {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
