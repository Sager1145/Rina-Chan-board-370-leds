import Foundation
import UIKit
import RinaCore

// MARK: - Comms log (C10)

enum DebugLogLevel: Int, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    static func < (lhs: DebugLogLevel, rhs: DebugLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug: return "详细"
        case .info: return "信息"
        case .warn: return "警告"
        case .error: return "错误"
        }
    }
}

struct DebugLogEntry: Identifiable {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    let id = UUID()
    let date = Date()
    let level: DebugLogLevel
    let message: String

    var timeString: String { Self.timeFormatter.string(from: date) }
}

enum DebugLogFilter: String, CaseIterable, Identifiable {
    case errorsOnly = "仅错误"
    case warnAndUp = "警告以上"
    case normal = "正常"
    case verbose = "详细"

    var id: String { rawValue }

    var minLevel: DebugLogLevel {
        switch self {
        case .errorsOnly: return .error
        case .warnAndUp: return .warn
        case .normal: return .info
        case .verbose: return .debug
        }
    }
}

// MARK: - JSON helpers

enum DebugJSON {
    static func prettyString(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    static func prettyString(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return prettyString(from: obj)
    }

    /// Flattens an arbitrary JSON document into dot-path key/value rows, used
    /// for the Debug device-overview grid (C2) so every field the firmware
    /// returns is visible, not just the ones `DeviceStatus` declares.
    static func flatten(_ data: Data) -> [(key: String, value: String)] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rows: [(String, String)] = []
        flattenValue(obj, prefix: "", into: &rows)
        return rows
    }

    private static func flattenValue(_ value: Any, prefix: String, into rows: inout [(String, String)]) {
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() {
                let newPrefix = prefix.isEmpty ? key : "\(prefix).\(key)"
                flattenValue(dict[key] ?? NSNull(), prefix: newPrefix, into: &rows)
            }
        } else if let arr = value as? [Any] {
            let hasContainer = arr.contains { $0 is [String: Any] || $0 is [Any] }
            if hasContainer {
                for (i, v) in arr.enumerated() {
                    flattenValue(v, prefix: "\(prefix)[\(i)]", into: &rows)
                }
            } else {
                rows.append((prefix, arr.map { "\($0)" }.joined(separator: ", ")))
            }
        } else if value is NSNull {
            rows.append((prefix, "—"))
        } else {
            rows.append((prefix, "\(value)"))
        }
    }
}

// MARK: - Test pattern generation (C7/C8)

enum DebugPattern: String, CaseIterable, Identifiable {
    case off, checker, border, saved, allOn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "全黑"
        case .checker: return "棋盘"
        case .border: return "边框"
        case .saved: return "当前保存表情"
        case .allOn: return "全亮"
        }
    }

    var sendReason: String {
        switch self {
        case .off: return "debug_off"
        case .allOn: return "debug_on"
        case .checker: return "debug_checker"
        case .border: return "debug_border"
        case .saved: return "debug_saved"
        }
    }

    func frame(savedFrame: PackedFrame) -> PackedFrame {
        var f = PackedFrame()
        switch self {
        case .off:
            break
        case .allOn:
            f.fill()
        case .checker:
            for y in 0..<MatrixGeometry.rows {
                guard let xr = MatrixGeometry.validXRange(row: y) else { continue }
                for x in xr where (x + y) % 2 == 0 {
                    if let idx = MatrixGeometry.ledIndex(x: x, y: y) { f.set(idx) }
                }
            }
        case .border:
            for y in 0..<MatrixGeometry.rows {
                guard let xr = MatrixGeometry.validXRange(row: y) else { continue }
                for x in xr {
                    let onEdge = x == xr.lowerBound || x == xr.upperBound || y == 0 || y == MatrixGeometry.rows - 1
                    if onEdge, let idx = MatrixGeometry.ledIndex(x: x, y: y) { f.set(idx) }
                }
            }
        case .saved:
            f = savedFrame
        }
        return f
    }
}

// MARK: - Packed frame lab parsing (C9)

enum DebugPackedParse {
    static func parse(_ text: String) -> PackedFrame? {
        try? PackedFrame.parse(text: text)
    }
}

// MARK: - View model

@Observable
@MainActor
final class DebugViewModel {
    // C1 preview
    var debugFrame = PackedFrame()
    private(set) var isLocalPatternActive = false

    // C2 device overview
    var statusRows: [(key: String, value: String)] = []
    var deviceInfo: DeviceInfo?
    var estimatedWatts: Double = 0

    // C3 firmware health
    var pingMs: Double?
    var commandsSent = 0
    var commandsFailed = 0
    var framesSent = 0
    var lastLocalError: String?

