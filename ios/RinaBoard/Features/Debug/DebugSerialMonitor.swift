import SwiftUI
import RinaCore

struct DebugMonitorRequest {
    let type: RinaLinkMessageType
    let payload: Data
    /// The `cmd` being sent; `nil` for the frame-level queries.
    var commandName: String?

    var isDestructive: Bool {
        commandName.map(DebugCommandCatalog.isDestructive(commandName:)) ?? false
    }

    static func parse(_ text: String) throws -> Self {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch input.uppercased() {
        case "PING": return Self(type: .ping, payload: Data())
        case "GET_STATUS": return Self(type: .getStatus, payload: Data("{}".utf8))
        case "GET_POWER": return Self(type: .getPower, payload: Data())
        default: break
        }
        if input.first == "{" {
            let data = Data(input.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["cmd"] as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParseError.invalidCommand
            }
            return Self(type: .cmd, payload: data,
                        commandName: command.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !input.isEmpty, input.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw ParseError.invalidCommand
        }
        return Self(type: .cmd, payload: try JSONSerialization.data(withJSONObject: ["cmd": input]),
                    commandName: input)
    }

    enum ParseError: LocalizedError {
        case invalidCommand
        var errorDescription: String? {
            NSLocalizedString("请输入指令名，或包含 cmd 字段的 JSON 对象。", comment: "monitor invalid input")
        }
    }
}

struct DebugSerialMonitor: View {
    @Environment(BoardConnection.self) private var connection
    @Bindable var vm: DebugViewModel
    @State private var showCommands = false
    @State private var commandSearch = ""

    private var commands: [DebugCommandTemplate] {
        let query = commandSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = DebugCommandCatalog.commands
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var inputIsDestructive: Bool {
        (try? DebugMonitorRequest.parse(vm.monitorInput))?.isDestructive ?? false
    }

    var body: some View {
        Section {
            SwapLabel(connection.connectionState == .connected ? "已连接" : "未连接",
                      systemImage: connection.connectionState == .connected ? "checkmark.circle.fill" : "circle.dashed")
            TextField("指令名或 JSON", text: $vm.monitorInput, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("debug.monitor.input")
            if inputIsDestructive {
                Toggle("我已检查内容，确认发送此指令", isOn: $vm.monitorDestructiveConfirmed)
                    .accessibilityIdentifier("debug.monitor.confirm")
            }
            Button {
                Task { await vm.sendMonitorCommand(connection: connection) }
            } label: {
                SwapLabel(vm.isMonitorSending ? "正在发送…" : "发送指令", systemImage: "paperplane")
            }
            .buttonStyle(.pill)
            .disabled(connection.connectionState != .connected || vm.isMonitorSending
                      || vm.monitorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || (inputIsDestructive && !vm.monitorDestructiveConfirmed))
            .accessibilityIdentifier("debug.monitor.send")
            Toggle("显示全部可用指令", isOn: $showCommands)
                .accessibilityIdentifier("debug.monitor.commands")
        } header: {
            Text("命令终端")
        } footer: {
            Text("通过当前蓝牙／Wi-Fi 连接发送 RinaLink 指令。带参数的指令请使用 JSON；USB 串口命令不适用于此页面。")
        }

        if showCommands {
            Section {
                TextField("搜索指令", text: $commandSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("可用指令")
            } footer: {
                Text("列出当前项目固件支持的全部 CMD 指令及常用查询。点选示例后可修改参数，再发送；设备实际支持情况取决于固件版本。")
            }
            let matches = commands
            ForEach(DebugCommandGroup.allCases) { group in
                let templates = matches.filter { $0.group == group }
                if !templates.isEmpty {
                    Section(group.title) {
                        ForEach(templates) { command in
                            Button {
                                vm.monitorInput = command.example
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(command.name).font(.subheadline.monospaced().weight(.semibold))
                                    Text(command.example).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }

        Section {
            Toggle("接收固件日志", isOn: Binding(
                get: { vm.firmwareLogState == .on || vm.firmwareLogState == .subscribing },
                set: { vm.setFirmwareLogSubscribed($0, connection: connection) }
            ))
            .disabled(connection.connectionState != .connected)
            if case .failed(let message) = vm.firmwareLogState {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("清空") { vm.clearMonitor() }
                Spacer()
                Button("复制脱敏日志") { vm.copyMonitor() }
                    .disabled(vm.isMonitorEntriesEmpty)
            }
            .buttonStyle(.pill)
            if vm.isMonitorEntriesEmpty {
                Text("发送指令后，回复将显示在这里。")
                    .foregroundStyle(.secondary)
            }
            // Materialize the ring buffer once per body pass instead of
            // reading `vm.monitorEntries` (O(n)) multiple times.
            let monitorEntries = vm.monitorEntries
            ForEach(monitorEntries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.timeString).font(.caption2).foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(entry.level == .error || entry.level == .warn ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("收发记录（最新在前）")
        }
    }
}
