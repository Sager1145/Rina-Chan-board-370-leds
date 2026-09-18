import SwiftUI
import RinaCore

/// Connection tab (FEATURE_INVENTORY §E): status card, BLE scan/connect,
/// home Wi-Fi (Bonjour + manual host), hotspot join, and on-board Wi-Fi
/// provisioning (`wifi_*` over the active transport).
struct ConnectionView: View {
    @Environment(BoardSessionStore.self) private var sessions
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    /// Model and unsent input live in the app-scoped workspace, so a resize
    /// that swaps the Settings layout — and rebuilds this page — keeps them.
    @Bindable private var workspace: SettingsWorkspace
    @Bindable private var viewModel: ConnectionViewModel

    /// Shown beside the sidebar without the user having opened it: reads
    /// nothing from the board and does not browse the network.
    private let isPassive: Bool

    init(workspace: SettingsWorkspace, isPassive: Bool = false) {
        self.workspace = workspace
        self.viewModel = workspace.connection
        self.isPassive = isPassive
    }

    /// Read through the store rather than injected, because `any BLEConnecting`
    /// cannot go in the environment (`@Environment(T.self)` needs a concrete
    /// observable type) and the active session is the one this tab acts on.
    private var bleTransport: any BLEConnecting { sessions.active.bleTransport }

