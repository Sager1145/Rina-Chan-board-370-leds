import Foundation
import os

/// Signposts for Instruments (Points of Interest / os_signpost). Intervals cost
/// almost nothing when no profiler is attached.
enum RinaPerf {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: .pointsOfInterest)
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
    private static var totalsMs: [String: Double] = [:]
    private static var order: [String] = []
    private static var frameCount = 0
    private static let lock = NSLock()

    /// Converts a `Duration` to milliseconds, matching `LaunchTiming.ms(_:)`.
    static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    /// Adds `elapsed` to `stage`'s running total for the current batch.
    static func record(stage: String, elapsed: Duration) {
        lock.lock()
        defer { lock.unlock() }
        if totalsMs[stage] == nil { order.append(stage) }
        totalsMs[stage, default: 0] += ms(elapsed)
    }

    /// Call once per processed frame, after all of that frame's stages have
    /// been recorded via `record`. Every `batchSize`th call logs one summary
    /// (each stage's total and share of the whole-frame `VideoFrameProcess`
    /// total, plus the frame count) and resets for the next batch.
    static func frameCompleted() {
        lock.lock()
        frameCount += 1
        guard frameCount >= batchSize else { lock.unlock(); return }
        let snapshotTotals = totalsMs
        let snapshotOrder = order
        let frames = frameCount
        totalsMs.removeAll()
        order.removeAll()
        frameCount = 0
        lock.unlock()

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
