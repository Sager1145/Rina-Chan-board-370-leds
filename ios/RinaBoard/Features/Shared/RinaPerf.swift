import Foundation
import os

/// Signposts for Instruments (Points of Interest / os_signpost). Intervals cost
/// almost nothing when no profiler is attached.
enum RinaPerf {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: .pointsOfInterest)

    /// Wraps `block` in a signpost interval named `name`, returning its result
    /// unchanged. Lets a call site wrap a construction expression in place
    /// (e.g. as a `@State` initial value) without altering evaluation order
    /// or semantics.
    static func measure<T>(_ name: StaticString, _ block: () -> T) -> T {
        let state = signposter.beginInterval(name)
        #if DEBUG || RINA_PERF_LOG
        let start = ContinuousClock.now
        let value = block()
        let elapsed = ContinuousClock.now - start
        signposter.endInterval(name, state)
        LaunchTiming.record(name: "\(name)", milliseconds: LaunchTiming.ms(elapsed))
        return value
        #else
        defer { signposter.endInterval(name, state) }
        return block()
        #endif
    }
}

#if DEBUG || RINA_PERF_LOG
/// Temporary launch-timing collector for PR-14 measurement: records each
/// model construction's wall-clock duration so a single summary line can be
/// logged once `ContentReady` fires, without needing an Instruments trace.
/// Debug-only; compiled out of Release unless `RINA_PERF_LOG` is defined.
enum LaunchTiming {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: "LaunchTiming")
    private static var entries: [(name: String, ms: Double)] = []
    private static var didLogSummary = false
    private static let lock = NSLock()

    /// Converts a `Duration` to milliseconds for the recorded entries above.
    static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    /// Wall-clock time the process started, read once from the kernel
    /// (`sysctl KERN_PROC` `p_starttime`), used as the zero point for the
    /// process-start → `ContentReady` interval.
    static let processStart: Date = {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    static func record(name: String, milliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !didLogSummary else { return }
        entries.append((name, milliseconds))
    }

    /// Logs one summary line with every recorded model's duration, the
    /// video+presetLive+lipSync subtotal (the candidates for lazy init per
    /// PR-14's decision rule), and process-start → `eventName`. Marks the
    /// summary as logged so later `record` calls (e.g. boot-loader replay)
    /// are dropped instead of growing the buffer for a summary that already
    /// fired.
    static func logSummary(eventName: String) {
        lock.lock()
        let snapshot = entries
        didLogSummary = true
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let perModel = snapshot
            .map { String(format: "%@=%.2fms", $0.name, $0.ms) }
            .joined(separator: " ")
        let lazyCandidateNames: Set<String> = ["ModelInit.video", "ModelInit.presetLive", "ModelInit.lipSync"]
        let lazyCandidatesTotal = snapshot
            .filter { lazyCandidateNames.contains($0.name) }
            .reduce(0) { $0 + $1.ms }
        let sinceStart = Date().timeIntervalSince(processStart) * 1000
        logger.info(
            "\(eventName, privacy: .public): \(perModel, privacy: .public) videoPresetLiveLipSyncTotal=\(String(format: "%.2f", lazyCandidatesTotal), privacy: .public)ms processStartToEvent=\(String(format: "%.2f", sinceStart), privacy: .public)ms"
        )
    }
}
#endif
