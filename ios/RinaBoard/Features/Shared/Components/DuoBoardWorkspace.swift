import SwiftUI

private struct DuoWorkspaceKey: EnvironmentKey {
    static let defaultValue = false
}
private struct FoldedDuoKey: EnvironmentKey {
    static let defaultValue = false
}
private struct PreviewHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 420
}
extension EnvironmentValues {
    var duoWorkspace: Bool {
        get { self[DuoWorkspaceKey.self] }
        set { self[DuoWorkspaceKey.self] = newValue }
    }
    var foldedDuo: Bool {
        get { self[FoldedDuoKey.self] }
        set { self[FoldedDuoKey.self] = newValue }
    }
    var boardPreviewMaximumHeight: CGFloat {
        get { self[PreviewHeightKey.self] }
        set { self[PreviewHeightKey.self] = newValue }
    }
}

/// Observe discrete layout facts, not the continuously changing hinge angle.
/// A division on the inner display remains queryable when the screen is flat.
struct DuoWorkspaceAdapter: ViewModifier {
    @State private var folded = false
    @State private var lastInnerDisplay = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
                let hasDivision = regions.contains {
                    DuoWorkspaceFrames.validDivision($0.frame, in: proxy.size) != nil
                }
                // Reserved-region delivery can briefly lag rotation. The
                // inner phone display remains wide in both orientations.
                let widePhone = UIDevice.current.userInterfaceIdiom == .phone
                    && min(proxy.size.width, proxy.size.height) >= 600
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                let displaySize = (scenes.first { $0.activationState == .foregroundActive }
                    ?? scenes.first { $0.activationState == .foregroundInactive })?.screen.bounds.size
                let wideDisplayPhone = UIDevice.current.userInterfaceIdiom == .phone
                    && displaySize.map { min($0.width, $0.height) >= 600 } == true
                let inner = DuoWorkspaceDetection.isInnerDisplay(
                    viewportSize: proxy.size, displaySize: displaySize,
                    isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                    folded: folded, hasDivision: hasDivision, previousInner: lastInnerDisplay)
                content
                    .environment(\.boardToolbarIsVertical,
                                 proxy.safeAreaInsets.leading > 0 || proxy.safeAreaInsets.trailing > 0)
                    .environment(\.duoWorkspace, inner)
                    .environment(\.foldedDuo, folded && !inner)
                    .onChange(of: folded || !inner, initial: true) { _, _ in
                        RinaPhoneOrientationPolicy.updateConnectedScenes(innerDisplay: inner, folded: folded)
                    }
                    .onChange(of: hasDivision || widePhone || wideDisplayPhone, initial: true) { _, detected in
                        if detected && (!folded || widePhone) { lastInnerDisplay = true }
                    }
            }
                .onHingeChange { _, context in
                    folded = context.hinge?.status == .closed
                    if folded { lastInnerDisplay = false }
                }
        } else {
            content
        }
        #endif
    }
}

enum DuoWorkspaceDetection {
    static func isInnerDisplay(viewportSize: CGSize, displaySize: CGSize?, isPhone: Bool,
                               folded: Bool, hasDivision: Bool, previousInner: Bool) -> Bool {
        // Hinge delivery can precede the scene's resize/rotation. A closed
        // phone must stop using the inner layout even while the geometry
        // still describes the inner screen.
        guard !folded else { return false }
        let wideViewport = isPhone && min(viewportSize.width, viewportSize.height) >= 600
        let wideDisplay = isPhone && displaySize.map { min($0.width, $0.height) >= 600 } == true
        // The native bar temporarily reduces viewport height while rotating.
        // Display bounds still identify the inner screen when this view remounts.
        // A confirmed closed hinge excludes a stale inner display during handoff.
        return wideViewport || wideDisplay || hasDivision || previousInner
    }
}

/// Three stable siblings keep the preview and the two lists alive as their
/// grouping changes. All rectangles are in the page's safe content space.
struct DuoWorkspaceFrames {
    var preview: CGRect
    var controlCenter: CGRect
    var tabControls: CGRect

