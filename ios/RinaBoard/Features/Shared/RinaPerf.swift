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
/// Temporary per-frame stage-timing collector for PR-11 item 2's YUV
/// measurement (`VideoPlayerModel.processFrame`): accumulates each named
/// stage's wall-clock duration across a batch of frames and logs one summary
/// line once the batch fills, so shares can be read from the device log
/// without an Instruments trace. Modelled on `LaunchTiming` (perf/pr14-launch).
/// Debug-only; compiled out of Release unless `RINA_PERF_LOG` is defined.
enum VideoFrameTiming {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: "VideoFrameTiming")
    /// Frames per summary line: a few seconds of playback at typical frame
    /// rates (10–30 fps), long enough to average over per-frame jitter.
    private static let batchSize = 120
    private struct Batch: Sendable {
        var totalsMs: [String: Double] = [:]
        var order: [String] = []
        var frameCount = 0
    }
    private static let storage = OSAllocatedUnfairLock(initialState: Batch())

    /// Converts a `Duration` to milliseconds, matching `LaunchTiming.ms(_:)`.
    static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    /// Adds `elapsed` to `stage`'s running total for the current batch.
    static func record(stage: String, elapsed: Duration) {
        storage.withLock { batch in
            if batch.totalsMs[stage] == nil { batch.order.append(stage) }
            batch.totalsMs[stage, default: 0] += ms(elapsed)
        }
    }

    /// Call once per processed frame, after all of that frame's stages have
    /// been recorded via `record`. Every `batchSize`th call logs one summary
    /// (each stage's total and share of the whole-frame `VideoFrameProcess`
    /// total, plus the frame count) and resets for the next batch.
    static func frameCompleted() {
        let snapshot = storage.withLock { batch -> Batch? in
            batch.frameCount += 1
            guard batch.frameCount >= batchSize else { return nil }
            let completed = batch
            batch = Batch()
            return completed
        }
        guard let snapshot else { return }
        let snapshotTotals = snapshot.totalsMs
        let snapshotOrder = snapshot.order
        let frames = snapshot.frameCount

        let wholeFrameMs = snapshotTotals["VideoFrameProcess"] ?? 0
        guard wholeFrameMs > 0 else { return }
        let perStage = snapshotOrder.map { stage -> String in
            let total = snapshotTotals[stage] ?? 0
            let share = total / wholeFrameMs * 100
            return String(format: "%@=%.2fms(%.1f%%)", stage, total, share)
        }.joined(separator: " ")
        logger.info("VideoFrameProcess frames=\(frames, privacy: .public) \(perStage, privacy: .public)")
    }
}
#endif

#if DEBUG || RINA_PERF_LOG
/// Temporary per-draw stage-timing collector for PR-11 item 3's bloom
/// measurement (`LEDBoardPreview.draw` / `LEDBloomRenderer.drawBloom`):
/// accumulates each named stage's wall-clock duration across a batch of
/// Canvas redraws and logs one summary line once the batch fills, so shares
/// can be read from the device log without an Instruments trace. Modelled on
/// the `VideoFrameTiming` collector on `perf/pr11b-yuv-measure`, which is
/// itself modelled on the `LaunchTiming` collector on `perf/pr14-launch` —
/// neither is present on this branch, so this reimplements the same shape
/// rather than depending on either. Debug-only; compiled out of Release
/// unless `RINA_PERF_LOG` is defined.
enum BloomFrameTiming {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: "BloomFrameTiming")
    /// Draws per summary line. A whole-board Canvas at 120 Hz (the Text
    /// preview's ceiling) fills this in well under a second, and at Video's
    /// far lower rate it still covers several seconds of playback — long
    /// enough to average over per-draw jitter either way.
    private static let batchSize = 240
    private struct Batch: Sendable {
        var totalsMs: [String: Double] = [:]
        var order: [String] = []
        var drawCount = 0
    }
    private static let storage = OSAllocatedUnfairLock(initialState: Batch())

    /// Converts a `Duration` to milliseconds.
    static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    /// Adds `elapsed` to `stage`'s running total for the current batch.
    static func record(stage: String, elapsed: Duration) {
        storage.withLock { batch in
            if batch.totalsMs[stage] == nil { batch.order.append(stage) }
            batch.totalsMs[stage, default: 0] += ms(elapsed)
        }
    }

    /// Call once per `LEDBoardPreview.draw`, after all of that draw's stages
    /// have been recorded via `record`. Every `batchSize`th call logs one
    /// summary (each stage's total and share of the whole-draw
    /// `LEDBoardPreviewDraw` total, plus the draw count) and resets for the
    /// next batch.
    static func drawCompleted() {
        let snapshot = storage.withLock { batch -> Batch? in
            batch.drawCount += 1
            guard batch.drawCount >= batchSize else { return nil }
            let completed = batch
            batch = Batch()
            return completed
        }
        guard let snapshot else { return }
        let snapshotTotals = snapshot.totalsMs
        let snapshotOrder = snapshot.order
        let draws = snapshot.drawCount

        let wholeDrawMs = snapshotTotals["LEDBoardPreviewDraw"] ?? 0
        guard wholeDrawMs > 0 else { return }
        let perStage = snapshotOrder.map { stage -> String in
            let total = snapshotTotals[stage] ?? 0
            let share = total / wholeDrawMs * 100
            return String(format: "%@=%.2fms(%.1f%%)", stage, total, share)
        }.joined(separator: " ")
        logger.info("LEDBoardPreviewDraw draws=\(draws, privacy: .public) \(perStage, privacy: .public)")
    }
}
#endif

#if DEBUG || RINA_PERF_LOG
/// Temporary launch-timing collector for PR-14 measurement: records each
/// model construction's wall-clock duration so a single summary line can be
/// logged once `ContentReady` fires, without needing an Instruments trace.
/// Debug-only; compiled out of Release unless `RINA_PERF_LOG` is defined.
enum LaunchTiming {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: "LaunchTiming")
    private struct State: Sendable {
        var entries: [(name: String, ms: Double)] = []
        var didLogSummary = false
    }
    private static let storage = OSAllocatedUnfairLock(initialState: State())

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
        storage.withLock { state in
            guard !state.didLogSummary else { return }
            state.entries.append((name, milliseconds))
        }
    }

    /// Logs one summary line with every recorded model's duration, the
    /// video+presetLive+lipSync subtotal (the candidates for lazy init per
    /// PR-14's decision rule), and process-start → `eventName`. Marks the
    /// summary as logged so later `record` calls (e.g. boot-loader replay)
    /// are dropped instead of growing the buffer for a summary that already
    /// fired.
    static func logSummary(eventName: String) {
        let snapshot = storage.withLock { state in
            state.didLogSummary = true
            return state.entries
        }
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
