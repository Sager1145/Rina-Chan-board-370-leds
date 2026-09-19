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
        case .debug: return NSLocalizedString("详细", comment: "debug log level")
        case .info: return NSLocalizedString("信息", comment: "debug log level")
        case .warn: return NSLocalizedString("警告", comment: "debug log level")
        case .error: return NSLocalizedString("错误", comment: "debug log level")
        }
    }
}

enum DebugLogSource: String, CaseIterable, Identifiable {
    case app
    case firmware

    var id: String { rawValue }
    var label: String {
        switch self {
        case .app: return NSLocalizedString("应用", comment: "debug log source")
        case .firmware: return NSLocalizedString("固件", comment: "debug log source")
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
    let source: DebugLogSource
    let level: DebugLogLevel
    let message: String

    init(source: DebugLogSource = .app, level: DebugLogLevel, message: String) {
        self.source = source
        self.level = level
        self.message = message
    }

    var timeString: String { Self.timeFormatter.string(from: date) }
}

enum DebugLogFilter: String, CaseIterable, Identifiable {
    case errorsOnly
    case warnAndUp
    case normal
    case verbose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .errorsOnly: return NSLocalizedString("仅错误", comment: "debug log filter")
        case .warnAndUp: return NSLocalizedString("警告及以上", comment: "debug log filter")
        case .normal: return NSLocalizedString("信息及以上", comment: "debug log filter")
        case .verbose: return NSLocalizedString("详细", comment: "debug log filter")
        }
    }

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
        case .off: return NSLocalizedString("全部熄灭", comment: "debug test pattern")
        case .checker: return NSLocalizedString("棋盘", comment: "debug test pattern")
        case .border: return NSLocalizedString("边框", comment: "debug test pattern")
        case .saved: return NSLocalizedString("当前保存表情", comment: "debug test pattern")
        case .allOn: return NSLocalizedString("全部点亮", comment: "debug test pattern")
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

struct DebugRawField: Identifiable {
    let source: String
    let key: String
    let value: String
    var id: String { "\(source).\(key)" }
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
    var powerRows: [(key: String, value: String)] = []
    var statusRawText = ""
    var powerRawText = ""
    var statusSnapshot: DeviceStatus?
    var powerSnapshot: PowerStatus?
    var deviceInfo: DeviceInfo?
    var estimatedWatts: Double?
    var statusUpdatedAt: Date?
    var powerUpdatedAt: Date?
    var deviceInfoUpdatedAt: Date?
    var isRefreshingOverview = false
    var rawFieldSearch = ""

    // C3 firmware health
    var pingMs: Double?
    var commandAttempts = 0
    var commandRejected = 0
    var commandFailures = 0
    var frameAttempts = 0
    var frameFailures = 0
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
    /// Ground truth ring buffer (capacity 500). Not `@Observable`-tracked:
    /// lines are appended to it immediately and in full on every `log()`
    /// call (from whichever thread/actor calls in — always hopped to
    /// `@MainActor` since this whole model is `@MainActor`), but the
    /// published `logs` snapshot below is only refreshed on a coalesced
    /// schedule so a burst of firmware log lines doesn't force a SwiftUI
    /// diff per line.
    @ObservationIgnored private var logRing = RingBuffer<DebugLogEntry>(capacity: 500)
    /// Published snapshot of `logRing`, refreshed by `flushPendingLogs()`.
    /// `visibleLogs` (and everything else that renders the log) reads this,
    /// not `logRing` directly.
    private(set) var logs: [DebugLogEntry] = []
    @ObservationIgnored private var hasScheduledLogFlush = false
    var logFilter: DebugLogFilter = .normal {
        didSet { recomputeVisibleLogs() }
    }
    var logSource: DebugLogSource? {
        didSet { recomputeVisibleLogs() }
    }
    var logSearch = "" {
        didSet { recomputeVisibleLogs() }
    }
    var isLogDisplayPaused = false {
        didSet {
            guard isLogDisplayPaused != oldValue else { return }
            if isLogDisplayPaused {
                // Flush so the paused snapshot reflects everything logged up
                // to this instant, matching the old synchronous behavior.
                flushPendingLogs()
                pausedLogs = logs
            } else {
                // Flush so resuming immediately shows lines that arrived
                // while paused, instead of waiting for the next scheduled
                // flush.
                flushPendingLogs()
                pausedLogs = nil
            }
        }
    }
    private var pausedLogs: [DebugLogEntry]? {
        didSet { recomputeVisibleLogs() }
    }
    enum FirmwareLogState: Equatable {
        case off
        case subscribing
        case on
        case failed(String)
    }
    private(set) var firmwareLogState: FirmwareLogState = .off
    private var firmwareLogTask: Task<Void, Never>?