    // C4 power panel local ADC simulation (display only)
    var simAdcRaw: Double = 2048
    var simAdcRef: Double = 3.3
    var simADCVoltage: Double { (simAdcRaw / 4095.0) * simAdcRef }

    // C9 packed-frame lab
    var packedLabText: String = ""
    var packedLabValid: PackedFrame?
    var packedLabError: String?

    // C10 comms log
    private(set) var logs: [DebugLogEntry] = []
    var logFilter: DebugLogFilter = .normal
    var firmwareLogSubscribed = false
    private var firmwareLogTask: Task<Void, Never>?

    // C11 raw command
    var rawCommandText: String = "{\"cmd\":\"pause_scroll\"}"
    var rawCommandConfirmed = false
    var rawCommandResult: String = ""
    var rawCommandValid = true

    // C12 danger zone
    var clearFacesConfirmText = ""

    var visibleLogs: [DebugLogEntry] {
        Array(logs.filter { $0.level >= logFilter.minLevel }.suffix(120).reversed())
    }

    // MARK: Logging

    func log(_ level: DebugLogLevel, _ message: String) {
        logs.append(DebugLogEntry(level: level, message: message))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func clearLog() { logs.removeAll() }

    /// C10 firmware log toggle: on subscribes via `log_subscribe{on:true}` and
    /// mirrors `EV_LOG` (0x94) events into the comms log; off unsubscribes and
    /// cancels the consuming task.
    func setFirmwareLogSubscribed(_ on: Bool, connection: BoardConnection) {
        guard on != firmwareLogSubscribed else { return }
        firmwareLogSubscribed = on
        firmwareLogTask?.cancel()
        firmwareLogTask = nil
        guard on else {
            Task { _ = try? await connection.command(.logSubscribe(on: false)) }
            return
        }
        firmwareLogTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            _ = try? await connection.command(.logSubscribe(on: true))
            guard !Task.isCancelled, let self else { return }
            for await event in connection.events() {
                if Task.isCancelled { break }
                if case .log(let entry) = event {
                    self.log(Self.debugLevel(for: entry.level), "[固件\(entry.tag ?? "")] \(entry.msg ?? "")")
                }
            }
        }
    }

    private static func debugLevel(for firmwareLevel: String?) -> DebugLogLevel {
        switch firmwareLevel?.uppercased().first {
        case "E": return .error
        case "W": return .warn
        case "I": return .info
        case "D", "V": return .debug
        default: return .info
        }
    }

    var logShareText: String {
        logs.map { "[\($0.timeString)] \($0.level.label): \($0.message)" }.joined(separator: "\n")
    }

    func copyLog() {
        UIPasteboard.general.string = logShareText
    }

    // MARK: C2/C3 refresh

    func refreshStatus(connection: BoardConnection) async {
        do {
            let data = try await connection.getStatusRaw()
            statusRows = DebugJSON.flatten(data)
            recomputePower(connection: connection)
            log(.info, "刷新状态成功")
        } catch {
            lastLocalError = "\(error)"
            log(.error, "刷新状态失败: \(error)")
        }
    }

    func refreshPower(connection: BoardConnection) async {
        do {
            _ = try await connection.getPowerRaw()
            recomputePower(connection: connection)
            log(.info, "刷新电源成功")
        } catch {
            lastLocalError = "\(error)"
            log(.error, "刷新电源失败: \(error)")
        }
    }

    func refreshDeviceInfo(connection: BoardConnection) async {
        do {
            deviceInfo = try await connection.getDeviceInfo()
            log(.info, "获取设备信息成功")
        } catch {
            log(.error, "获取设备信息失败: \(error)")
        }
    }

    private func recomputePower(connection: BoardConnection) {
        let connectionStatus = statusRowsAsLookup()
        let lit = connection.currentFrame.litCount
        let brightness = connectionStatus["brightness"].flatMap { Int($0) } ?? 50
        let color = connectionStatus["color"] ?? "#f971d4"
        estimatedWatts = RGBHex.estimatedWatts(litCount: lit, brightness: brightness, hex: color)
    }

    private func statusRowsAsLookup() -> [String: String] {
        var dict: [String: String] = [:]
        for row in statusRows {
            let shortKey = row.key.split(separator: ".").last.map(String.init) ?? row.key
            dict[shortKey] = row.value
        }
        return dict
    }

    func pingBoard(connection: BoardConnection) async {
        do {
            let (uptime, rtt) = try await connection.pingRoundTrip()
            pingMs = rtt
            log(.info, "PING 往返 \(String(format: "%.1f", rtt)) ms，运行时间 \(uptime) ms")
        } catch {
            log(.error, "PING 失败: \(error)")
        }
    }

