import SwiftUI
import RinaCore

/// Collapsed Control Center (design guide §6.1).
///
/// On iOS 26 this is the content of the system's tab-bar bottom accessory —
/// Apple's own persistent-bottom-surface presentation (the same one Music uses
/// for its mini player) — so there is no custom drag interaction anywhere in
/// the expansion path.
///
/// It carries the glanceable board state *and*, while the board is connected,
/// the controls that are worth reaching without expanding anything:
/// previous/next face, the auto/manual switch, the board colour (§9, §10) and
/// sending the editor's draft frame.
/// Everything else still lives behind the expanded sheet.
///
/// Only the summary region expands the sheet. The controls are real controls,
/// so the accessory is deliberately *not* wrapped in one big button — nesting
/// them inside a parent button would make every step or colour tap also open
/// the sheet.
@available(iOS 26.0, *)
struct BoardControlCenterAccessory: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardControlCenterModel.self) private var model
    @Environment(ControlViewModel.self) private var editor
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage(AppSettingsKey.hapticsEnabled) private var hapticsEnabled = true

    /// The summary region is registered under this id so the expanded sheet
    /// can zoom out of it and back into it (see `ControlCenterPresenter`).
    var transitionSourceID: String
    var transitionNamespace: Namespace.ID

    /// Opens the expanded Control Center sheet.
    var onExpand: () -> Void

    /// Haptics are tied to the user's taps, not to model state: the accessory
    /// is mounted for the whole app lifetime, so a firmware echo clearing an
    /// override — or someone pressing B3 on the board itself — would otherwise
    /// buzz the phone with no one touching it.
    @State private var stepTicks = 0
    @State private var modeTicks = 0
    /// The accessory's own height, i.e. twice the capsule's corner radius.
    @State private var barHeight: CGFloat = 0

    private var isConnected: Bool { connection.connectionState == .connected }
    private var isAuto: Bool { model.isAutoMode(status: connection.status) }

    var body: some View {
        HStack(spacing: 0) {
            summary
            // Always present, dimmed while there is no board: the bar keeps a
            // stable shape, the controls stay discoverable, and nothing is
            // torn out of the hierarchy mid-interaction when a link drops.
            //
            // Every control occupies the same `Self.slot`-wide cell, so the row
            // is one even rhythm laid out from the send button leftwards — the
            // send button is the anchor, and it is the one pinned to the bar's
            // rounded end.
            HStack(spacing: 0) {
                stepButton(direction: -1, symbol: "chevron.left", label: "上一个表情")
                stepButton(direction: 1, symbol: "chevron.right", label: "下一个表情")
                modeToggle
                colorControl
                sendButton
            }
            // The controls keep their intrinsic width; the summary line is what
            // truncates when the bar runs out of room.
            .layoutPriority(1)
            .disabled(!isConnected)
            // The disc, the swatch and the send glyph are custom-tinted, so
            // they don't pick up the system's disabled treatment on their own.
            .grayscale(isConnected ? 0 : 1)
        }
        .padding(.leading, 12)
        // The send button's ring has to be concentric with the capsule's
        // trailing end, so its centre sits exactly one bar-radius in from the
        // edge. The bar's radius is half its own height, measured below rather
        // than hard-coded, since the height moves with Dynamic Type and with
        // the `.inline` placement.
        .padding(.trailing, max(0, barHeight / 2 - Self.slot / 2))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: BarHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
        .sensoryFeedback(.selection, trigger: stepTicks) { _, _ in hapticsEnabled }
        .sensoryFeedback(.selection, trigger: modeTicks) { _, _ in hapticsEnabled }
    }

    /// One control cell. Every button on the row is exactly this wide and this
    /// tall, which is both the even spacing and the HIG minimum hit target —
    /// the trailing padding above measures the bar's own radius against it, so
    /// the row's rhythm and the send ring's centring can never drift apart.
    private static let slot: CGFloat = AppLayout.minimumTapTarget

    // MARK: Summary (the only region that expands the sheet)

    private var summary: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.medium)
                VStack(alignment: .leading, spacing: 1) {
                    Text("面板控制")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    // Dropped where there is no room for a second line: the
                    // `.inline` placement inside a minimised tab bar, and at
                    // accessibility sizes. VoiceOver still reads it as the
                    // element's value either way.
                    if placement != .inline && !dynamicTypeSize.isAccessibilitySize {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            // A floor, so a narrower `.inline` placement can never squeeze
            // the only way into the sheet down to nothing.
            .frame(minWidth: AppLayout.minimumTapTarget, maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The zoom starts from (and collapses back into) this region only —
        // not the whole pill, whose trailing controls stay put.
        .matchedTransitionSource(id: transitionSourceID, in: transitionNamespace) { source in
            // Only rounded rectangles are accepted here; this radius reads as
            // the accessory pill's own curve at the summary's height.
            source.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("面板控制")
        .accessibilityValue(Text(subtitle))
        .accessibilityHint("打开面板控制中心")
    }

    // MARK: Inline controls

    private func stepButton(direction: Int, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            stepTicks += 1
            Task { await model.step(face: direction, connection: connection) }
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: Self.slot, height: Self.slot)
                .background(controlRing())
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    /// Auto/manual as a chrome-free toggle, the way Music draws shuffle and
    /// repeat: the state is a solid, translucent tinted disc behind a filled
    /// glyph when on, and a hollow ring behind an outline glyph when off.
    /// Shape, fill and glyph all move together, so the state never rests on
    /// colour alone (§41), and the state line spells it out as well.
    private var modeToggle: some View {
        Toggle(isOn: Binding(
            get: { isAuto },
            set: { _ in
                modeTicks += 1
                Task { await model.toggleAutoMode(connection: connection) }
            }
        )) {
            Image(systemName: isAuto ? "arrow.triangle.2.circlepath" : "hand.tap")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isAuto ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: Self.slot, height: Self.slot)
                .background(controlRing(filled: isAuto))
                .contentShape(.rect)
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: isAuto)
        .accessibilityLabel("自动模式")
        .accessibilityValue(Text(isAuto ? "自动" : "手动"))
    }

    /// The chrome every button on the bar wears: a 32pt ring drawn inside the
    /// 44pt hit target, so the row keeps one rhythm and nothing shifts when a
    /// state flips. Hollow by default; the mode toggle fills it when auto is
    /// on, which is the only state any ring here carries.
    private func controlRing(filled: Bool = false) -> some View {
        Circle()
            .fill(filled ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
            // `Color.primary`, not `.primary`: inside the send button's tinted
            // foreground style the hierarchical form would resolve to the tint
            // and give that one ring a different colour from the rest.
            .overlay(Circle().strokeBorder(Color.primary.opacity(filled ? 0 : 0.22)))
            .frame(width: 32, height: 32)
    }

    /// The swatch doubles as the colour control: it is the system
    /// `ColorPicker`, so tapping it opens Apple's own picker.
    private var colorControl: some View {
        ColorPicker(selection: Binding(
            get: { model.draftColor },
            set: { newColor in
                Task { await model.setColor(hex: newColor.hexString, connection: connection) }
            }
        ), supportsOpacity: false) {
            Text("面板颜色")
        }
        .labelsHidden()
        // Same cell as the buttons, so the swatch sits on the row's rhythm.
        .frame(width: Self.slot, height: Self.slot)
        // `ColorPicker` keeps its swatch at full strength when disabled; the
        // cluster's grayscale handles the hue, this handles the weight.
        .opacity(isConnected ? 1 : 0.4)
        .accessibilityLabel("面板颜色")
    }

    /// The editor's "send draft to the board" action, parked at the trailing
    /// edge of the collapsed bar so it stays reachable from every tab. Tinted
    /// rather than boxed — nothing on this bar carries a background — because
    /// it is the only control that writes a whole frame.
    private var sendButton: some View {
        Button {
            Task { await editor.send(connection: connection) }
        } label: {
            Group {
                if editor.isSending {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(width: Self.slot, height: Self.slot)
            .background(controlRing())
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(editor.isSending)
        .accessibilityLabel("发送到面板")
    }

    // MARK: Derived state

    /// "已连接 · 亮度 62% · 自动" — the compact secondary state line.
    private var subtitle: String {
        var parts: [String] = [stateText]
        if connection.connectionState == .connected {
            parts.append(String(format: NSLocalizedString("亮度 %lld%%", comment: "brightness percent"),
                                BoardControlCenterModel.percent(forRaw: model.draftBrightness)))
            parts.append(isAuto
                         ? NSLocalizedString("自动", comment: "auto mode")
                         : NSLocalizedString("手动", comment: "manual mode"))
        }
        return parts.joined(separator: " · ")
    }

    private var stateText: String {
        switch connection.connectionState {
        case .connected: return NSLocalizedString("已连接", comment: "connection state connected")
        case .connecting: return NSLocalizedString("连接中", comment: "connection state connecting")
        case .reconnecting: return NSLocalizedString("重连中", comment: "connection state reconnecting")
        case .disconnected: return NSLocalizedString("未连接", comment: "connection state disconnected")
        case .failed: return NSLocalizedString("连接失败", comment: "connection state failed")
        }
    }

    private var symbol: String {
        switch connection.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "circle.slash"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch connection.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}

/// Carries the accessory's measured height up to the view that needs the
/// capsule's corner radius.
@available(iOS 26.0, *)
private struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
