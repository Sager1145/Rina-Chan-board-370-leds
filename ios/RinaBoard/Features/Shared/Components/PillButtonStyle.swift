import SwiftUI

extension Animation {
    /// The one timing for an icon or title swapping with its state.
    static let stateSwap: Animation = .snappy(duration: 0.2)
}

/// An SF Symbol that morphs into its replacement when `systemName` changes.
/// Carries its own animation, because most of the state behind these is set
/// by a model outside any `withAnimation`. Falls back to a cross-fade under
/// Reduce Motion, which the system's own `.symbolEffect(.replace)` ignores.
struct SwapSymbol: View {
    var systemName: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: systemName)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .animation(.stateSwap, value: systemName)
    }
}

/// `Label` whose icon morphs and whose title cross-fades when either changes.
struct SwapLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title).contentTransition(.opacity)
        } icon: {
            SwapSymbol(systemName: systemImage)
        }
        // Icon and title can each change on their own (e.g. a constant icon
        // with a changing title), so both are tracked.
        .animation(.stateSwap, value: systemImage)
        .animation(.stateSwap, value: title)
    }
}

extension View {
    /// Cross-fades a Text whose string changes with `value`.
    func swapText<V: Equatable>(_ value: V) -> some View {
        contentTransition(.opacity).animation(.stateSwap, value: value)
    }
}

/// The one pill button used across the app, drawn to match the command chips
/// on the Control tab (what `.bordered` + `.capsule` + `.small` rendered
/// there): footnote label, white text on the tint at low opacity, grey
/// when off or disabled.
///
/// A custom style rather than the system one, because the system style grows
/// on press and follows its label's height — a play icon swapping for a
/// ProgressView made a whole row jump. This one has a minimum height every
/// icon and one-line title fits inside, fills the height its row gives it,
/// and only dims while pressed; a long title still wraps rather than
/// truncating.
struct PillButtonStyle: ButtonStyle {
    /// Neutral grey fill, used for a toggle that is off.
    var isNeutral = false
    /// Told when a touch goes down on the pill and when it lifts, for a
    /// button that has to know what it showed when the press began.
    var onPressChanged: ((Bool) -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .footnote) private var minHeight: CGFloat = 31

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight, maxHeight: .infinity)
            .foregroundStyle(labelStyle)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged?(isPressed)
            }
            // A pill row stops growing at the largest standard text size
            // (see `PillButtonRow`); at the accessibility sizes a long press
            // shows the enlarged icon and title instead, as the tab bar does.
            .accessibilityShowsLargeContentViewer()
    }

    /// White label on a lit pill, grey on an off toggle, fainter grey when
    /// disabled; only the translucent fill carries the tint.
    private var labelStyle: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Color(.tertiaryLabel)) }
        return isNeutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    private var fill: AnyShapeStyle {
        isEnabled && !isNeutral
            ? AnyShapeStyle(.tint.opacity(0.18))
            : AnyShapeStyle(Color(.secondarySystemFill))
    }
}

/// Button-shaped toggle in the pill style: tinted when on, grey when off.
struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(PillButtonStyle(isNeutral: !configuration.isOn))
        .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}

/// Horizontal icon + title label used by every command control (§18), kept flat
/// so four chips share one row without clipping at larger Dynamic Type sizes.
struct CommandChip: View {
    static let minHeight: CGFloat = 22

    private let title: LocalizedStringKey
    private let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            SwapSymbol(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight)
        .contentShape(Capsule())
        .accessibilityLabel(Text(title))
        // Icon and title can each change on their own, so both are tracked.
        .animation(.stateSwap, value: systemImage)
        .animation(.stateSwap, value: title)
    }
}

/// The repeat symbol, struck through while looping is off. SF Symbols has no
/// `repeat.slash`, so the slash is drawn over it in the same direction as
/// `speaker.slash`.
struct RepeatSymbol: View {
    var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "repeat")
            .overlay {
                Capsule()
                    .frame(width: 1.5)
                    .padding(.vertical, -3)
                    // Under Reduce Motion the slash only fades; the collapse
                    // in height reads as movement.
                    .scaleEffect(y: reduceMotion || !isOn ? 1 : 0)
                    .opacity(isOn ? 0 : 1)
                    .rotationEffect(.degrees(-45))
            }
            .animation(.stateSwap, value: isOn)
    }
}

/// Puts a row of pill buttons in place of its list cell: the cell's grouped
/// background is cleared and the row has no insets, so the pills take the
/// cell's full height and reach its left and right edges.
///
/// The row follows Dynamic Type up to the largest standard size and no
/// further. Five icon pills at an accessibility size are wider than a phone
/// or a Slide Over window, and in a half-width iPad column a chip's title
/// shrank to "…"; past that size each pill offers the Large Content Viewer
/// instead (`PillButtonStyle`), the way the system tab bar does.
private struct PillButtonRow: ViewModifier {
    @Environment(\.defaultMinListRowHeight) private var rowHeight

    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity, minHeight: rowHeight)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

extension View {
    func pillButtonRow() -> some View {
        modifier(PillButtonRow())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}

extension ToggleStyle where Self == PillToggleStyle {
    static var pill: PillToggleStyle { PillToggleStyle() }
}
