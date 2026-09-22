import SwiftUI

/// The whole remote on one crown-scrollable list: target, board status, the
/// Control Center's board-wide controls, scroll speed, and lip sync. Every
/// adjustable value opens a screen the Digital Crown drives.
struct WatchRootView: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        @Bindable var model = model
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

    // MARK: Target & status

    private var targetSection: some View {
        Section {
            NavigationLink {
                WatchTargetPickerView()
            } label: {
                LabeledContent("控制对象") {
                    Text(model.selectedTarget?.name ?? "—")
                        .lineLimit(1)
                }
            }
            .disabled(model.snapshot == nil)
            statusRow
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if !model.isReachable {
            Label("iPhone 不可达", systemImage: "iphone.slash")
                .foregroundStyle(.secondary)
        } else if let snapshot = model.snapshot {
            if snapshot.board.isConnected {
                HStack {
                    Label(snapshot.board.memberCount > 1
                          ? String(format: NSLocalizedString("已连接 %lld / %lld", comment: "watch: group members connected"),
                                   snapshot.board.connectedCount, snapshot.board.memberCount)
                          : NSLocalizedString("已连接", comment: "watch: board connected"),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if let percent = snapshot.board.batteryPercent {
                        Text("\(percent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: snapshot.board.isCharging ? "battery.100percent.bolt" : "battery.50percent")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("未连接", systemImage: "circle.slash")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("等待 iPhone…", systemImage: "iphone.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Faces

    private func faceSection(_ snapshot: WatchBoardSnapshot) -> some View {
        @Bindable var model = model
        return Section("表情") {
            NavigationLink {
                WatchCrownValueView(
                    title: "亮度",
                    value: $model.brightness,
                    range: Double(snapshot.controls.brightnessMin)...Double(snapshot.controls.brightnessMax),
                    step: 5,
                    label: { String(format: "%lld%%", model.brightnessPercent($0)) },
                    onChange: { model.brightnessChanged() }
                )
            } label: {
                LabeledContent("亮度", value: String(format: "%lld%%", model.brightnessPercent(model.brightness)))
            }

            HStack {
                Button {
                    model.stepFace(-1)
                } label: {
                    Label("上一个", systemImage: "backward.fill")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("上一个")
                Button {
                    model.stepFace(1)
                } label: {
                    Label("下一个", systemImage: "forward.fill")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("下一个")
            }
            .buttonStyle(.bordered)
            .listRowBackground(Color.clear)

            if let index = snapshot.controls.faceIndex, let count = snapshot.controls.faceCount, count > 0 {
                Text(String(format: NSLocalizedString("表情 %lld / %lld", comment: "watch: face index of count"),
                            index + 1, count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("自动切换", isOn: Binding(
                get: { snapshot.controls.isAutoMode },
                set: { model.setAutoMode($0) }
            ))

            NavigationLink {
                WatchCrownValueView(
                    title: "切换间隔",
                    value: $model.autoIntervalSeconds,
                    range: snapshot.controls.autoIntervalMinSeconds...snapshot.controls.autoIntervalMaxSeconds,
                    step: 0.5,
                    label: { String(format: NSLocalizedString("%.1f 秒", comment: "watch: seconds"), $0) },
                    onChange: { model.autoIntervalChanged() }
                )
            } label: {
                LabeledContent("切换间隔",
                               value: String(format: NSLocalizedString("%.1f 秒", comment: "watch: seconds"),
                                             model.autoIntervalSeconds))
            }
            .disabled(!snapshot.controls.isAutoMode)
        }
        .disabled(!model.canControl)
    }

    // MARK: Scroll text

    private func scrollSection(_ snapshot: WatchBoardSnapshot) -> some View {
        @Bindable var model = model
        let active = snapshot.controls.isScrollActive
        return Section {
            NavigationLink {
                WatchCrownValueView(
                    title: "滚动速度",
                    value: $model.scrollFps,
                    range: Double(snapshot.controls.scrollFpsMin)...Double(snapshot.controls.scrollFpsMax),
                    step: 1,
                    label: { String(format: NSLocalizedString("%lld fps", comment: "watch: frames per second"), Int($0)) },
                    onChange: { model.scrollFpsChanged() }
                )
            } label: {
                LabeledContent("滚动速度") {
                    if active {
                        Text(String(format: NSLocalizedString("%lld fps", comment: "watch: frames per second"),
                                    Int(model.scrollFps)))
                    } else {
                        Text("未在滚动")
                    }
                }
            }
            .disabled(!active || !model.canControl)
        } header: {
            Text("滚动文字")
        }
    }

    // MARK: Colour

    private func colorSection(_ snapshot: WatchBoardSnapshot) -> some View {
        Section {
            NavigationLink {
                WatchColorPickerView()
            } label: {
                LabeledContent("颜色") {
                    Circle()
                        .fill(Color(hex: snapshot.controls.colorHex) ?? .pink)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white.opacity(0.4)))
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
                model.toggleLipSync()
            } label: {
                Label(lip.isRunning ? "停止同步" : "开始同步",
                      systemImage: lip.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(lip.isRunning ? .red : .accentColor)
            .disabled(!lip.isAvailable || lip.isStarting || (!lip.isRunning && !model.canControl))
            .listRowBackground(Color.clear)

            NavigationLink {
                WatchCrownValueView(
                    title: "麦克风灵敏度",
                    value: $model.sensitivityDb,
                    range: lip.sensitivityMinDb...lip.sensitivityMaxDb,
                    step: 1,
                    label: { String(format: NSLocalizedString("%.0f dB", comment: "watch: decibels"), $0) },
                    onChange: { model.sensitivityChanged() }
                )
            } label: {
                LabeledContent("麦克风灵敏度",
                               value: String(format: NSLocalizedString("%.0f dB", comment: "watch: decibels"),
                                             model.sensitivityDb))
            }
            .disabled(!lip.canEditOptions || !model.isReachable)
        } header: {
            Text("口型同步")
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