    var selectedPattern: DebugPattern?

    var monitorInput = "get_info" {
        // A confirmation covers the text it was given for, nothing later.
        didSet { if monitorInput != oldValue { monitorDestructiveConfirmed = false } }
    }
    var monitorDestructiveConfirmed = false
    var isMonitorSending = false
    private var monitorRing = RingBuffer<DebugLogEntry>(capacity: 500)
    /// O(1): checks the ring buffer directly instead of materializing
    /// `monitorEntries` (which is O(n)) just to test emptiness.
    var isMonitorEntriesEmpty: Bool { monitorRing.isEmpty }
    /// Materializes the ring buffer's contents. O(n) — call once per view
    /// body pass and reuse the result rather than reading this repeatedly.
    var monitorEntries: [DebugLogEntry] {
        monitorRing.elements
    }

    func clearMonitor() {
        monitorRing.removeAll()
    }

    // C12 danger zone
    var clearFacesConfirmText = ""

    /// Filters + sorts (newest first, capped to 120) on `logs`/`pausedLogs`.
    /// A `@Observable`-tracked stored property, eagerly recomputed by
    /// `recomputeVisibleLogs()` whenever an input actually changes (see the
    /// `didSet`s on `logFilter`/`logSource`/`logSearch`/`pausedLogs`, and
    /// `flushPendingLogs()`/`clearLog()` for `logs`). It must be a *stored*
    /// property recomputed on write, not a lazily-recomputed getter: a getter
    /// that only reads its dependencies on a "dirty" branch registers no
    /// Observation dependency on a clean read, so a body pass that hits the
    /// clean path wouldn't be re-invoked by a later flush.
    private(set) var visibleLogs: [DebugLogEntry] = []

    private func recomputeVisibleLogs() {
        let source = pausedLogs ?? logs
        let query = logSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleLogs = Array(source.filter { entry in
            entry.level >= logFilter.minLevel
                && (logSource == nil || entry.source == logSource)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }.suffix(120).reversed())
    }

    var filteredRawRows: [DebugRawField] {
        let query = rawFieldSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = statusRows.map { DebugRawField(source: "STATUS", key: $0.key, value: $0.value) }
            + powerRows.map { DebugRawField(source: "POWER", key: $0.key, value: $0.value) }
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.source.localizedCaseInsensitiveContains(query)
                || $0.key.localizedCaseInsensitiveContains(query)
                || $0.value.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: Logging

    /// Called from wherever a log line originates (this whole view model is
    /// `@MainActor`, so `log` itself always runs on the main actor even
    /// though callers may be resuming from an arbitrary background
    /// continuation, e.g. the firmware `EV_LOG` stream in
    /// `setFirmwareLogSubscribed`). Appends to the ring buffer immediately
    /// (O(1), not `@Observable`-tracked) and schedules a coalesced flush of
    /// the published `logs` snapshot instead of publishing every single line.
    func log(_ level: DebugLogLevel, _ message: String, source: DebugLogSource = .app) {
        if source == .firmware { appendMonitor(level, "EV_LOG · \(message)") }
        logRing.append(DebugLogEntry(source: source, level: level, message: message))
        scheduleLogFlush()
    }

    @ObservationIgnored private var pendingFlushTask: Task<Void, Never>?

    private func scheduleLogFlush() {
        guard !hasScheduledLogFlush else { return }
        hasScheduledLogFlush = true
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            // `Task.sleep` throws `CancellationError`, which `try?` swallows
            // above — without this explicit check, cancelling the task (see
            // `flushPendingLogs()`) would make it fall straight through to
            // `flushPendingLogs()` immediately instead of not running at all,
            // which is worse than not cancelling: a burst plus a rapid pause
            // toggle could cascade (task A is cancelled, flushes anyway,
            // which cancels task B, which wakes and flushes too).
            guard !Task.isCancelled else { return }
            self?.flushPendingLogs()
        }
    }

