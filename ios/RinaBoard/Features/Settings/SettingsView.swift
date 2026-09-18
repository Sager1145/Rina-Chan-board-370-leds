import SwiftUI
import RinaCore

/// Settings tab (design guide §31–§35): a native `Form`, no LED preview.
///
/// On iOS 17–25 this screen also hosts the Control Center, because those
/// releases have no persistent system bottom surface to attach it to and the
/// guide forbids hand-building one (§2). On iOS 26+ the Control Center lives
/// in the tab bar accessory, and on the two-column iPad layout it lives under
/// every other page's board preview; either way this section is omitted rather
/// than duplicated (§33).
struct SettingsView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(BoardGroupStore.self) private var groupStore

    /// Mirrors the Control Center's "控制对象" choice (BOARD_GROUP_SPEC.md
    /// §3), so the row that pushes it can show which one is active — on
    /// iOS 17–25 there is no tab-bar accessory to show it instead.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""

    @AppStorage(AppSettingsKey.showBoardPhoto) private var showBoardPhoto = true
    @AppStorage(AppSettingsKey.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettingsKey.keepScreenAwake) private var keepScreenAwake = false
    @AppStorage(AppSettingsKey.restoreLastTab) private var restoreLastTab = false

    @State private var confirmReboot = false
    @State private var rebootError: String?
    #if DEBUG
    @State private var opensDebug = UserDefaults.standard.string(forKey: "initialTab") == "debug"
    #endif

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if ControlCenterPlacement.resolve(
                        splitLayout: BoardPageColumns.isSplit(horizontalSizeClass)
                    ) == .settingsLink {
                        Section {
                            NavigationLink {
                                BoardControlCenterView()
                            } label: {
                                LabeledContent {
                                    Text(controlTargetSummary)
                                        .foregroundStyle(.secondary)
                                } label: {
                                    Label("面板控制中心", systemImage: "slider.horizontal.below.rectangle")
                                }
                            }
                        }
                    }

                    connectionSection
                    boardSection
                    appSection
                    debugSection
                    aboutSection
                }
                .rinaTranslucentRows()
            }
            .listSectionSpacing(.compact)
            .rinaScrollBackground()
            .navigationTitle("设置")
            #if DEBUG
            .navigationDestination(isPresented: $opensDebug) { DebugView() }
            #endif
        }
    }

    // MARK: §32 Connection

    private var connectionSection: some View {
        Section("连接") {
            LabeledContent("状态") {
                Text(stateText).foregroundStyle(.secondary)
            }
            NavigationLink {
                ConnectionView()
            } label: {
                Label("连接设置", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }

    /// "单板 · <board>" / "多板组 · <name>" — the current 控制对象, shown as
    /// this row's secondary value since iOS 17–25 has no tab-bar accessory to
    /// show it instead (BOARD_GROUP_SPEC.md §3).
    private var controlTargetSummary: String {
        switch ControlTarget.resolved(storedGroupIDString: controlTargetGroupIDStorage, in: groupStore) {
        case .single:
            return "单板 · \(connection.deviceName ?? "未连接")"
        case .group(let id):
            let name = groupStore.groups.first { $0.id == id }?.name ?? "多板组"
            return "多板组 · \(name)"
        }
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

    // MARK: §33 Board

    private var boardSection: some View {
        Section {
            LabeledContent("设备") {
                Text(connection.status?.device ?? "—").foregroundStyle(.secondary)
            }
            LabeledContent("协议版本") {
                Text(connection.protocolVersion.map(String.init) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("自动切换间隔") {
                Text(String(format: "%.1fs", controlCenter.autoIntervalDraft))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("重启面板", systemImage: "arrow.clockwise") {
                confirmReboot = true
            }
            .disabled(!isConnected)
            NavigationLink {
                BoardGroupListView()
            } label: {
                Label("多板组", systemImage: "square.grid.3x1.below.line.grid.1x2")
            }
        } header: {
            Text("面板")
        }
        .confirmationDialog("重启面板？", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("重启", role: .destructive) {
                Task {
                    do {
                        _ = try await connection.command(.reboot)
                    } catch {
                        // The firmware acknowledges `reboot` and only reboots
                        // 200 ms later, so a failure here means the command
                        // never arrived rather than "it rebooted, link gone".
                        rebootError = String(
                            format: NSLocalizedString("重启命令未送达：%@",
                                                      comment: "reboot command failed to reach the board"),
                            error.localizedDescription
                        )
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("面板将断开连接并重新启动。")
        }
        .errorAlert($rebootError)
    }

    // MARK: §34 App

    private var appSection: some View {
        Section {
            Toggle(isOn: $showBoardPhoto) {
                Label("显示面板照片", systemImage: "photo")
            }
            Toggle(isOn: $hapticsEnabled) {
                Label("触感反馈", systemImage: "hand.tap")
            }
            Toggle(isOn: $keepScreenAwake) {
                Label("控制时保持屏幕常亮", systemImage: "sun.max")
            }
            Toggle(isOn: $restoreLastTab) {
                Label("记住上次的标签页", systemImage: "square.on.square")
            }
        } header: {
            Text("应用")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label("关于", systemImage: "info.circle")
            }
        }
    }

    // MARK: §35 Debug

    private var debugSection: some View {
        Section {
            LabeledContent("亮度原始值") {
                Text("\(controlCenter.draftBrightness)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("颜色") {
                Text(controlCenter.colorHexDraft)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                DebugView()
            } label: {
                Label("调试工具", systemImage: "ladybug")
            }
        } header: {
            Text("调试")
        } footer: {
            Text("亮度在界面上以百分比显示；此处为固件使用的 \(RinaLinkConstants.brightnessMin)–\(RinaLinkConstants.brightnessMax) 原始值。")
        }
    }
}