    func clearError() {
        lastLocalError = nil
    }

    func copyDiagnostics(connection: BoardConnection) {
        var obj: [String: Any] = [:]
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(connection.status)) ?? Data()) {
            obj["status"] = data
        }
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(connection.power)) ?? Data()) {
            obj["power"] = data
        }
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(connection.wifi)) ?? Data()) {
            obj["wifi"] = data
        }
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(connection.preview)) ?? Data()) {
            obj["preview"] = data
        }
        obj["counters"] = ["commandsSent": commandsSent, "commandsFailed": commandsFailed, "framesSent": framesSent]
        UIPasteboard.general.string = DebugJSON.prettyString(from: obj)
        log(.info, "已复制诊断 JSON")
    }

    // MARK: Command/frame wrappers (also drive the client-side counters)

    @discardableResult
    func runCommand(_ cmd: RinaCommand, connection: BoardConnection, note: String? = nil) async -> Bool {
        commandsSent += 1
        do {
            let reply = try await connection.command(cmd)
            log(.info, note ?? "\(cmd.name) -> ok=\(reply.ok)")
            return reply.ok
        } catch {
            commandsFailed += 1
            log(.error, "\(cmd.name) 失败: \(error)")
            return false
        }
    }

    func sendPattern(_ pattern: DebugPattern, connection: BoardConnection) async {
        let frame = pattern.frame(savedFrame: connection.currentFrame)
        framesSent += 1
        do {
            _ = try await connection.setFrame(frame, playback: .idle, reason: pattern.sendReason)
            debugFrame = frame
            isLocalPatternActive = true
            log(.info, "已发送图案: \(pattern.label)")
        } catch {
            log(.error, "发送图案失败(\(pattern.label)): \(error)")
        }
    }

    func previewPattern(_ pattern: DebugPattern, connection: BoardConnection) {
        debugFrame = pattern.frame(savedFrame: connection.currentFrame)
        isLocalPatternActive = true
        log(.debug, "本地预览: \(pattern.label)")
    }

    /// Keeps the C1 preview mirroring the board's live frame until the user
    /// opts into a local test pattern / packed-frame-lab preview.
    func syncDebugFrameWithLiveFrame(_ frame: PackedFrame) {
        guard !isLocalPatternActive else { return }
        debugFrame = frame
    }

    // MARK: C9 packed-frame lab

    func parsePackedLab() {
        packedLabError = nil
        if let frame = DebugPackedParse.parse(packedLabText) {
            packedLabValid = frame
        } else {
            packedLabValid = nil
            packedLabError = "无法解析：需要 94 位十六进制 / 47 项整数 JSON 数组 / base64"
        }
    }

    func applyPackedLabToPreview() {
        guard let frame = packedLabValid else { return }
        debugFrame = frame
        isLocalPatternActive = true
        log(.debug, "已解析为本地预览")
    }

    func sendPackedLab(connection: BoardConnection) async {
        guard let frame = packedLabValid else { return }
        framesSent += 1
        do {
            _ = try await connection.setFrame(frame, playback: .idle, reason: "debug_packed_lab")
            debugFrame = frame
            isLocalPatternActive = true
            log(.info, "已发送解析帧")
        } catch {
            log(.error, "发送解析帧失败: \(error)")
        }
    }

    func copyPreviewFrame() {
        UIPasteboard.general.string = debugFrame.hex94
        log(.debug, "已复制预览帧 (hex94)")
    }

    // MARK: C11 raw command

    func validateRawCommand() {
        guard let data = rawCommandText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              obj is [String: Any] else {
            rawCommandValid = false
            return
        }
        rawCommandValid = true
    }

    func sendRawCommand(connection: BoardConnection) async {
        guard rawCommandConfirmed, let data = rawCommandText.data(using: .utf8) else { return }
        commandsSent += 1
        do {
            let reply = try await connection.sendRawCommand(json: data)
            rawCommandResult = DebugJSON.prettyString(from: reply)
            log(.info, "原始指令已发送")
        } catch {
            commandsFailed += 1
            rawCommandResult = "错误: \(error)"
            log(.error, "原始指令失败: \(error)")
        }
    }

    // MARK: C12 danger zone

    func clearUserFaces(connection: BoardConnection) async {
        do {
            let reply = try await connection.facesClearUser()
            log(.info, "已清空用户表情，保留 \(reply.count ?? 0) 个默认表情 (gen=\(reply.gen ?? -1))")
        } catch {
            log(.error, "清空用户表情失败: \(error)")
        }
    }

    func reboot(connection: BoardConnection) async {
        await runCommand(.reboot, connection: connection, note: "已请求重启设备")
    }
}