    private var isConnected: Bool { connection.connectionState == .connected }
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
                sessionsSection
                statusSection
                savedBoardsSection
                bluetoothSection
                boardNameSection
                homeWifiSection
                hotspotSection
                phoneHotspotSection
                boardWifiSection
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("连接")
        // Keyed on the board session, and the model remembers which session
        // it last loaded, so the page being rebuilt by a resize neither wipes
        // a half-typed name nor reloads what it already has.
        .task(id: PageTaskID(board: boardDetailsKey, isPassive: isPassive)) {
            guard !isPassive else { return }
            await viewModel.loadBoardDetails(for: boardDetailsKey, connection: connection)
        }
        // Bonjour browses while an opened Connection page is on screen. A
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
            // (or off it entirely) while this tab isn't visible; refresh the
            // cache whenever it (re)appears rather than trusting a stale join.
            await HotspotJoiner.revalidateLastJoinedSSID()
        }
        .errorAlert($viewModel.lastErrorMessage)
        // The password sheet is attached in `SettingsView`, above the layout
        // switch, so a resize cannot dismiss it.
    }

    private struct PageTaskID: Hashable {
        let board: ConnectionViewModel.BoardDetailsKey?
        let isPassive: Bool
    }

    /// One connected board session; `nil` while disconnected.
    private var boardDetailsKey: ConnectionViewModel.BoardDetailsKey? {
        guard isConnected else { return nil }
        return .init(connection: ObjectIdentifier(connection), generation: connection.connectionGeneration)
    }

    private func selectSession(id: String, name: String) -> BoardSession {
        let target = sessions.session(for: id, name: name)
        sessions.select(target)
        return target
    }

    private var sessionsSection: some View {
        Section {
            ForEach(sessions.sessions) { session in
                if session.boardID != nil {
                    HStack {
                        Button {
                            sessions.select(session)
                        } label: {
                            HStack {
                                Image(systemName: sessions.active.id == session.id ? "checkmark.circle.fill" : "circle")
                                Text(session.connection.deviceName ?? session.name)
                                Spacer()
                                Text(session.connection.connectionState == .connected ? "在线" : "未连接")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("断开", role: .destructive) { session.connection.disconnect(userInitiated: true) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            NavigationLink {
                BoardGroupListView()
            } label: {
                Label("多板组…", systemImage: "rectangle.split.3x1")
            }
        } header: {
            Text("控制对象 · \(sessions.sessions.filter { $0.connection.connectionState == .connected }.count) 块在线")
        } footer: {
            Text("可连接多块璃奈板，点选要控制的板，其他板保持连接。多板 Wi-Fi 连接需处于同一网络；热点直连仅适用于当前加入的热点。")
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        Section("状态") {
            LabeledContent("传输方式", value: transportLabel)
            LabeledContent("状态", value: stateLabel)
            if let error = connection.lastError, !isConnected {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("connection.failureReason")
                // Secondary encouragement directly under the concrete
                // failure reason above — it never stands in for that
                // reason, and only appears once one is already shown.
                // Only once the app has given up: while it is still
                // retrying on its own, lastError is set too.
                if case .failed = connection.connectionState {
                    Text("请重新尝试连接")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if case .bluetooth = connection.transportKind,
               let connectedName = bleTransport.connectedPeripheralName {
                LabeledContent("已连接璃奈板", value: connectedName)
            }
            if case .bluetooth = connection.transportKind,
               let rssi = bleTransport.connectedRSSI {
                LabeledContent("蓝牙信号强度", value: "\(rssi) dBm")
            }
            if let info = connection.status {
                if let fw = info.renderer?.ledRefreshUs { LabeledContent("刷新耗时", value: "\(fw) µs") }
            }
            if let wifi = connection.wifi {
                if let ip = wifi.ip, !ip.isEmpty { LabeledContent("IP", value: ip) }
                if let rssi = wifi.rssi { LabeledContent("信号强度", value: "\(rssi) dBm") }
            }
            HStack {
                Circle()
                    .fill(isConnected ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(isConnected ? "在线" : "离线")
                Spacer()
                if isConnected {
                    Button("断开", role: .destructive) { connection.disconnect(userInitiated: true) }
                }
            }
        }
    }

    private var transportLabel: String {
        switch connection.transportKind {
        case .bluetooth: return "蓝牙"
        case .wifi: return "家庭 Wi-Fi"
        case .hotspot: return "热点直连"
        case nil: return "未连接"
        }
    }

    private var stateLabel: String {
        switch connection.connectionState {
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .reconnecting(let attempt): return "重连中(\(attempt))"
        case .failed(let message): return "失败: \(message)"
        }
    }

    // MARK: Saved boards

    @ViewBuilder
    private var savedBoardsSection: some View {
        if !boardStore.boards.isEmpty {
            Section {
                ForEach(boardStore.boards) { board in
                    HStack {
                        Button {
                            Task {
                                await viewModel.connectSavedBoard(
                                    board, sessions: sessions, boardStore: boardStore
                                )
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(board.name).foregroundStyle(.primary)
                                    Text(board.preferredTransport == "bluetooth" ? "蓝牙" : "Wi-Fi")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.connectingSavedBoardID == board.id {
                                    ProgressView()
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(viewModel.connectingSavedBoardID != nil || viewModel.isConnectingBLE)
                        .accessibilityLabel("连接 \(board.name)")

                        Button("忘记", role: .destructive) {
                            sessions.remove(id: board.id)
                            boardStore.remove(id: board.id)
                        }
                        .accessibilityLabel("忘记 \(board.name)")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("已保存的璃奈板")
            }
        }
    }

    // MARK: Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        Section {
            // A button, not a toggle: scanning is an action the user starts
            // and stops, and a switch implies a persistent setting that
            // survives leaving the tab — it does not (connecting stops it).
            Button {
                viewModel.toggleBLEScan(ble: sessions.scanner)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: sessions.scanner.isScanning
                          ? "stop.circle.fill"
                          : "antenna.radiowaves.left.and.right")
                    Text(sessions.scanner.isScanning ? "停止扫描" : "扫描附近的璃奈板")
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
        let isKnown = boardStore.boards.contains { $0.id == peripheral.id.uuidString }

        Button {
            Task {
                let target = selectSession(id: peripheral.id.uuidString, name: peripheral.name)
                guard target.connection.connectionState != .connected else { return }
                sessions.scanner.stopScan()
                await viewModel.connectBLE(peripheral, ble: target.bleTransport, connection: target.connection, boardStore: boardStore)
            }
        } label: {
            HStack(spacing: 12) {
                signalBars(rssi: peripheral.rssi)
                    .foregroundStyle(isThisConnected ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(peripheral.name)
                            .foregroundStyle(.primary)
                        if isKnown {
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

    /// Four bars mapped from RSSI. Thresholds are the usual BLE rules of thumb:
    /// > -55 dBm is touching distance, < -85 dBm is barely reachable.
    @ViewBuilder
    private func signalBars(rssi: Int) -> some View {
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

    // MARK: Board name

    @ViewBuilder
    private var boardNameSection: some View {
        Section {
            TextField("璃奈板名称", text: $viewModel.boardNameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isConnected || viewModel.isRenamingBoard)

            Button {
                Task { await viewModel.renameBoard(connection: connection, boardStore: boardStore, ble: bleTransport) }
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
                    Task { await viewModel.renameBoard(connection: connection, boardStore: boardStore, ble: bleTransport) }
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

    // MARK: Home Wi-Fi

    @ViewBuilder
    private var homeWifiSection: some View {
        Section("家庭 Wi-Fi") {
            ForEach(viewModel.bonjour.boards) { board in
                Button {
                    Task {
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
                    Task {
                        let host = viewModel.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        let target = selectSession(id: host, name: host)
                        guard target.connection.connectionState != .connected else { return }
                        await viewModel.connectManualHost(connection: target.connection, boardStore: boardStore)
                    }
                }
                .disabled(viewModel.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: Hotspot

    @ViewBuilder
    private var hotspotSection: some View {
        Section("热点直连") {
            Button {
                Task { await viewModel.connectHotspot(sessions: sessions, boardStore: boardStore) }
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

            if case .bluetooth = connection.transportKind, connection.wifi?.staConnected == true {
                Button("切换到 Wi-Fi") {
                    Task { await viewModel.switchToWifi(connection: connection, boardStore: boardStore) }
                }
            }
        }
    }

    // MARK: iPhone 热点 (RINALINK_PROTOCOL_V1 §8)

    @ViewBuilder
    private var phoneHotspotSection: some View {
        Section("iPhone 热点") {
            TextField("热点名称", text: $viewModel.hotspotName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField(viewModel.hotspotPassword.isEmpty ? "热点密码" : "使用已保存的密码", text: $viewModel.hotspotPassword)

            Button {
                Task { await viewModel.provisionPhoneHotspot(connection: connection, boardStore: boardStore) }
            } label: {
                if viewModel.isProvisioningHotspot {
                    ProgressView()
                } else {
                    Text("发送到板子并连接")
                }
            }
            .disabled(!isConnected || viewModel.isProvisioningHotspot || viewModel.hotspotName.trimmingCharacters(in: .whitespaces).isEmpty)

            if let status = hotspotStatusText {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }

            if let wifi = connection.wifi {
                LabeledContent("家庭网络", value: wifi.homeSsid ?? "无")
                LabeledContent("手机热点", value: wifi.hotspotSsid ?? "无")
                LabeledContent("当前使用", value: profileLabel(wifi.activeProfile))
            }

            Button("清除", role: .destructive) {
                Task { await viewModel.clearPhoneHotspot(connection: connection) }
            }
            .disabled(!isConnected)
        }
    }

    private func profileLabel(_ profile: String?) -> String {
        switch profile {
        case "home": return "家庭"
        case "hotspot": return "手机热点"
        default: return "无"
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

    private var hotspotStatusText: String? {
        switch viewModel.hotspotProvisionStage {
        case .idle:
            nil
        case .sendingCredentials, .waitingForBoard, .boardJoined, .connectingToBoard:
            "等待板子加入热点…"
        case .connected:
            "已连接到板子（手机热点）"
        case .failed(let message):
            message
        }
    }

    /// `homeProvisionStage` used to be written on every home-Wi-Fi provisioning
    /// path and read by nothing at all, so a wrong password produced a failure
    /// message that no view rendered — on the app's main onboarding path.
    private var homeStatusText: String? {
        switch viewModel.homeProvisionStage {
        case .idle:
            nil
        case .sendingCredentials, .waitingForBoard:
            "等待板子加入网络…"
        case .boardJoined:
            "板子已加入网络"
        case .connectingToBoard:
            "正在连接板子…"
        case .connected:
            "已连接到板子"
        case .failed(let message):
            message
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

    // MARK: Board Wi-Fi settings

    @ViewBuilder
    private var boardWifiSection: some View {
        Section("板载 Wi-Fi 设置") {
            Picker("模式", selection: modeBinding) {
                Text("关闭").tag("off")
                Text("仅热点").tag("ap")
                Text("家庭 Wi-Fi").tag("sta")
                Text("家庭 Wi-Fi（热点备用）").tag("sta_or_ap")
            }
            .disabled(!isConnected)

            Button {
                Task { await viewModel.scanNetworks(connection: connection) }
            } label: {
                if viewModel.isScanningNetworks {
                    ProgressView()
                } else {
                    Text("扫描网络")
                }
            }
            .disabled(!isConnected)

            if let status = homeStatusText {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }

            ForEach(viewModel.wifiNetworks) { network in
                Button {
                    workspace.passwordInput = ""
                    workspace.networkForPassword = network
                } label: {
                    HStack {
                        Text(network.ssid)
                        if network.secure {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(network.rssi) dBm").foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!isConnected)

            if let wifi = connection.wifi {
                LabeledContent("已连接网络", value: (wifi.staConnected == true ? wifi.ssid : nil) ?? "无")
                LabeledContent("IP", value: wifi.ip ?? "—")
                LabeledContent("信号", value: wifi.rssi.map { "\($0) dBm" } ?? "—")
                LabeledContent("热点状态", value: wifi.apActive == true ? "开启" : "关闭")
                if let apSsid = wifi.apSsid { LabeledContent("热点名称", value: apSsid) }
                if let apIp = wifi.apIp { LabeledContent("热点 IP", value: apIp) }
            }

            Button("忘记网络", role: .destructive) {
                Task { await viewModel.forgetNetwork(connection: connection) }
            }
            .disabled(!isConnected)

            VStack(alignment: .leading, spacing: 8) {
                Text("热点名称与密码").font(.subheadline)
                TextField("SSID", text: $workspace.apSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码 (留空为开放网络)", text: $workspace.apPassword)
                Button("保存") {
                    Task { await viewModel.setAp(ssid: workspace.apSSID, password: workspace.apPassword, connection: connection, boardStore: boardStore) }
                }
                .disabled(workspace.apSSID.isEmpty)
            }
            .disabled(!isConnected)
        }
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { connection.wifi?.mode ?? "sta_or_ap" },
            set: { newValue in Task { await viewModel.setMode(newValue, connection: connection) } }
        )
    }

}

// No #Preview: ConnectionView requires a live BLETransport (backed by a real
// CBCentralManager), which isn't safe/meaningful to construct in the
// Xcode Previews sandbox.

/// Joins the board to a scanned network. Presented from `SettingsView` so it
/// survives the Settings layout changing under it.
struct ConnectionPasswordSheet: View {
    let network: WifiNetwork
    @Environment(SettingsWorkspace.self) private var workspace
    @Environment(BoardConnection.self) private var connection

    var body: some View {
        @Bindable var workspace = workspace
        NavigationStack {
            Form {
                Section(network.ssid) {
                    if network.secure {
                        SecureField("密码", text: $workspace.passwordInput)
                    } else {
                        Text("开放网络，无需密码")
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("连接网络")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        workspace.passwordInput = ""
                        workspace.networkForPassword = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        let ssid = network.ssid
                        let password = workspace.passwordInput
                        workspace.passwordInput = ""
                        workspace.networkForPassword = nil
                        let viewModel = workspace.connection
                        Task { await viewModel.connectNetwork(ssid: ssid, password: password, connection: connection) }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
