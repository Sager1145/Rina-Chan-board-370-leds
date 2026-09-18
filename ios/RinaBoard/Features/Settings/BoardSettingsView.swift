import SwiftUI
import RinaCore

/// "面板" category (design guide §33, §35): what the connected board reports,
/// the raw values behind the Control Center's drafts, and reboot.
struct BoardSettingsView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(SettingsWorkspace.self) private var workspace
    @Environment(BoardGroupStore.self) private var groupStore

    /// Mirrors the Control Center's "控制对象" choice (BOARD_GROUP_SPEC.md
    /// §3), so this row shows which one is active even on layouts where the
    /// Settings sidebar isn't visible next to it.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""

    private var isConnected: Bool { connection.connectionState == .connected }

    /// "单板 · <board>" / "多板组 · <name>".
    private var controlTargetSummary: String {
        switch ControlTarget.resolved(storedGroupIDString: controlTargetGroupIDStorage, in: groupStore) {
        case .single:
            return "单板 · \(connection.deviceName ?? "未连接")"
        case .group(let id):
            let name = groupStore.groups.first { $0.id == id }?.name ?? "多板组"
            return "多板组 · \(name)"
        }
    }

    var body: some View {
        Form {
            Group {
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
                }

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
                } footer: {
                    Text("亮度在界面上以百分比显示；此处为固件使用的 \(RinaLinkConstants.brightnessMin)–\(RinaLinkConstants.brightnessMax) 原始值。")
                }

                Section {
                    // The dialog is attached in `SettingsView`, above the
                    // layout switch, so a resize cannot dismiss it.
                    Button("重启面板", systemImage: "arrow.clockwise") {
                        workspace.confirmBoardReboot = true
                    }
                    .disabled(!isConnected)
                }

                Section {
                    LabeledContent("控制对象") {
                        Text(controlTargetSummary).foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        BoardGroupListView()
                    } label: {
                        Label("多板组", systemImage: "square.grid.3x1.below.line.grid.1x2")
                    }
                }
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("面板")
    }
}
