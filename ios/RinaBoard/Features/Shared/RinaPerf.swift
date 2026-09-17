import Foundation
import os

/// Signposts for Instruments (Points of Interest / os_signpost). Intervals cost
/// almost nothing when no profiler is attached.
enum RinaPerf {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: .pointsOfInterest)
}

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
    private static var totalsMs: [String: Double] = [:]
    private static var order: [String] = []
    private static var drawCount = 0
    private static let lock = NSLock()

    /// Converts a `Duration` to milliseconds.
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

    /// Call once per `LEDBoardPreview.draw`, after all of that draw's stages
    /// have been recorded via `record`. Every `batchSize`th call logs one
    /// summary (each stage's total and share of the whole-draw
    /// `LEDBoardPreviewDraw` total, plus the draw count) and resets for the
    /// next batch.
    static func drawCompleted() {
        lock.lock()
        drawCount += 1
        guard drawCount >= batchSize else { lock.unlock(); return }
        let snapshotTotals = totalsMs
        let snapshotOrder = order
        let draws = drawCount
        totalsMs.removeAll()
        order.removeAll()
        drawCount = 0
        lock.unlock()

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
