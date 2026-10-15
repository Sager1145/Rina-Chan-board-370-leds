import SwiftUI

enum ControlCenterCardStop: String, CaseIterable {
    case collapsed, half, full

    var title: LocalizedStringKey {
        switch self {
        case .collapsed: "已收起"
        case .half: "半屏"
        case .full: "全屏"
        }
    }

    func height(in availableHeight: CGFloat) -> CGFloat {
        let minimum = min(84, availableHeight)
        switch self {
        case .collapsed: return minimum
        case .half: return max(minimum, availableHeight / 2)
        case .full: return availableHeight
        }
    }

    static func nearest(to height: CGFloat, availableHeight: CGFloat) -> Self {
        allCases.min { abs($0.height(in: availableHeight) - height)
            < abs($1.height(in: availableHeight) - height) } ?? .collapsed
    }
}

/// Applied inside each TabView destination, where the native tab bar already
/// defines the bottom safe area. All destinations share the selected stop.
struct ControlCenterMenuCard: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.duoWorkspace) private var duoWorkspace
    @Environment(\.foldedDuo) private var foldedDuo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var stop: ControlCenterCardStop
    let namespace: Namespace.ID
    @State private var translation: CGFloat = 0

    private var snapAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)
    }

    private var isEnabled: Bool {
        ControlCenterPlacement.resolve(
            splitLayout: BoardPageColumns.isSplit(horizontalSizeClass, duoWorkspace: duoWorkspace),
            foldedDuo: foldedDuo) == .menuCard
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if #available(iOS 26.0, *), isEnabled {
                    Color.clear.frame(height: ControlCenterCardStop.collapsed.height(in: 84))
                }
            }
            .overlay(alignment: .bottom) {
                if #available(iOS 26.0, *), isEnabled {
                    GeometryReader { proxy in
                        card(availableHeight: proxy.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { stop = .collapsed; translation = 0 }
            }
            .onDisappear { translation = 0 }
    }

    @available(iOS 26.0, *)
    private func card(availableHeight: CGFloat) -> some View {
        let minimum = ControlCenterCardStop.collapsed.height(in: availableHeight)
        let height = min(availableHeight, max(minimum, stop.height(in: availableHeight) - translation))
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Button {
                    select(stop == .collapsed ? .half : .collapsed)
                } label: {
                    Capsule().fill(.secondary).frame(width: 36, height: 5)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("面板控制")
                .accessibilityValue(Text(stop.title))
                .accessibilityHint("展开控制中心")
                .accessibilityIdentifier("controlCenter.card.handle")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: select(stop == .collapsed ? .half : .full)
                    case .decrement: select(stop == .full ? .half : .collapsed)
                    @unknown default: break
                    }
                }

                HStack(spacing: 8) {
                    ForEach([FoldedBoardControl.status, .mode, .previous, .next, .color], id: \.self) { control in
                        BoardControlCenterAccessory(
                            transitionSourceID: "controlCenter", transitionNamespace: namespace,
                            toolbarControl: control, onExpand: { select(.half) })
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
            // A stationary coordinate space prevents the moving header from
            // cancelling its own displacement. Once a drag is recognized it
            // takes priority over taps, so releasing cannot also press a button.
            .highPriorityGesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { translation = value.translation.height }
                }
                .onEnded { value in
                    let projected = stop.height(in: availableHeight) - value.predictedEndTranslation.height
                    withAnimation(snapAnimation) {
                        stop = .nearest(to: projected, availableHeight: availableHeight)
                        translation = 0
                    }
                })

            if stop != .collapsed || translation < 0 {
                NavigationStack {
                    BoardControlCenterView(onDismiss: { select(.collapsed) }, usesAppBackground: true)
                }
                .environment(\.rinaBackdropIsShared, true)
                .frame(height: max(0, height - 84))
                .clipped()
            }
        }
        .frame(height: height, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controlCenter.card")
        .animation(snapAnimation, value: stop)
    }

    private func select(_ newStop: ControlCenterCardStop) {
        stop = newStop
    }
}
