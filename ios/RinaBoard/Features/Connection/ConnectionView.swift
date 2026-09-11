import SwiftUI
import RinaCore

/// Connection tab (FEATURE_INVENTORY §E): status card, BLE scan/connect,
/// home Wi-Fi (Bonjour + manual host), hotspot join, and on-board Wi-Fi
/// provisioning (`wifi_*` over the active transport).
struct ConnectionView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Environment(BLETransport.self) private var bleTransport
    @State private var viewModel = ConnectionViewModel()

    @State private var networkForPassword: WifiNetwork?
    @State private var passwordInput = ""
    @State private var apSSID = ""
    @State private var apPassword = ""

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                bluetoothSection
                homeWifiSection
                hotspotSection
                phoneHotspotSection
                boardWifiSection
            }
            .navigationTitle("连接")
            .alert("出错了", isPresented: errorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.lastErrorMessage ?? "")
            }
            .sheet(item: $networkForPassword) { network in
                passwordSheet(for: network)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { viewModel.lastErrorMessage != nil }, set: { if !$0 { viewModel.lastErrorMessage = nil } })
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        Section("状态") {
            LabeledContent("传输方式", value: transportLabel)
            LabeledContent("状态", value: stateLabel)
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
                    Button("断开", role: .destructive) { connection.disconnect() }
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

    // MARK: Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        Section("蓝牙") {
            Toggle("扫描附近的璃奈板", isOn: Binding(
                get: { viewModel.isScanningBLE },
                set: { _ in viewModel.toggleBLEScan(ble: bleTransport) }
            ))
            ForEach(bleTransport.discoveredPeripherals) { peripheral in
                Button {
                    Task { await viewModel.connectBLE(peripheral, ble: bleTransport, connection: connection, boardStore: boardStore) }
                } label: {
                    HStack {
                        Text(peripheral.name)
                        Spacer()
                        Text("\(peripheral.rssi) dBm").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Home Wi-Fi

    @ViewBuilder
    private var homeWifiSection: some View {
        Section("家庭 Wi-Fi") {
            ForEach(viewModel.bonjour.boards) { board in
                Button {
                    Task { await viewModel.connectBonjour(board, connection: connection, boardStore: boardStore) }
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
                    Task { await viewModel.connectManualHost(connection: connection, boardStore: boardStore) }
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
                Task { await viewModel.connectHotspot(connection: connection, boardStore: boardStore) }
            } label: {
                if viewModel.isJoiningHotspot {
                    ProgressView()
                } else {
                    Text("加入璃奈板热点并连接")
                }
            }
            .disabled(viewModel.isJoiningHotspot)

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
            Text("1. 打开 设置 › 个人热点 并开启「允许其他人加入」\n2. 在下方填写热点名称与密码\n3. 点击发送")
                .font(.footnote)
                .foregroundStyle(.secondary)

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

            if let status = viewModel.hotspotStatusText {
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

    // MARK: Board Wi-Fi settings

    @ViewBuilder
    private var boardWifiSection: some View {
        Section("板载 Wi-Fi 设置") {
            Picker("模式", selection: modeBinding) {
                Text("关闭").tag("off")
                Text("仅热点").tag("ap")
                Text("家庭 Wi-Fi").tag("sta")
                Text("家庭 Wi-Fi + 热点备用").tag("sta_or_ap")
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

            ForEach(viewModel.wifiNetworks) { network in
                Button {
                    networkForPassword = network
                    passwordInput = ""
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
                TextField("SSID", text: $apSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码 (留空为开放网络)", text: $apPassword)
                Button("保存") {
                    Task { await viewModel.setAp(ssid: apSSID, password: apPassword, connection: connection) }
                }
                .disabled(apSSID.isEmpty)
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

    @ViewBuilder
    private func passwordSheet(for network: WifiNetwork) -> some View {
        NavigationStack {
            Form {
                Section(network.ssid) {
                    if network.secure {
                        SecureField("密码", text: $passwordInput)
                    } else {
                        Text("开放网络，无需密码")
                    }
                }
            }
            .navigationTitle("连接网络")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { networkForPassword = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        let ssid = network.ssid
                        let password = passwordInput
                        networkForPassword = nil
                        Task { await viewModel.connectNetwork(ssid: ssid, password: password, connection: connection) }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// No #Preview: ConnectionView requires a live BLETransport (backed by a real
// CBCentralManager), which isn't safe/meaningful to construct in the
// Xcode Previews sandbox.
