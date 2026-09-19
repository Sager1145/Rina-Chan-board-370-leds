import SwiftUI
import RinaCore

/// "面板" category (design guide §33, §35): the selected board's name, what
/// it reports (device, firmware, protocol), and reboot. Brightness, color
/// and interval stay in the Control Center: its drafts are not board facts.
struct BoardSettingsView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardSessionStore.self) private var sessions
    @Environment(BoardStore.self) private var boardStore
    @Environment(SettingsWorkspace.self) private var workspace

    /// Shown beside the sidebar without the user having opened it: reads
    /// nothing from the board.
    var isPassive = false

    private var isConnected: Bool { connection.connectionState == .connected }
    private var viewModel: ConnectionViewModel { workspace.connection }

    /// One connected board session; `nil` while disconnected.
    private var boardDetailsKey: ConnectionViewModel.BoardDetailsKey? {
        guard isConnected else { return nil }
        return .init(connection: ObjectIdentifier(connection), generation: connection.connectionGeneration)
    }

    private struct PageTaskID: Hashable {
        let board: ConnectionViewModel.BoardDetailsKey?
        let isPassive: Bool
    }

    var body: some View {
        Form {
            Group {
                BoardNameSection(viewModel: viewModel, isConnected: isConnected) {
                    workspace.run(from: .board) {
                        await viewModel.renameBoard(connection: connection, boardStore: boardStore,
                                                    ble: sessions.active.bleTransport)
                    }
                }

                Section {
                    LabeledContent("设备") {
                        Text(connection.status?.device ?? "—").foregroundStyle(.secondary)
                    }
                    LabeledContent("固件版本") {
                        Text(viewModel.boardFirmware ?? "—").foregroundStyle(.secondary)
                    }
                    if let build = viewModel.boardBuild {
                        LabeledContent("固件构建") {
                            Text(build).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("协议版本") {
                        Text(connection.protocolVersion.map(String.init) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if case .bluetooth = connection.transportKind,
                       let rssi = sessions.active.bleTransport.connectedRSSI {
                        LabeledContent("蓝牙信号强度") {
                            Text("\(rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if let refresh = connection.status?.renderer?.ledRefreshUs {
                        LabeledContent("刷新耗时") {
                            Text("\(refresh) µs").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    // The dialog is attached in `SettingsView`, above the
                    // layout switch, so a resize cannot dismiss it.
                    Button("重启此面板", systemImage: "arrow.clockwise") {
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
        // Keyed on the board session, and the model remembers which session
        // it last loaded, so the page being rebuilt by a resize neither wipes
        // a half-typed name nor reloads what it already has.
        .task(id: PageTaskID(board: boardDetailsKey, isPassive: isPassive)) {
            guard !isPassive else { return }
            await viewModel.loadBoardDetails(for: boardDetailsKey, connection: connection)
        }
        .errorAlert(workspace.connectionError(for: .board))
    }
}

/// The board's own name (`set_name`), kept on the board and advertised over
/// BLE and Bonjour.
private struct BoardNameSection: View {
    @Bindable var viewModel: ConnectionViewModel
    let isConnected: Bool
    let save: () -> Void

    var body: some View {
        Section {
            TextField("璃奈板名称", text: $viewModel.boardNameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isConnected || viewModel.isRenamingBoard)

            Button {
                save()
            } label: {
                if viewModel.isRenamingBoard {
                    ProgressView()
                } else {
                    Text("保存名称")
                }
            }
            .disabled(!isConnected || viewModel.isRenamingBoard)

            if viewModel.boardHasCustomName {
                Button("恢复默认名称", role: .destructive) {
                    viewModel.boardNameInput = ""
                    save()
                }
                .disabled(!isConnected || viewModel.isRenamingBoard)
            }

            if let defaultName = viewModel.boardDefaultName {
                LabeledContent("默认名称", value: defaultName)
            }
            if let status = viewModel.boardNameStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("璃奈板名称")
        }
    }
}
