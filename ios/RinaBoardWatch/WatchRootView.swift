import SwiftUI
import WatchKit

/// The whole remote on one crown-scrollable list: which board the watch is
/// pointed at and how it is doing, then that board's controls — faces, scroll
/// speed, colour and lip sync.
///
/// Two rules shape the layout. Every adjustable number opens its own screen so
/// the Digital Crown, not a fingertip, drives it. And every action that takes
/// effect in place answers with a haptic, because the board is rarely in the
/// same glance as the watch — the wrist is the only confirmation you get.
struct WatchRootView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// A prev/next tap. The count makes two taps in the same direction two
    /// distinct values, so the haptic fires for each one and not just the first.
    private struct FaceStep: Equatable {
        var count = 0
        var direction = 0
    }

    /// A lip-sync toggle this watch asked for. Keyed on the tap, not on
    /// `lipSync.isRunning`: that flips for a start from the phone, and for a
    /// target switch to a board in the other state, neither of which the
    /// wearer did.
    private struct LipToggle: Equatable {
        var count = 0
        var starting = false
    }

    @State private var faceStep = FaceStep()
    @State private var lipToggle = LipToggle()
    @ScaledMetric(relativeTo: .body) private var swatchDiameter: CGFloat = 22

    var body: some View {
        NavigationStack {
            List {
                targetSection
                if let snapshot = model.snapshot {
                    faceSection(snapshot)
                    scrollSection(snapshot)
                    colorSection(snapshot)
                    lipSyncSection(snapshot)
                }
            }
            .navigationTitle("璃奈板")
            .containerBackground(boardGradient, for: .navigation)
            .sensoryFeedback(trigger: faceStep) { _, new in
                new.direction > 0 ? .increase : .decrease
            }
            .sensoryFeedback(trigger: lipToggle) { _, new in
                new.starting ? .start : .stop
            }
            .alert("出错了", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("好") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    // MARK: Board colour

    /// The colour the board is showing, or the app's accent while we have no
    /// snapshot to read it from.
    private var boardColor: Color {
        Color(hex: model.snapshot?.controls.colorHex ?? "") ?? .accentColor
    }

    /// The board's own colour washed over the top of the screen: which board
    /// the watch drives, readable before any of the text is. It goes grey when
    /// the board is not connected, and nearly away in Always-On, where the
    /// screen is meant to be quiet.
    private var boardGradient: LinearGradient {
        let tint = model.isConnected ? boardColor : .gray
        let strength = isLuminanceReduced ? 0.08 : 0.3
        return LinearGradient(colors: [tint.opacity(strength), .black],
                              startPoint: .top, endPoint: .bottom)
    }

    // MARK: Target & status

    private var targetSection: some View {
        // The row shows the board, not the word: the name and its status are
        // what you came to read. The header keeps the phone's term for what
        // tapping it changes.
        Section("控制对象") {
            if model.snapshot == nil {
                targetRow
            } else {
                NavigationLink {
                    WatchTargetPickerView()
                } label: {
                    targetRow
                }
            }
        }
    }

    private var targetRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.selectedTarget?.name ?? "—")
                .font(.headline)
                .lineLimit(1)
            statusLine
        }
        .padding(.vertical, 2)
    }

    /// One line under the target's name: what the phone and the board are
    /// doing, and the board's battery when it reports one. Small enough that
    /// the battery never has to compete with the status for width.
    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 4) {
            if !model.isReachable {
                Image(systemName: "iphone.slash")
                Text("iPhone 不可达")
                    .lineLimit(1)
            } else if let snapshot = model.snapshot {
                if snapshot.board.isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(snapshot.board.memberCount > 1
                         ? String(format: NSLocalizedString("已连接 %lld / %lld", comment: "watch: group members connected"),
                                  snapshot.board.connectedCount, snapshot.board.memberCount)
                         : NSLocalizedString("已连接", comment: "watch: board connected"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let percent = snapshot.board.batteryPercent {
                        Spacer(minLength: 2)
                        Image(systemName: snapshot.board.isCharging
                              ? "battery.100percent.bolt" : "battery.50percent")
                        Text(String(format: NSLocalizedString("%lld%%", comment: "watch: percent"), percent))
                            .monospacedDigit()
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "circle.slash")
                    Text("未连接")
                }
            } else {
                ProgressView()
                    .controlSize(.mini)
                Text("等待 iPhone…")
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: Faces

    private func faceSection(_ snapshot: WatchBoardSnapshot) -> some View {
        @Bindable var model = model
        let index = snapshot.controls.faceIndex
        let count = snapshot.controls.faceCount
        return Section {
            // The one control used most from a wrist, so it gets the widest
            // targets on the screen and no value to read first.
            HStack(spacing: 6) {
                Button {
                    stepFace(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .accessibilityLabel("上一个")
                Button {
                    stepFace(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .accessibilityLabel("下一个")
            }
            .buttonStyle(.bordered)
            .listRowBackground(Color.clear)

            NavigationLink {
                WatchCrownValueView(
                    title: "亮度",
                    systemImage: "sun.max",
                    value: $model.brightness,
                    range: Double(snapshot.controls.brightnessMin)...Double(snapshot.controls.brightnessMax),
                    step: 5,
                    tint: boardColor,
                    minSymbol: "sun.min",
                    maxSymbol: "sun.max",
                    label: { String(format: NSLocalizedString("%lld%%", comment: "watch: percent"),
                                    model.brightnessPercent($0)) },
                    onChange: { model.brightnessChanged() }
                )
            } label: {
                WatchValueRow(title: "亮度", systemImage: "sun.max",
                              value: String(format: NSLocalizedString("%lld%%", comment: "watch: percent"),
                                            model.brightnessPercent(model.brightness)))
            }

            Toggle(isOn: Binding(
                get: { snapshot.controls.isAutoMode },
                set: { model.setAutoMode($0) }
            )) {
                WatchRowLabel(title: "自动切换", systemImage: "arrow.triangle.2.circlepath")
            }

            NavigationLink {
                WatchCrownValueView(
                    title: "切换间隔",
                    systemImage: "timer",
                    value: $model.autoIntervalSeconds,
                    range: snapshot.controls.autoIntervalMinSeconds...snapshot.controls.autoIntervalMaxSeconds,
                    step: 0.5,
                    tint: boardColor,
                    label: { String(format: NSLocalizedString("%.1f 秒", comment: "watch: seconds"), $0) },
                    onChange: { model.autoIntervalChanged() }
                )
            } label: {
                WatchValueRow(title: "切换间隔", systemImage: "timer",
                              value: String(format: NSLocalizedString("%.1f 秒", comment: "watch: seconds"),
                                            model.autoIntervalSeconds))
            }
            .disabled(!snapshot.controls.isAutoMode)
        } header: {
            HStack {
                Text("表情")
                if let index, let count, count > 0 {
                    Spacer()
                    Text(String(format: NSLocalizedString("%lld / %lld", comment: "watch: face index of count"),
                                index + 1, count))
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel({
                guard let index, let count, count > 0 else {
                    return NSLocalizedString("表情", comment: "watch: faces section")
                }
                return String(format: NSLocalizedString("表情 %lld / %lld", comment: "watch: face index of count"),
                              index + 1, count)
            }())
        }
        .disabled(!model.canControl)
    }

    private func stepFace(_ direction: Int) {
        faceStep = FaceStep(count: faceStep.count + 1, direction: direction)
        model.stepFace(direction)
    }

    // MARK: Scroll text

    private func scrollSection(_ snapshot: WatchBoardSnapshot) -> some View {
        @Bindable var model = model
        let active = snapshot.controls.isScrollActive
        return Section("滚动文字") {
            NavigationLink {
                WatchCrownValueView(
                    title: "滚动速度",
                    systemImage: "hare",
                    value: $model.scrollFps,
                    range: Double(snapshot.controls.scrollFpsMin)...Double(snapshot.controls.scrollFpsMax),
                    step: 1,
                    tint: boardColor,
                    minSymbol: "tortoise",
                    maxSymbol: "hare",
                    label: { String(format: NSLocalizedString("%lld fps", comment: "watch: frames per second"), Int($0)) },
                    onChange: { model.scrollFpsChanged() }
                )
            } label: {
                WatchValueRow(
                    title: "滚动速度",
                    systemImage: "hare",
                    value: active
                        ? String(format: NSLocalizedString("%lld fps", comment: "watch: frames per second"),
                                 Int(model.scrollFps))
                        : NSLocalizedString("未在滚动", comment: "watch: no scroll running")
                )
            }
            .disabled(!active || !model.canControl)
        }
    }

    // MARK: Colour

    private func colorSection(_ snapshot: WatchBoardSnapshot) -> some View {
        let hex = snapshot.controls.colorHex
        // The phone already localised every preset name, so naming the current
        // colour costs nothing and saves opening the grid to see which it is.
        let name = snapshot.controls.presets
            .first { $0.hex.lowercased() == hex.lowercased() }?.name
        return Section("颜色") {
            NavigationLink {
                WatchColorPickerView()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: hex) ?? .accentColor)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                        .frame(width: swatchDiameter, height: swatchDiameter)
                    Text(name ?? NSLocalizedString("自定义", comment: "watch: colour outside the presets"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .disabled(!model.canControl || snapshot.controls.presets.isEmpty)
        }
    }

    // MARK: Lip sync

    private func lipSyncSection(_ snapshot: WatchBoardSnapshot) -> some View {
        @Bindable var model = model
        let lip = snapshot.lipSync
        return Section {
            Button {
                lipToggle = LipToggle(count: lipToggle.count + 1, starting: !lip.isRunning)
                model.toggleLipSync()
            } label: {
                Label(lip.isRunning ? "停止同步" : "开始同步",
                      systemImage: lip.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(lip.isRunning ? .red : .accentColor)
            .disabled(!lip.isAvailable || lip.isStarting || (!lip.isRunning && !model.canControl))
            .listRowBackground(Color.clear)

            NavigationLink {
                WatchCrownValueView(
                    title: "麦克风灵敏度",
                    systemImage: "mic",
                    value: $model.sensitivityDb,
                    range: lip.sensitivityMinDb...lip.sensitivityMaxDb,
                    step: 1,
                    tint: boardColor,
                    label: { String(format: NSLocalizedString("%.0f dB", comment: "watch: decibels"), $0) },
                    onChange: { model.sensitivityChanged() }
                )
            } label: {
                WatchValueRow(title: "麦克风灵敏度", systemImage: "mic",
                              value: String(format: NSLocalizedString("%.0f dB", comment: "watch: decibels"),
                                            model.sensitivityDb))
            }
            .disabled(!lip.canEditOptions || !model.isReachable)
        } header: {
            HStack {
                Text("口型同步")
                Spacer()
                // A live indicator beats re-reading the button: the section
                // says it is listening even while the row is scrolled past.
                if lip.isStarting {
                    ProgressView()
                        .controlSize(.mini)
                } else if lip.isRunning {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: !isLuminanceReduced)
                        .foregroundStyle(.red)
                }
            }
        } footer: {
            if lip.isRunning {
                Text("正在用 iPhone 的麦克风驱动嘴型")
            } else if !lip.isAvailable {
                Text("多板组未同步时无法从手表开始口型同步")
            } else if lip.permission == .denied {
                Text("请在 iPhone 上允许麦克风权限")
            } else {
                Text("使用 iPhone 的麦克风")
            }
        }
    }
}

// MARK: - Rows

/// The left half of a settings row: a fixed icon column so a list of them
/// scans down the screen as one, and a title that truncates rather than shrink.
struct WatchRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// A row that names a value and shows it. The value is kept whole and the
/// title gives way first — a clipped "滚动速" still reads, a clipped "12 fp"
/// does not.
struct WatchValueRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            WatchRowLabel(title: title, systemImage: systemImage)
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Helpers

/// A tap that ends in a dismissal cannot use `.sensoryFeedback`: the view is
/// gone before the trigger is observed, so those play the haptic themselves.
@MainActor
func watchPlaySelectionHaptic() {
    WKInterfaceDevice.current().play(.click)
}

extension Color {
    /// `#rrggbb` → `Color`, or `nil` when the string does not parse.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
