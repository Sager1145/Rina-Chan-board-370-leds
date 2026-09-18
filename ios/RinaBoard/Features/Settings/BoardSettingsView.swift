import SwiftUI
import RinaCore

/// "面板" category (design guide §33, §35): what the connected board reports,
/// the raw values behind the Control Center's drafts, and reboot.
struct BoardSettingsView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(SettingsWorkspace.self) private var workspace

    private var isConnected: Bool { connection.connectionState == .connected }

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
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("面板")
    }
}