    /// Copies the ring buffer's current contents into the published `logs`
    /// snapshot. Runs on its own coalesced schedule (see `scheduleLogFlush`),
    /// but is also called synchronously wherever an exact, up-to-the-instant
    /// view of the log is required (export, pause/resume) — and is exposed
    /// so tests can force deterministic, synchronous flushing. Cancels any
    /// still-sleeping scheduled flush so a synchronous flush doesn't leave an
    /// orphan wake-up behind (the "one-shot" scheduling really is one-shot).
    func flushPendingLogs() {
        hasScheduledLogFlush = false
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        logs = logRing.elements
        // While paused, `visibleLogs` is driven by the frozen `pausedLogs`
        // snapshot (see its `didSet`), not by `logs` — so recomputing here
        // would provably return the same result while still invalidating
        // every SwiftUI observer of `visibleLogs` on each coalesced flush
        // (~13/s), and re-running the search filter over up to 500 entries
        // on the main actor for a list nobody can see change.
        guard pausedLogs == nil else { return }
        recomputeVisibleLogs()
    }

    func clearLog() {
        logRing.removeAll()
        logs.removeAll()
        pausedLogs?.removeAll()
        recomputeVisibleLogs()
    }

    /// C10 firmware log toggle: on subscribes via `log_subscribe{on:true}` and
    /// mirrors `EV_LOG` (0x94) events into the comms log; off unsubscribes and
    /// cancels the consuming task.
    func setFirmwareLogSubscribed(_ on: Bool, connection: BoardConnection) {
        firmwareLogTask?.cancel()
        firmwareLogTask = nil
        guard on else {
            firmwareLogState = .off
            Task {
                do {
                    _ = try await connection.command(.logSubscribe(on: false))
                } catch is CancellationError {
                } catch {
                    log(.warn, String(format: NSLocalizedString("关闭固件日志订阅失败：%@", comment: "debug firmware log unsubscribe failed"), error.localizedDescription))
                }
            }
            return
        }
        guard connection.connectionState == .connected else {
            firmwareLogState = .failed(NSLocalizedString("设备未连接", comment: "debug firmware logging unavailable"))
            return
        }
        firmwareLogState = .subscribing
        firmwareLogTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else { return }
                let reply = try await connection.command(.logSubscribe(on: true))
                guard reply.ok else {
                    self?.firmwareLogState = .failed(reply.error ?? NSLocalizedString("固件拒绝订阅", comment: "debug firmware log subscription rejected"))
                    return
                }
                guard !Task.isCancelled else { return }
                self?.firmwareLogState = .on
                // Resolve `self` per event rather than binding it for the whole
                // loop: `self.firmwareLogTask` holds this task, so a strong
                // binding held across the stream's awaits is a retain cycle and
                // the model outlives the screen, still mirroring EV_LOG into its
                // rings and running the redaction regexes on the main actor.
                for await event in connection.events() {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if case .log(let entry) = event {
                        let tag = entry.tag.map { "[\($0)] " } ?? ""
                        self.log(Self.debugLevel(for: entry.level),
                                 "\(tag)\(entry.msg ?? "")",
                                 source: .firmware)
                    }
                }
                if !Task.isCancelled {
                    self?.firmwareLogState = .failed(NSLocalizedString("固件日志流已停止", comment: "debug firmware log stream ended"))
                }
            } catch is CancellationError {
            } catch {
                self?.firmwareLogState = .failed(error.localizedDescription)
            }
        }
    }

    /// The active board changed. `handleConnectionStateChange` is driven by
    /// `connectionState`, so switching between two boards that are both
    /// `.connected` never reached it: the old board's log task kept streaming
    /// (it holds the old connection), the header still claimed the firmware log
    /// was on, and the overview stayed on the previous board.
    @ObservationIgnored private var lastSessionKey: String?

    /// How old an overview may be before the page reloads it on appearing.
    static let overviewFreshness: TimeInterval = 10

    /// Called whenever the Debug page is built. A different session resets
    /// the firmware log and reloads; the same session only reloads a stale
    /// snapshot, so a resize that rebuilds the page sends nothing.
    func pageAppeared(sessionKey: String, connection: BoardConnection) async {
        if sessionKey != lastSessionKey {
            lastSessionKey = sessionKey
            handleSessionChange()
            // The model outlives the page; never show one board's snapshot
            // as another's, which a disconnected board would otherwise do.
            clearSnapshots()
        } else if let updated = statusUpdatedAt,
                  Date().timeIntervalSince(updated) < Self.overviewFreshness {
            return
        }
        await refreshOverview(connection: connection)
    }

    private func clearSnapshots() {
        statusRows = []
        powerRows = []
        statusRawText = ""
        powerRawText = ""
        statusSnapshot = nil
        powerSnapshot = nil
        deviceInfo = nil
        statusUpdatedAt = nil
        powerUpdatedAt = nil
        deviceInfoUpdatedAt = nil
    }

    func handleSessionChange() {
        firmwareLogTask?.cancel()
        firmwareLogTask = nil
        firmwareLogState = .off
    }

    func handleConnectionStateChange(_ state: BoardConnectionState) {
        log(.info, String(format: NSLocalizedString("连接状态：%@", comment: "debug connection state log"), Self.connectionStateLabel(state)))
        guard state != .connected else { return }
        firmwareLogTask?.cancel()
        firmwareLogTask = nil
        if case .on = firmwareLogState {
            firmwareLogState = .failed(NSLocalizedString("连接已断开", comment: "debug firmware log disconnected"))
        } else if case .subscribing = firmwareLogState {
            firmwareLogState = .failed(NSLocalizedString("连接已断开", comment: "debug firmware log disconnected"))
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

    private static func connectionStateLabel(_ state: BoardConnectionState) -> String {
        switch state {
        case .disconnected:
            return NSLocalizedString("未连接", comment: "debug connection state")
        case .connecting:
            return NSLocalizedString("连接中", comment: "debug connection state")
        case .connected:
            return NSLocalizedString("已连接", comment: "debug connection state")
        case .reconnecting(let attempt):
            return String(format: NSLocalizedString("重连中 · 第 %lld 次", comment: "debug reconnecting state"), Int64(attempt))
        case .failed(let message):
            return String(format: NSLocalizedString("连接失败：%@", comment: "debug failed connection state"), message)
        }
    }

    /// Export/copy text. Reads `logRing` (the ground truth) directly instead
    /// of `logs`, so it always reflects every line logged so far regardless
    /// of the coalesced publish schedule — without mutating any
    /// `@Observable`-tracked state from a getter. `ShareLink(item:)` and
    /// similar SwiftUI call sites evaluate this eagerly on every body pass,
    /// so this must stay a pure read.
    var logShareText: String {
        logRing.elements.map {
            Self.redactSensitive("[\($0.timeString)] [\($0.source.label)] \($0.level.label): \($0.message)")
        }.joined(separator: "\n")
    }

    // Compiled once, not per call: `redactSensitive` runs over every line of
    // `logShareText`/`copyRawSnapshots` (up to 500 lines), and recompiling
    // two `NSRegularExpression`s per line made this the single largest
    // per-body-pass cost on the Debug log page — the exact page this PR
    // exists to speed up.
    private static let quotedValuePattern = #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
    // Authorization header values commonly contain a scheme and credential
    // separated by whitespace. Redact the complete value before applying
    // the generic single-value rule below.
    private static let authorizationExpression = try? NSRegularExpression(
        pattern: #"(?i)(\"?authorization\"?\s*[:=]\s*)("# + quotedValuePattern + #"|[^\r\n,}\]]+)"#
    )
    private static let sensitiveValueExpression = try? NSRegularExpression(
        pattern: #"(?i)(\"?(?:password|passwd|pwd|psk|secret|token)\"?\s*[:=]\s*)("# + quotedValuePattern + #"|[^\s,}\]]+)"#
    )

    private static func redactSensitive(_ value: String) -> String {
        let hidden = NSLocalizedString("<已隐藏>", comment: "redacted debug value placeholder")

        return [authorizationExpression, sensitiveValueExpression].reduce(value) { redacted, expression in
            guard let expression else { return redacted }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            return expression.stringByReplacingMatches(in: redacted,
                                                       range: range,
                                                       withTemplate: "$1\(hidden)")
        }
    }

    func copyLog() {
        UIPasteboard.general.string = logShareText
    }

    // MARK: C2/C3 refresh

    func refreshOverview(connection: BoardConnection) async {
        guard !isRefreshingOverview else { return }
        guard connection.connectionState == .connected else { return }
        isRefreshingOverview = true
        defer { isRefreshingOverview = false }
        await refreshStatus(connection: connection)
        await refreshPower(connection: connection)
        await refreshDeviceInfo(connection: connection)
    }

    func refreshStatus(connection: BoardConnection) async {
        do {
            let data = try await connection.getStatusRaw()
            statusRows = DebugJSON.flatten(data)
            statusRawText = DebugJSON.prettyString(from: data)
            statusSnapshot = try JSONDecoder().decode(DeviceStatus.self, from: data)
            statusUpdatedAt = Date()
            if let power = statusSnapshot?.power {
                powerSnapshot = power
                powerUpdatedAt = statusUpdatedAt
            }
            recomputePower()
            lastLocalError = nil
            log(.info, NSLocalizedString("刷新状态成功", comment: "debug status refresh succeeded"))
        } catch {
            lastLocalError = error.localizedDescription
            log(.error, String(format: NSLocalizedString("刷新状态失败：%@", comment: "debug status refresh failed"), error.localizedDescription))
        }
    }

    func refreshPower(connection: BoardConnection) async {
        do {
            let data = try await connection.getPowerRaw()
            powerRows = DebugJSON.flatten(data)
            powerRawText = DebugJSON.prettyString(from: data)
            powerSnapshot = try JSONDecoder().decode(PowerStatus.self, from: data)
            powerUpdatedAt = Date()
            lastLocalError = nil
            log(.info, NSLocalizedString("刷新电源成功", comment: "debug power refresh succeeded"))
        } catch {
            lastLocalError = error.localizedDescription
            log(.error, String(format: NSLocalizedString("刷新电源失败：%@", comment: "debug power refresh failed"), error.localizedDescription))
        }
    }

    func refreshDeviceInfo(connection: BoardConnection) async {
        do {
            deviceInfo = try await connection.getDeviceInfo()
            deviceInfoUpdatedAt = Date()
            lastLocalError = nil
            log(.info, NSLocalizedString("获取设备信息成功", comment: "debug device info refresh succeeded"))
        } catch {
            lastLocalError = error.localizedDescription
            log(.error, String(format: NSLocalizedString("获取设备信息失败：%@", comment: "debug device info refresh failed"), error.localizedDescription))
        }
    }

    private func recomputePower() {
        guard let renderer = statusSnapshot?.renderer,
              let lit = renderer.lit,
              let brightness = renderer.brightness,
              let color = renderer.color else {
            estimatedWatts = nil
            return
        }
        estimatedWatts = RGBHex.estimatedWatts(litCount: lit, brightness: brightness, hex: color)
    }

    func freshnessText(for date: Date?, connected: Bool) -> String {
        guard let date else { return NSLocalizedString("未采样", comment: "debug sample freshness") }
        let stamp = date.formatted(date: .omitted, time: .standard)
        if !connected {
            return String(format: NSLocalizedString("断线前 · %@", comment: "debug sample freshness while disconnected"), stamp)
        }
        if Date().timeIntervalSince(date) > 30 {
            return String(format: NSLocalizedString("可能陈旧 · %@", comment: "debug stale sample freshness"), stamp)
        }
        return String(format: NSLocalizedString("更新于 %@", comment: "debug fresh sample timestamp"), stamp)
    }

    static func triState(_ value: Bool?) -> String {
        guard let value else { return NSLocalizedString("未知", comment: "unknown optional boolean") }
        return value
            ? NSLocalizedString("是", comment: "optional boolean yes")
            : NSLocalizedString("否", comment: "optional boolean no")
    }

    func pingBoard(connection: BoardConnection) async {
        do {
            let (uptime, rtt) = try await connection.pingRoundTrip()
            pingMs = rtt
            log(.info, String(format: NSLocalizedString("PING 往返 %.1f ms，运行时间 %lld ms", comment: "debug ping result"), rtt, Int64(uptime)))
        } catch {
            log(.error, String(format: NSLocalizedString("PING 失败：%@", comment: "debug ping failed"), error.localizedDescription))
        }
    }

    func copyDiagnostics(connection: BoardConnection) {
        var obj: [String: Any] = [:]
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(statusSnapshot)) ?? Data()) {
            obj["status"] = data
        }
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(powerSnapshot)) ?? Data()) {
            obj["power"] = data
        }
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(connection.wifi)) ?? Data()) {
            obj["wifi"] = data
        }
        if let data = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(connection.preview)) ?? Data()) {
            obj["preview"] = data
        }
        obj["debugSessionCounters"] = [
            "commandAttempts": commandAttempts,
            "commandRejected": commandRejected,
            "commandFailures": commandFailures,
            "frameAttempts": frameAttempts,
            "frameFailures": frameFailures
        ]
        obj["sampledAt"] = [
            "status": statusUpdatedAt?.ISO8601Format() ?? "unknown",
            "power": powerUpdatedAt?.ISO8601Format() ?? "unknown",
            "deviceInfo": deviceInfoUpdatedAt?.ISO8601Format() ?? "unknown"
        ]
        UIPasteboard.general.string = DebugJSON.prettyString(from: obj)
        log(.info, NSLocalizedString("已复制诊断 JSON", comment: "debug diagnostics copied"))
    }

    func copyRawSnapshots() {
        let combined = "GET_STATUS\n\(statusRawText)\n\nGET_POWER\n\(powerRawText)"
        UIPasteboard.general.string = Self.redactSensitive(combined)
        log(.info, NSLocalizedString("已复制脱敏原始快照", comment: "debug redacted snapshots copied"))
    }

    // MARK: Command/frame wrappers (also drive the client-side counters)

    @discardableResult
    func runCommand(_ cmd: RinaCommand, connection: BoardConnection, note: String? = nil) async -> Bool {
        commandAttempts += 1
        let outputSession = connection.output.begin(.debug)
        do {
            let reply = try await connection.withOutput(outputSession) {
                try await connection.command(cmd)
            }
            guard reply.ok else {
                commandRejected += 1
                log(.warn, String(format: NSLocalizedString("%@ 被设备拒绝：%@", comment: "debug command rejected"),
                                  cmd.name,
                                  reply.error ?? NSLocalizedString("未知原因", comment: "unknown device rejection reason")))
                return false
            }
            log(.info, note ?? String(format: NSLocalizedString("%@ -> 成功", comment: "debug command succeeded"), cmd.name))
            return reply.ok
        } catch is CancellationError {
            log(.debug, String(format: NSLocalizedString("%@ 已被新的输出操作替代", comment: "debug command superseded"), cmd.name))
            return false
        } catch {
            if Self.isDeviceRejection(error) {
                commandRejected += 1
                log(.warn, String(format: NSLocalizedString("%@ 被设备拒绝：%@", comment: "debug command rejected"), cmd.name, error.localizedDescription))
            } else {
                commandFailures += 1
                log(.error, String(format: NSLocalizedString("%@ 失败：%@", comment: "debug command failed"), cmd.name, error.localizedDescription))
            }
            return false
        }
    }

    func sendPattern(_ pattern: DebugPattern, connection: BoardConnection) async {
        let frame = pattern.frame(savedFrame: connection.currentFrame)
        frameAttempts += 1
        let outputSession = connection.output.begin(.debug)
        do {
            let reply = try await connection.withOutput(outputSession) {
                try await connection.setFrame(frame,
                                              playback: .idle,
                                              reason: pattern.sendReason,
                                              outputSession: outputSession)
            }
            guard reply.ok else {
                commandRejected += 1
                log(.warn, String(format: NSLocalizedString("发送图案被设备拒绝：%@", comment: "debug pattern rejected"),
                                  reply.error ?? NSLocalizedString("未知原因", comment: "unknown device rejection reason")))
                return
            }
            debugFrame = frame
            isLocalPatternActive = true
            log(.info, String(format: NSLocalizedString("已发送图案：%@", comment: "debug pattern sent"), pattern.label))
        } catch is CancellationError {
            log(.debug, NSLocalizedString("发送图案已被新的输出操作替代", comment: "debug pattern superseded"))
        } catch {
            if Self.isDeviceRejection(error) {
                commandRejected += 1
                log(.warn, String(format: NSLocalizedString("发送图案被设备拒绝：%@", comment: "debug pattern rejected"), error.localizedDescription))
            } else {
                frameFailures += 1
                log(.error, String(format: NSLocalizedString("发送图案失败（%@）：%@", comment: "debug pattern send failed"), pattern.label, error.localizedDescription))
            }
        }
    }

    func previewPattern(_ pattern: DebugPattern, connection: BoardConnection) {
        debugFrame = pattern.frame(savedFrame: connection.currentFrame)
        isLocalPatternActive = true
        log(.debug, String(format: NSLocalizedString("本地预览：%@", comment: "debug local pattern preview"), pattern.label))
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
            packedLabError = NSLocalizedString("无法解析：需要 94 个十六进制字符 / 47 项整数 JSON 数组 / Base64", comment: "debug packed frame parse error")
        }
    }

    func applyPackedLabToPreview() {
        guard let frame = packedLabValid else { return }
        debugFrame = frame
        isLocalPatternActive = true
        log(.debug, NSLocalizedString("已解析为本地预览", comment: "debug packed frame preview parsed"))
    }

    func sendPackedLab(connection: BoardConnection) async {
        guard let frame = packedLabValid else { return }
        frameAttempts += 1
        let outputSession = connection.output.begin(.debug)
        do {
            let reply = try await connection.withOutput(outputSession) {
                try await connection.setFrame(frame,
                                              playback: .idle,
                                              reason: "debug_packed_lab",
                                              outputSession: outputSession)
            }
            guard reply.ok else {
                commandRejected += 1
                log(.warn, String(format: NSLocalizedString("发送解析帧被设备拒绝：%@", comment: "debug packed frame rejected"),
                                  reply.error ?? NSLocalizedString("未知原因", comment: "unknown device rejection reason")))
                return
            }
            debugFrame = frame
            isLocalPatternActive = true
            log(.info, NSLocalizedString("已发送解析帧", comment: "debug packed frame sent"))
        } catch is CancellationError {
            log(.debug, NSLocalizedString("发送解析帧已被新的输出操作替代", comment: "debug packed frame superseded"))
        } catch {
            if Self.isDeviceRejection(error) {
                commandRejected += 1
                log(.warn, String(format: NSLocalizedString("发送解析帧被设备拒绝：%@", comment: "debug packed frame rejected"), error.localizedDescription))
            } else {
                frameFailures += 1
                log(.error, String(format: NSLocalizedString("发送解析帧失败：%@", comment: "debug packed frame failed"), error.localizedDescription))
            }
        }
    }

    func copyPreviewFrame() {
        UIPasteboard.general.string = debugFrame.hex94
        log(.debug, NSLocalizedString("已复制预览帧 (hex94)", comment: "debug preview frame copied"))
    }

    // MARK: Serial monitor

    private func appendMonitor(_ level: DebugLogLevel, _ message: String) {
        monitorRing.append(DebugLogEntry(level: level, message: Self.redactSensitive(message)))
    }

    func copyMonitor() {
        UIPasteboard.general.string = monitorEntries.map { "[\($0.timeString)] \($0.message)" }.joined(separator: "\n")
    }

    func sendMonitorCommand(connection: BoardConnection) async {
        guard !isMonitorSending, connection.connectionState == .connected else { return }
        let input = monitorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let request: DebugMonitorRequest
        do {
            request = try DebugMonitorRequest.parse(input)
        } catch {
            appendMonitor(.error, error.localizedDescription)
            return
        }
        guard !request.isDestructive || monitorDestructiveConfirmed else { return }
        isMonitorSending = true
        defer {
            isMonitorSending = false
            monitorDestructiveConfirmed = false
        }
        commandAttempts += 1
        appendMonitor(.info, "TX → \(input)")
        do {
            let reply: RinaLinkFrame
            if request.type == .cmd {
                let session = connection.output.begin(.debug)
                reply = try await connection.withOutput(session) {
                    try await connection.send(type: request.type, payload: request.payload)
                }
            } else {
                reply = try await connection.send(type: request.type, payload: request.payload)
            }
            let object = (try? JSONSerialization.jsonObject(with: reply.payload)) as? [String: Any]
            let rejected = object?["ok"] as? Bool == false
            if rejected { commandRejected += 1 }
            appendMonitor(rejected ? .warn : .info, "RX ← \(DebugJSON.prettyString(from: reply.payload))")
        } catch is CancellationError {
            appendMonitor(.warn, NSLocalizedString("原始指令已被新的输出操作替代", comment: "debug command superseded"))
        } catch {
            if Self.isDeviceRejection(error) { commandRejected += 1 } else { commandFailures += 1 }
            appendMonitor(.error, "RX ← \(error.localizedDescription)")
        }
    }

    // MARK: C12 danger zone

    func clearUserFaces(connection: BoardConnection) async {
        commandAttempts += 1
        let outputSession = connection.output.begin(.debug)
        do {
            let reply = try await connection.withOutput(outputSession) {
                try await connection.facesClearUser()
            }
            if reply.ok == false {
                commandRejected += 1
                log(.warn, NSLocalizedString("清空用户表情被设备拒绝", comment: "debug clear faces rejected"))
                return
            }
            log(.info, String(format: NSLocalizedString("已清空用户表情，保留 %lld 个默认表情 (gen=%lld)", comment: "debug clear faces succeeded"),
                              Int64(reply.count ?? 0), Int64(reply.gen ?? -1)))
        } catch is CancellationError {
            log(.debug, NSLocalizedString("清空用户表情已被新的输出操作替代", comment: "debug clear faces superseded"))
        } catch {
            commandFailures += 1
            log(.error, String(format: NSLocalizedString("清空用户表情失败：%@", comment: "debug clear faces failed"), error.localizedDescription))
        }
    }

    private static func isDeviceRejection(_ error: Error) -> Bool {
        if error is RinaLinkError { return true }
        if case RinaTransportError.underlying(let message) = error {
            return message.contains("面板拒绝")
        }
        return false
    }
}
