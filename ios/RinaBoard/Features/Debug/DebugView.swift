import SwiftUI
import RinaCore

/// Debug tab (FEATURE_INVENTORY §C): device overview, firmware health, power
/// panel, button simulator, test patterns, packed-frame lab, comms log, raw
/// command console, and the danger zone.
struct DebugView: View {
    @Environment(BoardConnection.self) private var connection
    @State private var vm = DebugViewModel()

    @State private var confirmResetMin = false
    @State private var confirmResetMax = false
    @State private var confirmAllOn = false
    @State private var confirmReboot = false
    @State private var confirmClearFaces = false

    var body: some View {
        NavigationStack {
            List {
                previewSection
                overviewSection
                healthSection
                powerSection
                wifiSummarySection
                buttonSimulatorSection
                testPatternSection
                packedFrameLabSection
                commsLogSection
                rawCommandSection
                dangerZoneSection
            }
            .navigationTitle("调试")
            .task { await vm.refreshStatus(connection: connection) }
            .onChange(of: connection.connectionState) { _, newValue in
                vm.log(.info, "连接状态: \(String(describing: newValue))")
            }
            .onChange(of: connection.currentFrame) { _, newValue in
                vm.syncDebugFrameWithLiveFrame(newValue)
            }
        }
    }

    // MARK: C1 preview

    @ViewBuilder
    private var previewSection: some View {
        Section("预览 (仅本地)") {
            LEDMatrixView(frame: vm.debugFrame, brightness: connection.status?.renderer?.brightness ?? 50)
                .frame(height: 220)
        }
    }

    // MARK: C2 device overview