    static func resolve(size: CGSize, division: CGRect?, stackLowerPanels: Bool) -> Self {
        let division = division.flatMap { validDivision($0, in: size) }
        if let division, division.width > division.height {
            let topHeight = max(0, min(size.height, division.minY))
            let bottomY = min(size.height, division.maxY)
            let bottomHeight = max(0, size.height - bottomY)
            // With the software keyboard up, the lower region can disappear.
            // Keep editing and board controls reachable in the unobstructed
            // upper region rather than giving the focused list zero height.
            if bottomHeight < 160 {
                return columns(size: CGSize(width: size.width, height: topHeight), division: nil)
            }
            return Self(
                preview: CGRect(x: 0, y: 0, width: size.width, height: topHeight),
                controlCenter: CGRect(x: 0, y: bottomY,
                                      width: stackLowerPanels ? size.width : size.width / 2,
                                      height: stackLowerPanels ? bottomHeight / 2 : bottomHeight),
                tabControls: CGRect(x: stackLowerPanels ? 0 : size.width / 2,
                                    y: bottomY + (stackLowerPanels ? bottomHeight / 2 : 0),
                                    width: stackLowerPanels ? size.width : size.width / 2,
                                    height: stackLowerPanels ? bottomHeight / 2 : bottomHeight)
            )
        }
        return columns(size: size, division: division)
    }

    /// A previous orientation's reserved band must not lay out the new page.
    static func validDivision(_ frame: CGRect, in size: CGSize) -> CGRect? {
        guard frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        if frame.width > frame.height {
            guard frame.width >= size.width * 0.9, frame.width <= size.width * 1.1,
                  frame.minY >= 0, frame.minY < size.height else { return nil }
        } else {
            guard frame.height >= size.height * 0.9, frame.height <= size.height * 1.1,
                  frame.minX >= 0, frame.minX < size.width else { return nil }
        }
        return frame
    }

    private static func columns(size: CGSize, division: CGRect?) -> Self {
        let leftWidth = max(0, min(size.width, division?.minX ?? size.width / 2))
        let rightX = max(leftWidth, min(size.width, division?.maxX ?? size.width / 2))
        // An active hinge divides the available regions, which can differ
        // because the native sidebar occupies one edge. Fill each region;
        // the flat display still uses equal halves.
        let rightWidth = max(0, size.width - rightX)
        let previewHeight = min(360, size.height * 0.48)
        return Self(
            preview: CGRect(x: 0, y: 0, width: leftWidth, height: previewHeight),
            controlCenter: CGRect(x: 0, y: previewHeight, width: leftWidth,
                                  height: size.height - previewHeight),
            tabControls: CGRect(x: rightX, y: 0, width: rightWidth, height: size.height)
        )
    }
}

struct DuoWorkspacePlacement: Layout {
    let frames: DuoWorkspaceFrames
    let size: CGSize
    let previewAspectRatio: CGFloat
    let previewFooterHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var placement = frames
        if placement.tabControls.minY == 0 {
            // Reserve the same width-fitting board slot for every tab.
            // Measuring each page's content moved the shared panel whenever
            // a single-board preview was replaced by a shorter group preview.
            let naturalHeight = min(max(0, placement.preview.width - 24) / previewAspectRatio, 420)
                + previewFooterHeight
            let availableHeight = placement.controlCenter.maxY
            let previewHeight = min(naturalHeight, max(0, availableHeight - 44))
            placement.preview.size.height = previewHeight
            placement.controlCenter.origin.y = previewHeight
            placement.controlCenter.size.height = availableHeight - previewHeight
        }
        for (subview, frame) in zip(subviews, [placement.preview, placement.controlCenter, placement.tabControls]) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Stable Settings siblings, with active folds excluded from both panes.
struct SettingsColumnPlacement: Layout {
    let size: CGSize
    let division: CGRect?

    private var panes: [CGRect] {
        let frames = DuoWorkspaceFrames.resolve(size: size, division: division, stackLowerPanels: false)
        if frames.tabControls.minY > 0 {
            return [frames.preview,
                    CGRect(x: 0, y: frames.tabControls.minY, width: size.width,
                           height: frames.tabControls.height)]
        }
        return [CGRect(x: frames.preview.minX, y: 0, width: frames.preview.width, height: size.height),
                frames.tabControls]
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, panes) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
