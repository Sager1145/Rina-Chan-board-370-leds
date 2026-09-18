import SwiftUI

/// The top-level groups of the Settings tab. The raw value is the route: it
/// never changes with the language, so a restored or launch-argument route
/// means the same page in every locale.
enum SettingsCategory: String, CaseIterable, Codable, Hashable, Identifiable {
    /// iOS 17–25 single column only — see `ControlCenterPlacement.settingsLink`.
    case controlCenter
    case connection
    case board
    case application
    case debug
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .controlCenter: "面板控制中心"
        case .connection: "连接"
        case .board: "面板"
        case .application: "应用"
        case .debug: "调试"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .controlCenter: "slider.horizontal.below.rectangle"
        case .connection: "antenna.radiowaves.left.and.right"
        case .board: "rectangle.grid.3x2"
        case .application: "gearshape"
        case .debug: "ladybug"
        case .about: "info.circle"
        }
    }

    /// `-initialTab debug` / `-initialTab connect` land on that page, the
    /// automated-simulator-run affordance `AppTab(launchArgument:)` maps onto
    /// the Settings tab.
    init?(launchArgument raw: String?) {
        switch raw {
        case "debug": self = .debug
        case "connect": self = .connection
        default: return nil
        }
    }
}

/// How the Settings tab lays out its categories and the selected page.
enum SettingsLayoutMode: Equatable {
    /// One column: the category list, pushing each page on a stack.
    case compact
    /// Categories in a sidebar beside the selected page.
    case split
}

/// Picks the Settings layout from the width Settings actually has, never from
/// the device model or orientation, so an iPad window being resized, a folding
/// phone switching screens and a Mac window being dragged all go through the
/// same rule.
///
/// The two thresholds form a hysteresis band: a window dragged back and forth
/// across one edge does not flip between the layouts on every point. The band
/// deliberately contains no common full-screen width (744 iPad mini portrait,
/// 768, 810, 820, 834 …): inside it the layout depends on the previous one,
/// and a device that rests there would come back from a rotation in a
/// different layout than it started in.
enum SettingsLayoutPolicy {
    /// Widths for text at or below the default large size.
    static let enterSplitWidth: CGFloat = 800
    static let leaveSplitWidth: CGFloat = 770
    /// Accessibility text sizes need a wider page before a sidebar leaves the
    /// detail enough room to read.
    static let accessibilityEnterSplitWidth: CGFloat = 1024
    static let accessibilityLeaveSplitWidth: CGFloat = 960

    static func resolve(width: CGFloat,
                        horizontalSizeClass: UserInterfaceSizeClass?,
                        dynamicTypeSize: DynamicTypeSize,
                        previous: SettingsLayoutMode?) -> SettingsLayoutMode {
        // A compact width class collapses `NavigationSplitView` by itself;
        // asking for two columns there would fight the system.
        guard horizontalSizeClass == .regular, width > 0 else { return .compact }
        let large = dynamicTypeSize.isAccessibilitySize
        let enter = large ? accessibilityEnterSplitWidth : enterSplitWidth
        let leave = large ? accessibilityLeaveSplitWidth : leaveSplitWidth
        switch previous {
        case .split: return width < leave ? .compact : .split
        case .compact, nil: return width >= enter ? .split : .compact
        }
    }
}
