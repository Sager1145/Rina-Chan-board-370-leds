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
/// previous/next face, the auto/manual switch and the board colour (§9, §10).
/// Sending the editor's draft lives on the Control tab; everything else still
/// lives behind the expanded sheet.
///
/// Only the summary region expands the sheet. The controls are real controls,
/// so the accessory is deliberately *not* wrapped in one big button — nesting
/// them inside a parent button would make every step or colour tap also open
/// the sheet.
@available(iOS 26.0, *)
struct BoardControlCenterAccessory: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardControlCenterModel.self) private var model
    @Environment(BoardGroupStore.self) private var groupStore
    @Environment(BoardGroupCoordinator.self) private var groupCoordinator
    @Environment(GroupControlFanOut.self) private var fanOut
    @Environment(GroupAutoCycler.self) private var groupAutoCycler
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Mirrors the Control Center's own "控制对象" choice
    /// (BOARD_GROUP_SPEC.md §3): empty string = `.single`.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""

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
    /// While a group is targeted this reads `GroupAutoCycler.isRunning`
    /// instead of the primary's own firmware `renderer.mode`, which never
    /// leaves `manual` while the synced cycle runs (item 3, BOARD_GROUP_SPEC
    /// .md §3 addendum).
    private var isAuto: Bool {
        groupControlSynced ? groupAutoCycler.isRunning : model.isAutoMode(status: connection.status)
    }

    /// The targeted group, or `nil` when the control target is `.single`.
    private var targetedGroup: BoardGroup? {
        guard case .group(let id) = ControlTarget.resolved(storedGroupIDString: controlTargetGroupIDStorage, in: groupStore)
        else { return nil }
        return groupStore.groups.first { $0.id == id }
    }

    /// True only while a group is targeted AND the fan-out actually has a
    /// primary attached — see `BoardControlCenterView.groupControlSynced`
    /// (H1); the accessory's compact prev/next/mode controls fall back to
    /// the ordinary single-board path the same way when this is `false`.
    private var groupControlSynced: Bool {
        targetedGroup != nil && fanOut.primaryID != nil
    }

    /// The capsule's own corner radius, i.e. half the measured bar height.
    /// Falls back to the slot's radius for the first frame, before the
    /// preference has reported a height.
    private var barRadius: CGFloat { barHeight > 0 ? barHeight / 2 : Self.slot / 2 }

    /// Whether there is room for the second line: not in the `.inline`
    /// placement inside a minimised tab bar, and not at accessibility sizes.
    private var showsSubtitle: Bool {
        placement != .inline && !dynamicTypeSize.isAccessibilitySize
    }

    /// The subtitle's cross-fade when the bar loses the room for a second
    /// line. Reduce Motion keeps it — a cross-fade is the preferred stand-in
    /// for a hard swap, not something to strip — just shorter and flatter.
    ///
    /// Deliberately *not* keyed to `barHeight`: the bar's own resize is
    /// already smooth, because `GeometryReader` reports the interpolated
    /// height every frame while the system animates the capsule, so the
    /// insets below track it as it moves. Animating on the measurement would
    /// restart a curve on every one of those frames and leave the insets
    /// chasing the capsule long after it had settled.
    private var subtitleAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)
    }

    var body: some View {
        HStack(spacing: 0) {
            summary
            // Always present, dimmed while there is no board: the bar keeps a
            // stable shape, the controls stay discoverable, and nothing is
            // torn out of the hierarchy mid-interaction when a link drops.
            //
            // Every control occupies the same `Self.slot`-wide cell, so the row
            // is one even rhythm laid out from the colour swatch leftwards — the
            // swatch is the anchor, and it is the one pinned to the bar's
            // rounded end.
            HStack(spacing: 0) {
                stepButton(direction: -1, symbol: "chevron.left", label: "上一个表情")
                stepButton(direction: 1, symbol: "chevron.right", label: "下一个表情")
                modeToggle
                colorControl
            }
            // The controls keep their intrinsic width; the summary line is what
            // truncates when the bar runs out of room.
            .layoutPriority(1)
            .disabled(!isConnected)
            // The disc and the swatch are custom-tinted, so they don't pick up
            // the system's disabled treatment on their own.
            .grayscale(isConnected ? 0 : 1)
        }
        // Mirrors the trailing inset: the summary's badge is centred in a
        // slot-sized cell of its own, so it sits on the capsule's leading curve
        // exactly as the swatch does on the trailing one.
        .padding(.leading, max(0, barHeight / 2 - Self.slot / 2) + Self.edgeInset)
        // The colour swatch's ring centres one bar-radius in from the edge, plus
        // `edgeInset` so the ring clears the capsule's glass border. The bar's
        // radius is half its own height, measured below rather than hard-coded,
        // since the height moves with Dynamic Type and with the `.inline`
        // placement.
        .padding(.trailing, max(0, barHeight / 2 - Self.slot / 2) + Self.edgeInset)
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
    /// the row's rhythm and the trailing ring's centring can never drift apart.
    private static let slot: CGFloat = AppLayout.minimumTapTarget

    /// The visible ring every control wears, and the battery ring's diameter.
    private static let ringDiameter: CGFloat = 32

    /// Extra inset past the concentric position at both ends, so the outermost
    /// rings don't crowd the capsule's border.
    private static let edgeInset: CGFloat = 4

    // MARK: Summary (the only region that expands the sheet)

    private var summary: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                statusBadge
                VStack(alignment: .leading, spacing: 1) {
                    Text(targetedGroup.map { "多板组 · \($0.name)" } ?? connection.deviceName ?? "面板控制")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    // Dropped where there is no room for a second line: the
                    // `.inline` placement inside a minimised tab bar, and at
                    // accessibility sizes. VoiceOver still reads it as the
                    // element's value either way.
                    if showsSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .animation(subtitleAnimation, value: showsSubtitle)
                Spacer(minLength: 0)
            }
            // The zoom source's clip shape below clips this region at rest too.
            // Giving the region a full slot's height and the badge half a
            // slot's worth of inset makes that clip concentric with the badge
            // ring, instead of a squeezed curve shaving the ring's leading edge.
            .padding(.leading, (Self.slot - Self.ringDiameter) / 2)
            // A floor, so a narrower `.inline` placement can never squeeze
            // the only way into the sheet down to nothing.
            .frame(minWidth: AppLayout.minimumTapTarget, maxWidth: .infinity, minHeight: Self.slot, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The zoom starts from (and collapses back into) this region only —
        // not the whole pill, whose trailing controls stay put.
        .matchedTransitionSource(id: transitionSourceID, in: transitionNamespace) { source in
            // Only rounded rectangles are accepted here. The radius has to be
            // the capsule's own — half the *measured* bar height, not half a
            // slot — or the sheet finishes collapsing into a corner tighter
            // than the bar it is disappearing into.
            source.clipShape(RoundedRectangle(cornerRadius: barRadius, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(accessibilitySummary))
        .accessibilityHint("打开面板控制中心")
    }

    // MARK: Inline controls

    private func stepButton(direction: Int, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            stepTicks += 1
            Task { await stepFace(direction: direction) }
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: Self.slot, height: Self.slot)
                .background(controlRing())
                .contentShape(.rect)
        }
        .buttonStyle(AccessoryControlStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    /// Auto/manual as a chrome-free toggle, the way Music draws shuffle and
    /// repeat: an "A" on a solid, translucent tinted disc when auto is on, and
    /// an "M" on a hollow ring when it is manual. The letter and the disc's
    /// fill both change, so the state is carried by glyph and shape as well as
    /// colour (§41), and the accessory's state line spells it out too.
    ///
    /// Drawn letters rather than the `a`/`m` SF Symbols, which are lowercase; the
    /// rounded face and the text style keep it weight-matched to the chevrons
    /// beside it and scaling with Dynamic Type the same way they do.
    private var modeToggle: some View {
        Toggle(isOn: Binding(
            get: { isAuto },
            set: { _ in
                modeTicks += 1
                Task { await toggleAutoMode() }
            }
        )) {
            Text(isAuto ? "A" : "M")
                .contentTransition(.opacity)
                .font(.system(.subheadline, design: .rounded).weight(isAuto ? .bold : .semibold))
                .foregroundStyle(isAuto ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: Self.slot, height: Self.slot)
                .background(controlRing(filled: isAuto))
                .contentShape(.rect)
        }
        .toggleStyle(.button)
        .buttonStyle(AccessoryControlStyle())
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
            // `Color.primary`, not `.primary`: inside a tinted foreground style
            // the hierarchical form would resolve to the tint and give that
            // ring a different colour from the rest.
            .overlay(Circle().strokeBorder(Color.primary.opacity(filled ? 0 : 0.22)))
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
    }

    // MARK: Status badge

    /// Leading badge. Once connected with a battery reading it is a battery
    /// ring the size of the trailing controls' rings: the outer arc is the
    /// charge level over a gray track, and the filled centre carries the
    /// percentage in white. Otherwise it is the connection-state symbol. The
    /// cell is the ring's size in every state, so the title never shifts when
    /// the badge changes.
    ///
    /// While a group is targeted it is one ring per member instead, in slot
    /// order (user requirement: every board shows its own battery), shrunk as
    /// the group grows so the title keeps its room. A member that is offline
    /// or hasn't reported yet gets an empty gray ring.
    @ViewBuilder
    private var statusBadge: some View {
        if let targetedGroup {
            let diameter = Self.groupRingDiameter(memberCount: targetedGroup.members.count)
            HStack(spacing: 3) {
                ForEach(targetedGroup.members, id: \.physicalBoardID) { member in
                    BatteryRing(reading: memberBattery(member))
                        .frame(width: diameter, height: diameter)
                }
            }
            .frame(height: Self.ringDiameter)
            .accessibilityHidden(true)
        } else {
            Group {
                if let battery = connection.batteryReading {
                    BatteryRing(reading: battery)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .imageScale(.medium)
                }
            }
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            .accessibilityHidden(true)
        }
    }

    /// Full size for one or two boards, smaller for bigger groups (up to
    /// `BoardGroup.maxMembers`, 5) so five rings still leave the title room.
    private static func groupRingDiameter(memberCount: Int) -> CGFloat {
        switch memberCount {
        case ...2: return ringDiameter
        case 3: return 28
        default: return 24
        }
    }

    /// One member's battery, or `nil` while it's offline or has no report.
    private func memberBattery(_ member: BoardGroup.Member) -> BatteryReading? {
        groupCoordinator.session(for: member)?.connection.batteryReading
    }

    /// Routes the mode toggle to the synced group cycler while a group is
    /// targeted, instead of sending `set_mode auto` to the primary.
    private func toggleAutoMode() async {
        if groupControlSynced {
            if groupAutoCycler.isRunning { groupAutoCycler.stop() } else { _ = groupAutoCycler.start() }
        } else {
            await model.toggleAutoMode(connection: connection)
        }
    }

    /// Routes prev/next to the group cycler's own index while a group is
    /// targeted and synced, so every member receives the identical resulting
    /// frame. Falls back to the ordinary single-board path otherwise (H1).
    private func stepFace(direction: Int) async {
        if groupControlSynced {
            await groupAutoCycler.step(direction: direction)
        } else {
            await model.step(face: direction, connection: connection)
        }
    }

    /// The board colour as a solid dot inside the row's ring. Tapping it opens
    /// a menu of the preset groups (配色组), each a submenu of its colours; a
    /// submenu starts with the team's own colour, followed by its members and
    /// subunits. Free-form colours stay in the expanded sheet.
    private var colorControl: some View {
        Menu {
            if let presets = model.colorPresets {
                ForEach(presets.parents) { parent in
                    let children = presets.children(of: parent)
                    if children.isEmpty {
                        colorMenuItem(name: ColorPresets.displayName(parent.name), hex: parent.color)
                    } else {
                        Menu {
                            colorMenuItem(name: ColorPresets.displayName(parent.name), hex: parent.color)
                            Divider()
                            ForEach(children, id: \.hex) { child in
                                colorMenuItem(name: ColorPresets.displayName(child.name), hex: child.hex)
                            }
                        } label: {
                            Label {
                                Text(ColorPresets.displayName(parent.name))
                            } icon: {
                                swatchImage(hex: parent.color)
                            }
                        }
                    }
                }
            }
        } label: {
            Circle()
                .fill(model.draftColor)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                // Same cell as the buttons, so the dot sits on the row's rhythm.
                .frame(width: Self.slot, height: Self.slot)
                .background(controlRing())
                .contentShape(.rect)
        }
        .buttonStyle(AccessoryControlStyle())
        // The accessory sits at the bottom of the screen, so the menu opens
        // upwards; keep the presets in their JSON order rather than reversed.
        .menuOrder(.fixed)
        // The dot is custom-filled, so it keeps full strength when disabled;
        // the cluster's grayscale handles the hue, this handles the weight.
        .opacity(isConnected ? 1 : 0.4)
        .accessibilityLabel("面板颜色")
    }

    /// The solid colour dot's diameter, inside the 32pt ring.
    private static let dotDiameter: CGFloat = 22

    /// One colour in the menu, checked when it is the board's current colour.
    private func colorMenuItem(name: String, hex: String) -> some View {
        Toggle(isOn: Binding(
            get: { isCurrentColor(hex) },
            set: { _ in Task { await model.setColor(hex: hex, connection: connection) } }
        )) {
            Label {
                Text(name)
            } icon: {
                swatchImage(hex: hex)
            }
        }
    }

    /// Menus re-tint SwiftUI foreground styles to the label colour, so the
    /// swatch is baked into an original-rendering `UIImage` instead.
    private func swatchImage(hex: String) -> Image {
        let color = UIColor(Color(hex: hex) ?? .rinaPink)
        let symbol = UIImage(systemName: "circle.fill")?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        return symbol.map { Image(uiImage: $0) } ?? Image(systemName: "circle.fill")
    }

    private func isCurrentColor(_ hex: String) -> Bool {
        guard let candidate = RGBHex.parseHex(hex), let current = RGBHex.parseHex(model.colorHexDraft) else {
            return false
        }
        return candidate == current
    }

    // MARK: Derived state

    /// The summary button's accessibility label. While a group is targeted
    /// this spells out the group name and its online count even at
    /// accessibility sizes, where `showsSubtitle` drops the second line from
    /// the visible bar to keep its fixed system height (BOARD_GROUP_SPEC.md
    /// §3).
    private var accessibilityTitle: String {
        guard let group = targetedGroup else { return "面板控制" }
        let online = group.members.filter { groupCoordinator.status(for: $0) != .offline }.count
        return String(
            format: NSLocalizedString("控制对象：多板组 %@，%lld/%lld 在线", comment: "control target accessibility label for a group"),
            group.name, online, group.members.count
        )
    }

    /// "已连接" — the compact secondary state line: connection state only.
    /// While a group is targeted this instead reads "播放中" or
    /// "<online>/<total> 在线" (BOARD_GROUP_SPEC.md §3).
    private var subtitle: String {
        guard let group = targetedGroup else { return stateText }
        // N1: paused counts as active here too — app-level pause never ends
        // group ownership, so this must keep reading "已暂停" rather than
        // falling back to the plain online count.
        if groupCoordinator.activeGroupID == group.id {
            if groupCoordinator.isPlaying { return "播放中" }
            if groupCoordinator.isPaused { return "已暂停" }
        }
        let online = group.members.filter { groupCoordinator.status(for: $0) != .offline }.count
        return "\(online)/\(group.members.count) 在线"
    }

    /// The state line plus the battery level, which is only drawn in the
    /// ring(s). While a group is targeted every member's level is read out,
    /// in slot order.
    private var accessibilitySummary: String {
        let readings: [BatteryReading?] = targetedGroup.map { $0.members.map(memberBattery) }
            ?? [connection.batteryReading]
        let parts = readings.compactMap { reading -> String? in
            switch reading {
            case .level(let percent):
                return String(format: NSLocalizedString("电量 %lld%%", comment: "battery percent"), percent)
            case .notDetected:
                return NSLocalizedString("未检测到电池", comment: "battery not detected")
            case nil:
                return nil
            }
        }
        return parts.isEmpty ? subtitle : subtitle + " · " + parts.joined(separator: "，")
    }

    private var stateText: String {
        switch connection.connectionState {
        case .connected: return NSLocalizedString("已连接", comment: "connection state connected")
        case .connecting: return NSLocalizedString("连接中", comment: "connection state connecting")
        case .reconnecting: return NSLocalizedString("重连中", comment: "connection state reconnecting")
        case .disconnected: return NSLocalizedString("未连接", comment: "connection state disconnected")
        case .failed(let message): return String(format: NSLocalizedString("连接失败：%@", comment: "connection state failed"), message)
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

/// Battery level as a ring: a coloured arc over a gray track, around a filled
/// disc with the bare percentage in white. Red at 20% and below. With no
/// battery detected the track stays empty and the red disc carries a white
/// exclamation mark instead of a number.
@available(iOS 26.0, *)
private struct BatteryRing: View {
    /// `nil` draws an empty gray ring: a group member that is offline or
    /// hasn't reported yet.
    var reading: BatteryReading?

    private static let lineWidth: CGFloat = 3
    private static let gap: CGFloat = 2

    private var progress: CGFloat {
        if case .level(let percent) = reading { return CGFloat(percent) / 100 }
        return 0
    }

    private var color: Color {
        switch reading {
        case .level(let percent) where percent > 20: return .green
        case nil: return Color.gray.opacity(0.35)
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.35), lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(color)
                .padding(Self.lineWidth + Self.gap)
            Group {
                switch reading {
                case .level(let percent):
                    Text("\(percent)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                case .notDetected:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .heavy))
                case nil:
                    EmptyView()
                }
            }
            .foregroundStyle(.white)
            .padding(Self.lineWidth + Self.gap + 1)
        }
        // The stroke straddles the path; inset it so the ring's outer edge is
        // the frame's edge, like the neighbouring `strokeBorder` rings.
        .padding(Self.lineWidth / 2)
        .animation(.snappy, value: reading)
    }
}

/// Press feedback for the accessory's inline controls: the pressed control
/// itself shrinks and dims, so the response stays on the button that was
/// touched instead of reading as the whole bar reacting.
///
/// The dim matches `PillButtonStyle`, the app's other pressable surface. The
/// shrink stays inside the 0.95-0.98 band — these are the most frequently
/// pressed controls in the app, on a bar that is mounted for its whole
/// lifetime, so the response has to register without reading as a pop. Under
/// Reduce Motion only the dim is left: the scale is a size change.
@available(iOS 26.0, *)
private struct AccessoryControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }

    /// A real view rather than the style's own body, so the environment read
    /// is guaranteed to resolve against the view hierarchy. (`PillButtonStyle`
    /// reads `isEnabled` straight off the style struct; that works, but only
    /// this form is documented to.)
    private struct Feedback: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
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
