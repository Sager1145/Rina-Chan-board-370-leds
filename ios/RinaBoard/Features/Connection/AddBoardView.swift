import SwiftUI
import RinaCore

/// "添加璃奈板" category: the three ways to reach a board that is not in the
/// list yet — BLE scan, home Wi-Fi (Bonjour + manual host) and joining the
/// board's own hotspot. Boards already known live on the Connection page.
struct AddBoardView: View {
    @Environment(BoardSessionStore.self) private var sessions
    @Environment(BoardStore.self) private var boardStore
    @Bindable private var workspace: SettingsWorkspace
    @Bindable private var viewModel: ConnectionViewModel

    /// Shown beside the category list without the user having opened it: does not
    /// browse the network.
    private let isPassive: Bool

    init(workspace: SettingsWorkspace, isPassive: Bool = false) {
        self.workspace = workspace
        self.viewModel = workspace.connection
        self.isPassive = isPassive
    }

    private var filteredPeripherals: [DiscoveredPeripheral] {
        let query = workspace.bluetoothFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions.scanner.discoveredPeripherals }
        return sessions.scanner.discoveredPeripherals.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.uuidString.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Form {
            Group {
                bluetoothSection
                homeWifiSection
                hotspotSection
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("添加璃奈板")
        // Bonjour browses while an opened page that lists it is on screen. A
        // task rather than onAppear/onDisappear: its cancellation always
        // pairs with its start, so the browser cannot be left running.
        .task(id: isPassive) {
            guard !isPassive else { return }
            workspace.connectionPageAppeared()
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            workspace.connectionPageDisappeared()
        }
        .task(id: isPassive) {
            guard !isPassive else { return }
            // The phone can wander onto a different remembered board hotspot
            // (or off it entirely) while this page isn't visible; refresh the
            // cache whenever it (re)appears rather than trusting a stale join.
            await HotspotJoiner.revalidateLastJoinedSSID()
        }
        .errorAlert(workspace.connectionError(for: .addBoard))
    }

    private func selectSession(id: String, name: String) -> BoardSession {
        let target = sessions.session(for: id, name: name)
        sessions.select(target)
        return target
    }

    // MARK: Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        Section {
            // A button, not a toggle: scanning is an action the user starts
            // and stops, and a switch implies a persistent setting that
            // survives leaving the page — it does not (connecting stops it).
            Button {
                workspace.markConnectionAction(from: .addBoard)
                viewModel.toggleBLEScan(ble: sessions.scanner)
            } label: {
                HStack(spacing: 10) {
                    SwapSymbol(systemName: sessions.scanner.isScanning
                          ? "stop.circle.fill"
                          : "antenna.radiowaves.left.and.right")
                    Text(sessions.scanner.isScanning ? "停止扫描" : "扫描附近的璃奈板")
                        .swapText(sessions.scanner.isScanning)
                    Spacer()
                    if sessions.scanner.isScanning { ProgressView() }
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(sessions.scanner.isScanning ? "停止扫描" : "扫描附近的璃奈板")
            .disabled(viewModel.isConnectingBLE)

            if sessions.scanner.isScanning && sessions.scanner.discoveredPeripherals.isEmpty {
                // The button already shows a spinner; a second one here would
                // read as two independent activities.
                Text("正在搜索…").foregroundStyle(.secondary)
            }

            if !sessions.scanner.isScanning && sessions.scanner.scanDidTimeOut {
                // Without this the spinner just vanishes and the user cannot
                // tell a finished scan from a crashed one.
                Text("扫描已在 \(Int(BLETransport.scanTimeoutSeconds)) 秒后自动停止，点按上方按钮可重新扫描。")
                    .foregroundStyle(.secondary)
            }

            TextField("按名称或设备编号筛选", text: $workspace.bluetoothFilter)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("bluetooth.deviceFilter")

            if !sessions.scanner.discoveredPeripherals.isEmpty && filteredPeripherals.isEmpty {
                Text("没有匹配的璃奈板，请修改筛选内容。")
                    .foregroundStyle(.secondary)
            }

            ForEach(filteredPeripherals) { peripheral in
                peripheralRow(peripheral)
            }
        } header: {
            Text("蓝牙")
        }
    }

    @ViewBuilder
    private func peripheralRow(_ peripheral: DiscoveredPeripheral) -> some View {
        let target = sessions.existingSession(for: peripheral.id.uuidString)
        let isConnecting = target?.bleTransport.connectingPeripheralID == peripheral.id
        let isThisConnected = target?.connection.connectionState == .connected
        let isActive = target.map { $0.id == sessions.active.id } ?? false
        let isKnown = boardStore.boards.contains { $0.id == peripheral.id.uuidString }

        Button {
            workspace.run(from: .addBoard) {
                let target = selectSession(id: peripheral.id.uuidString, name: peripheral.name)
                guard target.connection.connectionState != .connected else { return }
                sessions.scanner.stopScan()
                await viewModel.connectBLE(peripheral, ble: target.bleTransport, connection: target.connection, boardStore: boardStore)
            }
        } label: {
            HStack(spacing: 12) {
                SignalBars(rssi: peripheral.rssi)
                    .foregroundStyle(isThisConnected ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(peripheral.name)
                            .foregroundStyle(.primary)
                        if isActive {
                            CurrentBoardBadge()
                        } else if isKnown {
                            Text("已保存")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    // The identifier suffix is the only way to tell two boards
                    // apart when neither advertises a name (older firmware).
                    Text("\(peripheral.shortID) · \(peripheral.rssi) dBm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                if isConnecting {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("连接中")
                    }
                } else if isThisConnected {
                    Label("已连接", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("连接")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(viewModel.isConnectingBLE)
    }

    // MARK: Home Wi-Fi

    @ViewBuilder
    private var homeWifiSection: some View {
        Section {
            ForEach(viewModel.bonjour.boards) { board in
                Button {
                    workspace.run(from: .addBoard) {
                        guard board.isResolved else { return }
                        let target = selectSession(id: board.serviceIdentity?.storageID ?? board.host ?? board.name, name: board.name)
                        guard target.connection.connectionState != .connected else { return }
                        await viewModel.connectBonjour(board, connection: target.connection, boardStore: boardStore)
                    }
                } label: {
                    HStack {
                        Text(board.name)
                        Spacer()
                        if let host = board.host { Text(host).foregroundStyle(.secondary) }
                    }
                }
            }
            HStack {
                TextField("手动输入主机名或 IP", text: $viewModel.manualHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("连接") {
                    workspace.run(from: .addBoard) {
                        let host = viewModel.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        let target = selectSession(id: host, name: host)
                        guard target.connection.connectionState != .connected else { return }
                        await viewModel.connectManualHost(connection: target.connection, boardStore: boardStore)
                    }
                }
                .disabled(viewModel.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("家庭 Wi-Fi")
        }
    }

    // MARK: Hotspot

    @ViewBuilder
    private var hotspotSection: some View {
        Section {
            Button {
                workspace.run(from: .addBoard) { await viewModel.connectHotspot(sessions: sessions, boardStore: boardStore) }
            } label: {
                if isJoiningHotspot {
                    ProgressView()
                } else {
                    Text("加入璃奈板热点并连接")
                }
            }
            .disabled(isJoiningHotspot)

            if let status = directAPStatusText {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("热点直连")
        }
    }

    private var isJoiningHotspot: Bool {
        switch viewModel.directAPStage {
        case .joiningPhoneToBoardAP, .connectingToBoard:
            true
        case .idle, .connected, .failed:
            false
        }
    }

    /// `isJoiningHotspot` maps `.failed` to "not joining", which made the
    /// spinner disappear with the reason discarded.
    private var directAPStatusText: String? {
        switch viewModel.directAPStage {
        case .idle, .joiningPhoneToBoardAP:
            nil
        case .connectingToBoard:
            "正在连接板子…"
        case .connected:
            "已连接到板子（板载热点）"
        case .failed(let message):
            message
        }
    }
}

/// Four bars mapped from RSSI. Thresholds are the usual BLE rules of thumb:
/// > -55 dBm is touching distance, < -85 dBm is barely reachable.
private struct SignalBars: View {
    let rssi: Int

    var body: some View {
        let level: Int = switch rssi {
        case (-55)...: 4
        case (-67)..<(-55): 3
        case (-80)..<(-67): 2
        case (-90)..<(-80): 1
        default: 0
        }
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: CGFloat(4 + bar * 3))
            }
        }
        .frame(height: 16)
        .accessibilityLabel("信号强度 \(level) 格，\(rssi) dBm")
    }
}
