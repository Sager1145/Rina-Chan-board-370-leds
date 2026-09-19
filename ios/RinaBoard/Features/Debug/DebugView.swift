import SwiftUI
import RinaCore

/// Focused diagnostics: board snapshot, event history, test tools, then raw data.
struct DebugView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BootLoaderModel.self) private var bootLoader
    /// The model, the selected workspace and the open confirmations live in
    /// the app-scoped Settings workspace: a resize that swaps the Settings
    /// layout rebuilds this page, and must not drop the terminal, the log or
    /// a dialog the user is answering.
    @Bindable private var settings: SettingsWorkspace
    @Bindable private var vm: DebugViewModel

    /// Shown beside the sidebar without the user having opened it: sends
    /// nothing to the board.
    private let isPassive: Bool

    init(workspace: SettingsWorkspace, isPassive: Bool = false) {
        settings = workspace
        vm = workspace.debug
        self.isPassive = isPassive
    }

    private var isConnected: Bool { connection.connectionState == .connected }

    /// Identifies one board session: the connection object changes when the
    /// active board changes, and its generation changes when the same board
    /// reconnects. Keying the overview task on both means diagnostics follow
    /// the board instead of staying on whichever one was showing first.
    private var sessionKey: String {
        "\(ObjectIdentifier(connection).hashValue)-\(connection.connectionGeneration)"
    }

    var body: some View {
        List {
            Group {
                switch settings.debugWorkspace {
                case 1: logSection
                case 2: testSection
                case 3: rawDataSection
                case 4: DebugSerialMonitor(vm: vm)
                default: overviewSection
                }
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("调试")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($vm.lastLocalError)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("调试工作区", selection: $settings.debugWorkspace) {
                Text("概览").tag(0)
                Text("日志").tag(1)
                Text("测试").tag(2)
                Text("原始数据").tag(3)
                Text("终端").tag(4)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("debug.workspace")
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        // The model outlives this page, so being rebuilt by a Settings
        // layout change is not a new session and does not reload what is
        // already fresh.
        .task(id: "\(sessionKey)-\(isPassive)") {
            guard !isPassive else { return }
            await vm.pageAppeared(sessionKey: sessionKey, connection: connection)
        }
        .refreshable { await vm.refreshOverview(connection: connection) }
        .onChange(of: connection.connectionState) { _, state in
            vm.handleConnectionStateChange(state)
        }
        .onChange(of: connection.currentFrame) { _, frame in
            vm.syncDebugFrameWithLiveFrame(frame)
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        Section {
            HStack {
                Text("连接")
                Spacer()
                Label(connectionLabel, systemImage: connectionSymbol)
                    .foregroundStyle(connectionColor)
            }
            .accessibilityElement(children: .combine)

            if vm.isRefreshingOverview {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取面板快照…").foregroundStyle(.secondary)
                }
            }

            LabeledContent("设备", value: vm.deviceInfo?.device ?? vm.statusSnapshot?.device ?? "未知")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 16) {
                metric("播放", value: vm.statusSnapshot?.renderer?.playback ?? "未知", symbol: "play.circle")
                metric("亮度", value: vm.statusSnapshot?.renderer?.brightness.map(String.init) ?? "未知", symbol: "sun.max")
                metric("点亮 LED", value: vm.statusSnapshot?.renderer?.lit.map(String.init) ?? "未知", symbol: "lightbulb")
                metric("电池", value: vm.powerSnapshot?.batteryPercent.map { "\($0)%" } ?? "未知", symbol: "battery.100percent")
            }
            .padding(.vertical, 6)

            DisclosureGroup("硬件与网络详情") {
                LabeledContent("固件", value: vm.deviceInfo?.fw ?? "未知")
                LabeledContent("LED 后端", value: vm.deviceInfo?.ledBackend ?? vm.statusSnapshot?.renderer?.ledBackend ?? "未知")
                LabeledContent("构建", value: vm.deviceInfo?.build ?? "未知")
                LabeledContent("空闲堆内存", value: vm.deviceInfo?.heapFree.map { "\($0) B" } ?? "未知")
                LabeledContent("空闲 PSRAM", value: vm.deviceInfo?.psramFree.map { "\($0) B" } ?? "未知")
                LabeledContent("网络模式", value: vm.statusSnapshot?.wifi?.mode ?? "未知")
                LabeledContent("SSID", value: vm.statusSnapshot?.wifi?.ssid ?? "未知")
                LabeledContent("IP", value: vm.statusSnapshot?.wifi?.ip ?? "未知")
                LabeledContent("热点已开启", value: DebugViewModel.triState(vm.statusSnapshot?.wifi?.apActive))
            }

            if let power = vm.powerSnapshot {
                LabeledContent("电池电压", value: power.vbat.map { String(format: "%.2f V", $0) } ?? "未知")
                LabeledContent("正在充电", value: DebugViewModel.triState(power.charging))
                DisclosureGroup("电源详情") {
                    LabeledContent("读数正常", value: DebugViewModel.triState(power.ok))
                    LabeledContent("充电电压", value: power.vcharge.map { String(format: "%.2f V", $0) } ?? "未知")
                    LabeledContent("充电电压有效", value: DebugViewModel.triState(power.chargeValid))
                    LabeledContent("电池读数有效", value: DebugViewModel.triState(power.batteryValid))
                    LabeledContent("电池供电", value: DebugViewModel.triState(power.batteryPowered))
                    LabeledContent("电池已断开", value: DebugViewModel.triState(power.batteryDisconnected))
                    LabeledContent("低压且无外部电源", value: DebugViewModel.triState(power.batteryLowVoltageUnpowered))
                }
            } else {
                LabeledContent("电源", value: "未采样")
            }

            if let watts = vm.estimatedWatts {
                Label {
                    LabeledContent("客户端估算功耗", value: String(format: "%.2f W", watts))
                } icon: {
                    Image(systemName: watts > 40 ? "exclamationmark.triangle.fill" : "bolt.fill")
                        .foregroundStyle(watts > 40 ? .red : .secondary)
                }
            } else {
                LabeledContent("客户端估算功耗", value: "输入不足")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(vm.freshnessText(for: vm.statusUpdatedAt, connected: isConnected))
                if vm.powerUpdatedAt != vm.statusUpdatedAt {
                    Text("电源：\(vm.freshnessText(for: vm.powerUpdatedAt, connected: isConnected))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("刷新全部") { Task { await vm.refreshOverview(connection: connection) } }
                    .disabled(!isConnected || vm.isRefreshingOverview)
                Spacer()
                Button("PING") { Task { await vm.pingBoard(connection: connection) } }
                    .disabled(!isConnected)
                if let ms = vm.pingMs {
                    Text(String(format: "%.1f ms", ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.pill)

            DisclosureGroup("本次调试会话") {
                LabeledContent("命令尝试", value: "\(vm.commandAttempts)")
                LabeledContent("设备拒绝", value: "\(vm.commandRejected)")
                LabeledContent("通信失败", value: "\(vm.commandFailures)")
                LabeledContent("帧尝试 / 失败", value: "\(vm.frameAttempts) / \(vm.frameFailures)")
                Text("仅统计从本页发起的操作；不代表设备或整个 App 的累计通信量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("复制诊断摘要") { vm.copyDiagnostics(connection: connection) }
        } header: {
            Text("概览")
        } footer: {
            Text("读数来自最近一次 GET_STATUS、GET_POWER 与 get_info；功耗由状态中的点亮数、亮度和颜色在本机估算。")
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Logs

    private var logSection: some View {
        Section {
            TextField("搜索日志", text: $vm.logSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("来源", selection: $vm.logSource) {
                Text("全部").tag(nil as DebugLogSource?)
                ForEach(DebugLogSource.allCases) { source in
                    Text(source.label).tag(source as DebugLogSource?)
                }
            }
            .pickerStyle(.segmented)

            Picker("最低级别", selection: $vm.logFilter) {
                ForEach(DebugLogFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }

            Toggle("暂停列表更新", isOn: $vm.isLogDisplayPaused)
            firmwareLogControl

            if vm.visibleLogs.isEmpty {
                ContentUnavailableView("没有匹配的日志", systemImage: "text.magnifyingglass")
            } else {
                ForEach(vm.visibleLogs) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(entry.timeString)
                            Text(entry.source.label)
                            Text(entry.level.label)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            HStack {
                Button("清空") { vm.clearLog() }
                Button("复制脱敏日志") { vm.copyLog() }
                ShareLink(item: vm.logShareText) { Text("分享脱敏日志") }
            }
            .buttonStyle(.pill)
        } header: {
            Text("日志")
        } footer: {
            Text(vm.isLogDisplayPaused
                 ? "列表已冻结，日志仍在后台收集。复制和分享会隐藏密码、令牌等敏感字段。"
                 : "应用日志记录本页操作；固件日志来自 EV_LOG。这里不是完整的收发数据包跟踪。")
        }
    }

    @ViewBuilder
    private var firmwareLogControl: some View {
        switch vm.firmwareLogState {
        case .off:
            Button("开始接收固件日志") { vm.setFirmwareLogSubscribed(true, connection: connection) }
                .disabled(!isConnected)
        case .subscribing:
            HStack {
                ProgressView()
                Text("正在订阅固件日志…")
                Spacer()
                Button("取消") { vm.setFirmwareLogSubscribed(false, connection: connection) }
            }
        case .on:
            HStack {
                Label("正在接收固件日志", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Spacer()
                Button("停止") { vm.setFirmwareLogSubscribed(false, connection: connection) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("固件日志不可用：\(message)", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("重试") { vm.setFirmwareLogSubscribed(true, connection: connection) }
                    .disabled(!isConnected)
            }
        }
    }

    // MARK: - Test tools

    private var testSection: some View {
        Section {
            patternTool
            buttonSimulator
            packedFrameLab
            powerMaintenance

            DisclosureGroup("App 工具") {
                Button("重新播放启动动画") { bootLoader.replay() }
                Text("只在当前 App 中重放启动动画，不向面板发送数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("危险操作") {
                Button("清空用户表情", role: .destructive) {
                    vm.clearFacesConfirmText = ""
                    settings.confirmDebugClearFaces = true
                }
                Button("重启此面板", role: .destructive) { settings.confirmBoardReboot = true }
            }
        } header: {
            Text("测试")
        } footer: {
            Text("选择图案仅更新本机预览；发送、按键模拟和维护操作会直接控制面板。")
        }
        // The confirmations are attached in `SettingsView`, above the layout
        // switch, so a resize cannot dismiss them.
    }

    private var patternTool: some View {
        DisclosureGroup("测试图案") {
            Picker("图案", selection: $vm.selectedPattern) {
                Text("选择图案…").tag(nil as DebugPattern?)
                ForEach(DebugPattern.allCases) { pattern in
                    Text(pattern.label).tag(pattern as DebugPattern?)
                }
            }
            .onChange(of: vm.selectedPattern) { _, pattern in
                if let pattern { vm.previewPattern(pattern, connection: connection) }
            }

            BoardPreviewRow(frame: vm.debugFrame,
                            color: .rinaPink,
                            brightness: vm.statusSnapshot?.renderer?.brightness ?? 50)

            Button("发送当前预览") {
                guard let pattern = vm.selectedPattern else { return }
                if pattern == .allOn {
                    settings.confirmDebugAllOn = true
                } else {
                    Task { await vm.sendPattern(pattern, connection: connection) }
                }
            }
            .buttonStyle(.pill)
            .disabled(vm.selectedPattern == nil || !isConnected)
        }
    }

    private var buttonSimulator: some View {
        DisclosureGroup("按键模拟") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 8) {
                simButton("B1 下一个", .button(button: "B1"))
                simButton("B2 上一个", .button(button: "B2"))
                simButton("B3 自动/手动", .button(button: "B3"))
                simButton("B4 亮度−", .button(button: "B4"))
                simButton("B5 亮度+", .button(button: "B5"))
                simButton("B3B1 间隔−", .button(button: "B3B1"))
                simButton("B3B2 间隔+", .button(button: "B3B2"))
                simButton("B6 电量", .batteryOverlay(singleShot: true))
                simButton("B6 详情", .batteryOverlay(singleShot: false))
                simButton("暂停滚动", .pauseScroll)
            }
            .padding(.vertical, 4)
        }
    }

    private func simButton(_ title: String, _ command: RinaCommand) -> some View {
        Button(LocalizedStringKey(title)) { Task { await vm.runCommand(command, connection: connection) } }
            .buttonStyle(.pill)
            .disabled(!isConnected)
    }

    private var packedFrameLab: some View {
        DisclosureGroup("帧数据测试") {
            TextEditor(text: $vm.packedLabText)
                .frame(minHeight: 96)
                .font(.system(.caption, design: .monospaced))
                .overlay(alignment: .topLeading) {
                    if vm.packedLabText.isEmpty {
                        Text("94 个十六进制字符 / 47 项整数 JSON 数组 / Base64")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            if let error = vm.packedLabError {
                Label(error, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let frame = vm.packedLabValid {
                Label("有效帧，点亮 \(frame.litCount) 颗", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            HStack {
                Button("校验") { vm.parsePackedLab() }
                Button("预览") { vm.parsePackedLab(); vm.applyPackedLabToPreview() }
                Button("发送") { vm.parsePackedLab(); Task { await vm.sendPackedLab(connection: connection) } }
                    .disabled(!isConnected)
            }
            .buttonStyle(.pill)
            Button("复制预览帧") { vm.copyPreviewFrame() }
        }
    }

    private var powerMaintenance: some View {
        DisclosureGroup("电源维护与 ADC 模拟") {
            Button("重置最低电压") { settings.confirmDebugResetMin = true }.disabled(!isConnected)
            Button("重置最高电压") { settings.confirmDebugResetMax = true }.disabled(!isConnected)
            LabeledContent("ADC 原始值") {
                TextField("0–4095", value: $vm.simAdcRaw, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("参考电压") {
                TextField("3.3", value: $vm.simAdcRef, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("本地计算电压", value: String(format: "%.3f V", vm.simADCVoltage))
            Text("ADC 模拟只在本机计算，不读取或修改面板。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Raw data

    private var rawDataSection: some View {
        Section {
            TextField("搜索字段、值或来源", text: $vm.rawFieldSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            DisclosureGroup("原始字段（\(vm.filteredRawRows.count)）") {
                if vm.filteredRawRows.isEmpty {
                    Text("没有匹配字段").foregroundStyle(.secondary)
                } else {
                    ForEach(vm.filteredRawRows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.source) · \(row.key)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(row.value)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            DisclosureGroup("原始 JSON") {
                rawJSONBlock("GET_STATUS", vm.statusRawText)
                rawJSONBlock("GET_POWER", vm.powerRawText)
                Button("复制脱敏快照") { vm.copyRawSnapshots() }
            }

        } header: {
            Text("原始数据")
        } footer: {
            Text("字段直接来自固件回复，包含当前 App 尚未建模的未知键。发送指令请使用「终端」。")
        }
    }

    private func rawJSONBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Text(text.isEmpty ? "未采样" : text)
                .font(.caption2.monospaced())
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    private var connectionLabel: String {
        switch connection.connectionState {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reconnecting(let attempt): return "重连中 · 第 \(attempt) 次"
        case .failed(let message): return "失败 · \(message)"
        }
    }

    private var connectionSymbol: String {
        switch connection.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "circle.dashed"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch connection.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}

#Preview {
    NavigationStack {
        DebugView(workspace: SettingsWorkspace())
            .environment(BoardConnection())
            .environment(BootLoaderModel())
    }
}
