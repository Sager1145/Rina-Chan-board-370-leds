import SwiftUI
import RinaCore

/// "Wi-Fi 与热点" category: the selected board's own network settings
/// (`wifi_*` over the active transport, RINALINK_PROTOCOL_V1 §8) — which
/// network it joins and its own SoftAP.
struct BoardNetworkSettingsView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Bindable private var workspace: SettingsWorkspace
    @Bindable private var viewModel: ConnectionViewModel

    @State private var pendingMode: String?
    @State private var isChangingMode = false

    init(workspace: SettingsWorkspace) {
        self.workspace = workspace
        self.viewModel = workspace.connection
    }

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        Form {
            Group {
                statusSection
                joinNetworkSection
                boardHotspotSection
                hotspotAddressSection
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("Wi-Fi 与热点")
        .task(id: connection.connectionGeneration) {
            guard isConnected, connection.wifi == nil else { return }
            _ = try? await connection.refreshWifiStatus()
        }
        .confirmationDialog("更改 Wi-Fi 模式？", isPresented: Binding(
            get: { pendingMode != nil },
            set: { if !$0 { pendingMode = nil } }
        ), titleVisibility: .visible) {
            Button("更改模式", role: .destructive) {
                guard let mode = pendingMode else { return }
                pendingMode = nil
                applyMode(mode)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("更改后会断开与“\(boardName)”的当前连接。")
        }
        .errorAlert(workspace.connectionError(for: .network))
        // The password sheet is attached in `SettingsView`, above the layout
        // switch, so a resize cannot dismiss it.
    }

    // MARK: Status

    /// Mode plus everything the board reports about its links, once.
    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                if connection.wifi == nil {
                    Picker("模式", selection: .constant("loading")) {
                        Text("读取中…").tag("loading")
                    }
                    .disabled(true)
                    .accessibilityIdentifier("network.mode")
                } else {
                    Picker("模式", selection: modeBinding) {
                        Text("关闭").tag("off")
                        Text("仅热点").tag("ap")
                        Text("家庭 Wi-Fi").tag("sta")
                        Text("家庭 Wi-Fi（热点备用）").tag("sta_or_ap")
                    }
                    .disabled(!isConnected || isChangingMode || viewModel.isApplyingWifiMode)
                    .accessibilityIdentifier("network.mode")
                }
                if isChangingMode || viewModel.isApplyingWifiMode { ProgressView() }
            }

            if let wifi = connection.wifi {
                LabeledContent("已连接网络", value: (wifi.staConnected == true ? wifi.ssid : nil) ?? String(localized: "无"))
                LabeledContent("家庭 Wi-Fi IP", value: wifi.ip ?? "—")
                LabeledContent("信号", value: wifi.rssi.map { "\($0) dBm" } ?? "—")
                LabeledContent("热点状态", value: wifi.apActive == true ? String(localized: "开启") : String(localized: "关闭"))
                LabeledContent("热点 IP", value: wifi.apIp ?? "—")
            }
        } header: {
            Text("\(boardName) 的 Wi-Fi")
        } footer: {
            if !isConnected {
                Text("连接璃奈板后可修改这些设置。")
            }
        }
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { connection.wifi?.mode ?? "" },
            set: { newValue in requestModeChange(newValue) }
        )
    }

    private var boardName: String {
        connection.deviceName ?? String(localized: "此面板")
    }

    private func requestModeChange(_ mode: String) {
        guard mode != connection.wifi?.mode else { return }
        if modeDropsCurrentTransport(mode) {
            pendingMode = mode
        } else {
            applyMode(mode)
        }
    }

    private func modeDropsCurrentTransport(_ mode: String) -> Bool {
        switch connection.transportKind {
        case .wifi: mode == "off" || mode == "ap"
        case .hotspot: mode == "off" || mode == "sta"
        case .bluetooth, nil: false
        }
    }

    private func applyMode(_ mode: String) {
        isChangingMode = true
        workspace.run(from: .network) {
            await viewModel.setMode(mode, connection: connection)
            isChangingMode = false
        }
    }

    // MARK: Home network

    @ViewBuilder
    private var joinNetworkSection: some View {
        Section {
            if let wifi = connection.wifi {
                LabeledContent("家庭网络", value: wifi.homeSsid ?? String(localized: "无"))
            }

            Button {
                workspace.run(from: .network) { await viewModel.scanNetworks(connection: connection) }
            } label: {
                if viewModel.isScanningNetworks {
                    ProgressView()
                } else {
                    Text("扫描网络")
                }
            }
            .disabled(!isConnected || viewModel.isScanningNetworks)
            .accessibilityIdentifier("network.scan")

            if let status = homeStatusText {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }

            if !viewModel.isScanningNetworks && viewModel.wifiNetworks.isEmpty {
                Text("点击扫描网络，选择璃奈板附近的 Wi-Fi。")
                    .foregroundStyle(.secondary)
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
                .accessibilityIdentifier("network.result.\(network.ssid)")
            }
            .disabled(!isConnected)

            Button("忘记网络", role: .destructive) {
                workspace.run(from: .network) { await viewModel.forgetNetwork(connection: connection) }
            }
            .disabled(!isConnected)
        } header: {
            Text("家庭 Wi-Fi")
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
            String(localized: "等待板子加入网络…")
        case .boardJoined:
            String(localized: "板子已加入网络")
        case .connectingToBoard:
            String(localized: "正在连接板子…")
        case .connected:
            String(localized: "已连接到板子")
        case .failed(let message):
            message
        }
    }

    // MARK: Board SoftAP

    @ViewBuilder
    private var boardHotspotSection: some View {
        Section {
            if let apSsid = connection.wifi?.apSsid {
                LabeledContent("热点名称", value: apSsid)
            }
            TextField("SSID", text: $workspace.apSSID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码 (留空为开放网络)", text: $workspace.apPassword)
            Button("保存") {
                let capturedSSID = workspace.apSSID
                let capturedPassword = workspace.apPassword
                let capturedConnection = connection
                workspace.run(from: .network) {
                    await viewModel.setAp(ssid: capturedSSID, password: capturedPassword,
                                          connection: capturedConnection, boardStore: boardStore)
                }
            }
            .disabled(workspace.apSSID.isEmpty)
        } header: {
            Text("热点名称与密码")
        }
        .disabled(!isConnected)
    }

    @ViewBuilder
    private var hotspotAddressSection: some View {
        Section {
            TextField("热点 IPv4 地址", text: $workspace.apIP,
                      prompt: Text(verbatim: connection.wifi?.apIp ?? "—"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("network.apIP")
                .disabled(!isConnected || workspace.apIPSaveID != nil)

            if !workspace.apIP.isEmpty,
               BoardAPAddress.canonicalPrivateAddress(workspace.apIP) == nil {
                Text("请输入私有 IPv4 地址（10.x.x.x、172.16–31.x.x 或 192.168.x.x），最后一段须为 1–254。")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("network.apIP.validation")
            }
            if let status = workspace.apIPStatus,
               workspace.apIP.isEmpty || BoardAPAddress.canonicalPrivateAddress(workspace.apIP) != nil {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("network.apIP.status")
            }

            Button("保存 IP", action: saveHotspotAddress)
                .disabled(!isConnected || connection.transportKind != .bluetooth || workspace.apIPSaveID != nil)
                .accessibilityIdentifier("network.saveAPIP")
            if workspace.apIPSaveID != nil { ProgressView() }

            if isConnected && connection.transportKind != .bluetooth {
                Text("请先在连接页面切换到蓝牙，再保存热点 IP；修改地址会断开热点连接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("打开连接设置") { workspace.selection = .connection }
            }
        } header: {
            Text("热点 IP")
        } footer: {
            Text("仅保存热点 IP，不改变热点名称、密码或开启状态。")
        }
    }

    private func saveHotspotAddress() {
        guard isConnected, connection.transportKind == .bluetooth,
              workspace.apIPSaveID == nil else { return }
        guard let address = BoardAPAddress.canonicalPrivateAddress(workspace.apIP) else {
            workspace.apIPStatus = NSLocalizedString(
                "请输入私有 IPv4 地址（10.x.x.x、172.16–31.x.x 或 192.168.x.x），最后一段须为 1–254。",
                comment: "invalid board hotspot address")
            return
        }
        let capturedConnection = connection
        let capturedDraft = workspace.apIP
        let saveID = UUID()
        workspace.apIPSaveID = saveID
        workspace.apIPStatus = nil
        workspace.run(from: .network) {
            let saved = await viewModel.setAp(ssid: "", password: "", ip: address,
                                              connection: capturedConnection, boardStore: boardStore)
            guard workspace.apIPSaveID == saveID else { return }
            workspace.apIPSaveID = nil
            if saved && workspace.apIP == capturedDraft {
                workspace.apIP = address
                workspace.apIPStatus = NSLocalizedString("热点 IP 已保存", comment: "board hotspot address saved")
            }
        }
    }
}