    @ViewBuilder
    private var overviewSection: some View {
        Section("设备概览") {
            if vm.estimatedWatts > 40 {
                Label("估算功耗 \(String(format: "%.1f", vm.estimatedWatts)) W，超过 40 W 安全阈值", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LabeledContent("估算功耗", value: String(format: "%.2f W", vm.estimatedWatts))
            }
            if let info = vm.deviceInfo {
                LabeledContent("设备", value: info.device ?? "—")
                LabeledContent("固件版本", value: info.fw ?? "—")
                LabeledContent("LED 后端", value: info.ledBackend ?? "—")
                LabeledContent("堆内存", value: info.heapFree.map { "\($0) B" } ?? "—")
                LabeledContent("PSRAM", value: info.psramFree.map { "\($0) B" } ?? "—")
            }
            DisclosureGroup("完整状态字段 (\(vm.statusRows.count))") {
                ForEach(vm.statusRows, id: \.key) { row in
                    LabeledContent(row.key, value: row.value)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: C3 firmware health

    @ViewBuilder
    private var healthSection: some View {
        Section("固件健康") {
            HStack {
                Button("刷新状态") { Task { await vm.refreshStatus(connection: connection) } }
                Spacer()
                Button("刷新电源") { Task { await vm.refreshPower(connection: connection) } }
                Spacer()
                Button("获取信息") { Task { await vm.refreshDeviceInfo(connection: connection) } }
            }
            .buttonStyle(.bordered)
            HStack {
                Button("PING") { Task { await vm.pingBoard(connection: connection) } }
                    .buttonStyle(.bordered)
                Spacer()
                if let ms = vm.pingMs {
                    Text(String(format: "%.1f ms", ms)).foregroundStyle(.secondary)
                }
            }
            if let error = vm.lastLocalError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Button("清除错误") { vm.clearError() }
            Button("复制诊断 JSON") { vm.copyDiagnostics(connection: connection) }
            LabeledContent("命令发送/失败", value: "\(vm.commandsSent) / \(vm.commandsFailed)")
            LabeledContent("帧发送", value: "\(vm.framesSent)")
        }
    }

    // MARK: C4 power panel

    @ViewBuilder
    private var powerSection: some View {
        Section("电源面板") {
            if let power = connection.power {
                LabeledContent("读数正常", value: (power.ok ?? false) ? "是" : "否")
                LabeledContent("电池电压", value: power.vbat.map { String(format: "%.2f V", $0) } ?? "—")
                LabeledContent("充电电压", value: power.vcharge.map { String(format: "%.2f V", $0) } ?? "—")
                LabeledContent("电量百分比", value: power.batteryPercent.map { "\($0)%" } ?? "—")
                LabeledContent("正在充电", value: (power.charging ?? false) ? "是" : "否")
                LabeledContent("充电电压有效", value: (power.chargeValid ?? false) ? "是" : "否")
                LabeledContent("电池读数有效", value: (power.batteryValid ?? false) ? "是" : "否")
                LabeledContent("电池供电", value: (power.batteryPowered ?? false) ? "是" : "否")
                LabeledContent("电池已断开", value: (power.batteryDisconnected ?? false) ? "是" : "否")
                LabeledContent("低压且无外部电源", value: (power.batteryLowVoltageUnpowered ?? false) ? "是" : "否")
            } else {
                Text("暂无电源数据").foregroundStyle(.secondary)
            }
            Button("重置最低电压") { confirmResetMin = true }
            Button("重置最高电压") { confirmResetMax = true }
            DisclosureGroup("ADC 模拟(仅本地)") {
                HStack {
                    Text("原始值")
                    Spacer()
                    TextField("0-4095", value: $vm.simAdcRaw, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                HStack {
                    Text("参考电压")
                    Spacer()
                    TextField("3.3", value: $vm.simAdcRef, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                LabeledContent("计算电压", value: String(format: "%.3f V", vm.simADCVoltage))
            }
        }
        .confirmationDialog("重置最低电压？", isPresented: $confirmResetMin, titleVisibility: .visible) {
            Button("重置", role: .destructive) { Task { await vm.runCommand(.resetBatteryMin, connection: connection) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("重置最高电压？", isPresented: $confirmResetMax, titleVisibility: .visible) {
            Button("重置", role: .destructive) { Task { await vm.runCommand(.resetBatteryMax, connection: connection) } }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: C5 network summary (read-only; full panel lives in the Connection tab)

    @ViewBuilder
    private var wifiSummarySection: some View {
        Section("网络 (详见连接页)") {
            if let wifi = connection.wifi {
                LabeledContent("模式", value: wifi.mode ?? "—")
                LabeledContent("SSID", value: wifi.ssid ?? "—")
                LabeledContent("IP", value: wifi.ip ?? "—")
                LabeledContent("热点", value: (wifi.apActive ?? false) ? "开启" : "关闭")
                LabeledContent("客户端数", value: wifi.clients.map(String.init) ?? "—")
            } else {
                Text("暂无网络数据").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: C6 button simulator

    @ViewBuilder
    private var buttonSimulatorSection: some View {
        Section("按键模拟") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                simButton("B1 下一个") { await vm.runCommand(.button(button: "B1"), connection: connection) }
                simButton("B2 上一个") { await vm.runCommand(.button(button: "B2"), connection: connection) }
                simButton("B3 A/M") { await vm.runCommand(.button(button: "B3"), connection: connection) }
                simButton("B4 亮度−") { await vm.runCommand(.button(button: "B4"), connection: connection) }
                simButton("B5 亮度+") { await vm.runCommand(.button(button: "B5"), connection: connection) }
                simButton("B3B1 间隔−") { await vm.runCommand(.button(button: "B3B1"), connection: connection) }
                simButton("B3B2 间隔+") { await vm.runCommand(.button(button: "B3B2"), connection: connection) }
                simButton("B6 短按(电量)") { await vm.runCommand(.batteryOverlay(singleShot: true), connection: connection) }
                simButton("B6 长按(详情)") { await vm.runCommand(.batteryOverlay(singleShot: false), connection: connection) }
                simButton("暂停滚动") { await vm.runCommand(.pauseScroll, connection: connection) }
            }
            .padding(.vertical, 4)
        }
    }

    private func simButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .buttonStyle(.bordered)
            .font(.caption)
    }

    // MARK: C7/C8 test patterns

    @ViewBuilder
    private var testPatternSection: some View {
        Section("测试图案") {
            VStack(alignment: .leading, spacing: 6) {
                Text("预览").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([DebugPattern.off, .checker, .border, .saved]) { pattern in
                        Button(pattern.label) { vm.previewPattern(pattern, connection: connection) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
                Text("发送到设备").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([DebugPattern.off, .allOn, .checker, .border, .saved]) { pattern in
                        Button(pattern.label) {
                            if pattern == .allOn {
                                confirmAllOn = true
                            } else {
                                Task { await vm.sendPattern(pattern, connection: connection) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                    }
                }
            }
        }
        .confirmationDialog(
            "全亮会点亮全部 370 颗 LED，估算功耗可能超过 40 W，确定发送？",
            isPresented: $confirmAllOn, titleVisibility: .visible
        ) {
            Button("发送全亮", role: .destructive) { Task { await vm.sendPattern(.allOn, connection: connection) } }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: C9 packed-frame lab

    @ViewBuilder
    private var packedFrameLabSection: some View {
        Section("封包帧实验室") {
            TextEditor(text: $vm.packedLabText)
                .frame(height: 100)
                .font(.system(.caption, design: .monospaced))
                .overlay(alignment: .topLeading) {
                    if vm.packedLabText.isEmpty {
                        Text("94 位十六进制 / 47 项整数 JSON 数组 / base64")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
            if let error = vm.packedLabError {
                Text(error).foregroundStyle(.red).font(.caption)
            } else if vm.packedLabValid != nil {
                Text("有效帧 (\(vm.packedLabValid?.litCount ?? 0) 颗点亮)").foregroundStyle(.green).font(.caption)
            }
            HStack {
                Button("校验") { vm.parsePackedLab() }
                Button("解析为预览") { vm.parsePackedLab(); vm.applyPackedLabToPreview() }
                Button("解析并发送") { vm.parsePackedLab(); Task { await vm.sendPackedLab(connection: connection) } }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            HStack {
                Button("清空") { vm.packedLabText = ""; vm.packedLabValid = nil; vm.packedLabError = nil }
                Button("复制预览帧") { vm.copyPreviewFrame() }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    // MARK: C10 comms log

    @ViewBuilder
    private var commsLogSection: some View {
        Section("通信日志") {
            Picker("级别", selection: $vm.logFilter) {
                ForEach(DebugLogFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            Toggle("固件日志 (log_subscribe)", isOn: Binding(
                get: { vm.firmwareLogSubscribed },
                set: { newValue in vm.setFirmwareLogSubscribed(newValue, connection: connection) }
            ))

            ForEach(vm.visibleLogs) { entry in
                HStack(alignment: .top) {
                    Text(entry.timeString).font(.caption2).foregroundStyle(.secondary)
                    Text(entry.level.label).font(.caption2).foregroundStyle(color(for: entry.level))
                    Text(entry.message).font(.caption)
                }
            }
            HStack {
                Button("清空") { vm.clearLog() }
                Button("复制") { vm.copyLog() }
                ShareLink(item: vm.logShareText) {
                    Text("分享")
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    private func color(for level: DebugLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    // MARK: C11 raw command

    @ViewBuilder
    private var rawCommandSection: some View {
        Section("原始指令") {
            TextEditor(text: $vm.rawCommandText)
                .frame(height: 80)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: vm.rawCommandText) { _, _ in vm.validateRawCommand() }
            Text(vm.rawCommandValid ? "JSON 有效" : "JSON 无效")
                .font(.caption)
                .foregroundStyle(vm.rawCommandValid ? .green : .red)
            Button("校验 JSON") { vm.validateRawCommand() }
                .buttonStyle(.bordered)
                .font(.caption)
            Toggle("我确认发送原始指令", isOn: $vm.rawCommandConfirmed)
            Button("发送") { Task { await vm.sendRawCommand(connection: connection) } }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.rawCommandValid || !vm.rawCommandConfirmed)
            if !vm.rawCommandResult.isEmpty {
                Text(vm.rawCommandResult)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: C12 danger zone

    @ViewBuilder
    private var dangerZoneSection: some View {
        Section("危险操作") {
            Button("清空用户表情", role: .destructive) {
                vm.clearFacesConfirmText = ""
                confirmClearFaces = true
            }
            Button("重启设备", role: .destructive) { confirmReboot = true }
        }
        .alert("清空用户表情", isPresented: $confirmClearFaces) {
            TextField("输入 CLEAR 以确认", text: $vm.clearFacesConfirmText)
            Button("确认清空", role: .destructive) {
                if vm.clearFacesConfirmText == "CLEAR" {
                    Task { await vm.clearUserFaces(connection: connection) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除所有非默认表情，且不可撤销。输入 CLEAR 确认。")
        }
        .confirmationDialog("确定要重启设备吗？", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("重启", role: .destructive) { Task { await vm.reboot(connection: connection) } }
            Button("取消", role: .cancel) {}
        }
    }
}

#Preview {
    DebugView()
        .environment(BoardConnection())
}
