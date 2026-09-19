import SwiftUI
import RinaCore

/// "Wi-Fi 与热点" category: the selected board's own network settings
/// (`wifi_*` over the active transport, RINALINK_PROTOCOL_V1 §8) — which
/// network it joins, the iPhone hotspot it falls back to and its SoftAP.
struct BoardNetworkSettingsView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Bindable private var workspace: SettingsWorkspace
    @Bindable private var viewModel: ConnectionViewModel

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
                phoneHotspotSection
                boardHotspotSection
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("Wi-Fi 与热点")
        .errorAlert(workspace.connectionError(for: .network))
        // The password sheet is attached in `SettingsView`, above the layout
        // switch, so a resize cannot dismiss it.
    }

    // MARK: Status

    /// Mode plus everything the board reports about its links, once.
    @ViewBuilder
    private var statusSection: some View {
        Section {
            Picker("模式", selection: modeBinding) {
                Text("关闭").tag("off")
                Text("仅热点").tag("ap")
                Text("家庭 Wi-Fi").tag("sta")
                Text("家庭 Wi-Fi（热点备用）").tag("sta_or_ap")
            }
            .disabled(!isConnected)

            if let wifi = connection.wifi {
                LabeledContent("已连接网络", value: (wifi.staConnected == true ? wifi.ssid : nil) ?? "无")
                LabeledContent("当前使用", value: profileLabel(wifi.activeProfile))
                LabeledContent("IP", value: wifi.ip ?? "—")
                LabeledContent("信号", value: wifi.rssi.map { "\($0) dBm" } ?? "—")
                LabeledContent("热点状态", value: wifi.apActive == true ? "开启" : "关闭")
                if let apIp = wifi.apIp { LabeledContent("热点 IP", value: apIp) }
            }
        } header: {
            Text("板载 Wi-Fi 设置")
        } footer: {
            if !isConnected {
                Text("连接璃奈板后可修改这些设置。")
            }
        }
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { connection.wifi?.mode ?? "sta_or_ap" },
            set: { newValue in workspace.run(from: .network) { await viewModel.setMode(newValue, connection: connection) } }
        )
    }

    private func profileLabel(_ profile: String?) -> String {
        switch profile {
        case "home": return "家庭"
        case "hotspot": return "手机热点"
        default: return "无"
        }
    }

    // MARK: Home network

    @ViewBuilder
    private var joinNetworkSection: some View {
        Section {
            if let wifi = connection.wifi {
                LabeledContent("家庭网络", value: wifi.homeSsid ?? "无")
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

    // MARK: iPhone 热点

    @ViewBuilder
    private var phoneHotspotSection: some View {
        Section("iPhone 热点") {
            if let wifi = connection.wifi {
                LabeledContent("手机热点", value: wifi.hotspotSsid ?? "无")
            }

            TextField("热点名称", text: $viewModel.hotspotName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField(viewModel.hotspotPassword.isEmpty ? "热点密码" : "使用已保存的密码", text: $viewModel.hotspotPassword)

            Button {
                workspace.run(from: .network) { await viewModel.provisionPhoneHotspot(connection: connection, boardStore: boardStore) }
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

            Button("清除", role: .destructive) {
                workspace.run(from: .network) { await viewModel.clearPhoneHotspot(connection: connection) }
            }
            .disabled(!isConnected)
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
                workspace.run(from: .network) { await viewModel.setAp(ssid: workspace.apSSID, password: workspace.apPassword, connection: connection, boardStore: boardStore) }
            }
            .disabled(workspace.apSSID.isEmpty)
        } header: {
            Text("热点名称与密码")
        }
        .disabled(!isConnected)
    }
}
