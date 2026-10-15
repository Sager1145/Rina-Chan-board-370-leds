import SwiftUI

/// Page and sheet actions stay inside their menu instead of joining Duo's camera rail.
struct MenuToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement
    @ViewBuilder var content: () -> Content

    @ToolbarContentBuilder var body: some ToolbarContent {
        #if targetEnvironment(macCatalyst)
        ToolbarItem(placement: placement, content: content)
        #else
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: placement, content: content)
                .axisBehavior(.horizontalOnly)
        } else {
            ToolbarItem(placement: placement, content: content)
        }
        #endif
    }
}

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

/// Folded: mode, color, expand. Inner portrait: mode, previous, next, color.
/// The landscape rail keeps mode/previous/next so every native tab stays visible.
/// Other phones retain their existing navigation-bar visibility.
struct FoldedControlCenterToolbar: ViewModifier {
    @Environment(\.boardControlCenterLauncher) private var launcher
    @Environment(\.boardToolbarIsVertical) private var verticalBar
    var hidesNavigationBar = true

    private var controls: [FoldedBoardControl] {
        if launcher?.isFolded == true { return [.mode, .color, .status] }
        return verticalBar ? [.mode, .previous, .next] : [.mode, .previous, .next, .color]
    }

    func body(content: Content) -> some View {
        content
            .modifier(BoardToolbarTitleVisibility(isHidden: launcher != nil))
            .modifier(BoardToolbarCompressionPreference(enabled: launcher != nil))
            .toolbarTitleDisplayMode(.inline)
            .toolbar(launcher == nil && hidesNavigationBar ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if #available(iOS 27.1, *), let launcher {
                    // Let the native group adapt its spacing to the Duo bar;
                    // each child retains its own circular glass button.
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ForEach(controls, id: \.self) { control in
                            BoardControlCenterAccessory(transitionSourceID: "controlCenter",
                                                        transitionNamespace: launcher.namespace,
                                                        toolbarControl: control,
                                                        foldedPresentation: launcher.canExpand ? launcher.isPresented : nil,
                                                        onExpand: launcher.open)
                        }
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

private struct BoardToolbarCompressionPreference: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.1, *), enabled {
            content.toolbarVerticalCompressionBehavior(.prefersTabBar)
        } else {
            content
        }
    }
}
