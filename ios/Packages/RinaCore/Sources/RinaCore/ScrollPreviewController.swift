/// Preview speed-lock (phase-locked loop) for the local scroll-text preview,
/// ported from the WebUI (`app.js` 10222–10453) per
/// `docs/SCROLL_RASTERIZER_SPEC.md` §6. Pure value type, no Foundation and no
/// wall-clock reads — all timestamps are supplied by the caller so the
/// algorithm is unit-testable with synthetic time.
///
/// `tick()` advances one frame locally. Fresh sessions, reconnects and large
/// position errors anchor directly to the actual presentation; small drift is
/// corrected by slewing the delay between ticks. Telemetry stays low-frequency.
public struct ScrollPreviewController {
    // MARK: Constants (SCROLL_RASTERIZER_SPEC §6)

    private static let hwRateWindowMs: Double = 8000
    private static let minSamples = 3
    private static let minSpanMs: Double = 2000
    private static let minFrames = 3
    private static let fpsMin: Double = 0.2
    private static let fpsMax: Double = 120
    private static let emaAlpha: Double = 0.4
    private static let intervalBlendAlpha: Double = 0.18
    private static let phaseAlpha: Double = 0.25
    private static let phaseDeadband: Double = 0.65
    private static let gentleMin: Double = 0.97
    private static let gentleMax: Double = 1.03
    private static let catchupMin: Double = 0.9
    private static let catchupMax: Double = 1.1
    private static let catchupThreshold: Double = 4
    private static let alignHorizonMs: Double = 1000
    private static let slewPerSec: Double = 0.04

    /// Sources that represent a discontinuous jump (start/step/manual/clear/
    /// overlay) rather than the steady tick of an active scroll: these snap
    /// the display index instead of phase-correcting it, and are excluded
    /// from the rate estimator.
    private static let steppingSources: Set<String> = ["scroll_start", "scroll_step", "manual", "manual_frame", "clear", "overlay"]
    private static let discontinuousRateSources: Set<String> = [
        "scroll_start", "scroll_step", "manual", "manual_frame", "clear", "overlay",
    ]

    public enum RecordOutcome: Equatable {
        case ok
        case identityMismatch
        case snapped(Int)
    }

    public enum LockState: String, Equatable, Sendable {
        case free
        case locked
        case gentle
        case catchup
    }

    private struct RateSample {
        let seq: Int
        let advanceSeq: UInt32?
        let tMs: Double
        let frameIndex: Int
        let unwrappedFrame: Int
    }

    // MARK: Public read-only state

    public private(set) var displayIndex: Int = 0
    public private(set) var measuredFps: Double
    public private(set) var previewIntervalMs: Double
    public private(set) var phaseError: Double = 0
    public private(set) var lockState: LockState = .free

    // MARK: Private state

    private var lastSampleMs: Double?
    private var lastPresentedSeq: Int?
    private var nominalIntervalMs: Int?
    private var nextAlignedTickMs: Double?

    private var frameCount: Int
    private var timelineId: String?
    private var userFps: Double

    private var hwSamples: [RateSample] = []
    private var ignoreRateUntilSeq: Int = 0

    private var previewSpeedMultiplier: Double = 1
    private var previewTargetSpeedMultiplier: Double = 1
    private var lastSpeedUpdateMs: Double?

    public init(frameCount: Int, userFps: Double) {
        self.frameCount = frameCount
        self.userFps = userFps
        self.measuredFps = userFps
        self.previewIntervalMs = userFps > 0 ? 1000.0 / userFps : 100
    }

    /// Binds the controller to a new firmware scroll session, resetting all
    /// transient PLL state (rate window, phase filter, display index).
    public mutating func bind(timelineId: String, frameCount: Int) {
        self.timelineId = timelineId
        self.frameCount = frameCount
        reset()
    }

    /// Resets transient state without forgetting the bound identity.
    public mutating func reset() {
        lastSampleMs = nil
        lastPresentedSeq = nil
        nominalIntervalMs = nil
        nextAlignedTickMs = nil
        displayIndex = 0
        phaseError = 0
        lockState = .free
        hwSamples.removeAll()
        ignoreRateUntilSeq = 0
        previewSpeedMultiplier = 1
        previewTargetSpeedMultiplier = 1
        lastSpeedUpdateMs = nil
        measuredFps = userFps
        previewIntervalMs = userFps > 0 ? 1000.0 / userFps : 100
    }

    /// Advances the local preview by exactly one frame on the ring.
    public mutating func tick() {
        guard frameCount > 0 else { return }
        displayIndex = ((displayIndex % frameCount) + frameCount) % frameCount
        displayIndex = (displayIndex + 1) % frameCount
    }

    /// Jumps the local preview straight to `index` after an app-initiated seek,
    /// without waiting for the board's echo. The phase filter is cleared so the
    /// jump is not slewed in as drift.
    public mutating func snap(to index: Int) {
        guard frameCount > 0 else { return }
        displayIndex = ((index % frameCount) + frameCount) % frameCount
        phaseError = 0
        lockState = .free
        // Pre-jump samples would unwrap across the jump as a burst of frames
        // and inflate the regressed speed.
        hwSamples.removeAll()
    }

    /// Consumes one `preview` sample: identity guard, pause/step snap, phase
    /// filtering, and (when rate-eligible) rate estimation.
    public mutating func record(sample: PreviewSync, nowMs: Double) -> RecordOutcome {
        guard sample.valid != false else { return .ok }
        guard
            let fc = sample.presentedFrameCount ?? sample.frameCount, fc > 0,
            let frameIndex = sample.presentedFrameIndex ?? sample.frameIndex,
            let seq = sample.presentedSeq
        else { return .ok }

        if let tid = timelineId, let sampleTid = sample.scrollTimelineId, !sampleTid.isEmpty, sampleTid != tid {
            return .identityMismatch
        }
        if fc != frameCount {
            return .identityMismatch
        }

        // Ignore duplicated/out-of-order presentation packets, but still accept
        // pause changes carried on the same latched frame.
        if let previous = lastPresentedSeq, seq < previous { return .ok }
        let duplicate = lastPresentedSeq == seq
        let needsAnchor = lastSampleMs == nil || nowMs - (lastSampleMs ?? nowMs) > 1500
        lastSampleMs = nowMs
        lastPresentedSeq = seq
        if let interval = sample.scrollIntervalMs, interval > 0, interval != nominalIntervalMs {
            nominalIntervalMs = interval
            measuredFps = 1000 / Double(interval)
            previewIntervalMs = Double(interval)
            hwSamples.removeAll()
        }
        let source = sample.source ?? ""
        let paused = sample.firmwareScrollPaused == true
        let stepping = Self.steppingSources.contains(source)

        if paused || stepping {
            let normalized = ((frameIndex % frameCount) + frameCount) % frameCount
            displayIndex = normalized
            ignoreRateUntilSeq = max(ignoreRateUntilSeq, seq + 2)
            lockState = .free
            phaseError = 0
            hwSamples.removeAll()
            if !paused {
                let age = max(0, Double((sample.sampledAtUs ?? sample.presentedAtUs ?? 0)
                    - (sample.presentedAtUs ?? 0)) / 1000)
                nextAlignedTickMs = nowMs + max(1, previewIntervalMs - age)
            } else { nextAlignedTickMs = nil }
            return .snapped(normalized)
        }

        if duplicate { return .ok }
        if needsAnchor || abs(shortestRingDelta(frameIndex, displayIndex, frameCount)) > 2 {
            displayIndex = ((frameIndex % frameCount) + frameCount) % frameCount
            phaseError = 0
            let ageMs: Double
            if let sampled = sample.sampledAtUs, let presented = sample.presentedAtUs {
                ageMs = max(0, Double(sampled - presented) / 1000)
            } else { ageMs = 0 }
            nextAlignedTickMs = nowMs + max(1, previewIntervalMs - ageMs)
            if needsAnchor { hwSamples.removeAll() }
        }
        let err = shortestRingDelta(frameIndex, displayIndex, frameCount)
        phaseError = phaseError * (1 - Self.phaseAlpha) + err * Self.phaseAlpha

        let rateEligible = sample.rateEligible == true
        let continuousTick = !Self.discontinuousRateSources.contains(source)
        if rateEligible, seq > ignoreRateUntilSeq, continuousTick, let presentedAtUs = sample.presentedAtUs {
            let tMs = Double(presentedAtUs) / 1000.0
            if let last = hwSamples.last {
                if seq > last.seq, tMs > last.tMs {
                    let delta: Int
                    if let advance = sample.scrollAdvanceSeq, let previous = last.advanceSeq {
                        delta = Int(advance &- previous)
                    } else {
                        delta = forwardFrameDelta(frameIndex, last.frameIndex, frameCount)
                    }
                    hwSamples.append(RateSample(seq: seq, advanceSeq: sample.scrollAdvanceSeq, tMs: tMs, frameIndex: frameIndex, unwrappedFrame: last.unwrappedFrame + delta))
                }
            } else {
                hwSamples.append(RateSample(seq: seq, advanceSeq: sample.scrollAdvanceSeq, tMs: tMs, frameIndex: frameIndex, unwrappedFrame: frameIndex))
            }
            let cutoff = tMs - Self.hwRateWindowMs
            while hwSamples.count > 2, hwSamples[0].tMs < cutoff {
                hwSamples.removeFirst()
            }
            if let fps = estimateFpsByRegression() {
                applyMeasuredFps(fps)
            }
        }
        return .ok
    }

    private func estimateFpsByRegression() -> Double? {
        guard hwSamples.count >= Self.minSamples else { return nil }
        let first = hwSamples[0]
        let last = hwSamples[hwSamples.count - 1]
        let spanMs = last.tMs - first.tMs
        let spanFrames = last.unwrappedFrame - first.unwrappedFrame
        guard spanMs >= Self.minSpanMs, spanFrames >= Self.minFrames else { return nil }

        let t0 = first.tMs
        let n = Double(hwSamples.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for pt in hwSamples {
            let x = pt.tMs - t0
            let y = Double(pt.unwrappedFrame)
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let denom = n * sxx - sx * sx
        guard denom > 0 else { return nil }
        let fps = ((n * sxy - sx * sy) / denom) * 1000.0
        guard fps.isFinite, fps >= Self.fpsMin, fps <= Self.fpsMax else { return nil }
        return fps
    }

    private mutating func applyMeasuredFps(_ fps: Double) {
        measuredFps = measuredFps > 0 ? measuredFps * (1 - Self.emaAlpha) + fps * Self.emaAlpha : fps
        let nextInterval = max(1.0, 1000.0 / measuredFps)
        if previewIntervalMs <= 0 {
            previewIntervalMs = nextInterval
        } else {
            previewIntervalMs = previewIntervalMs * (1 - Self.intervalBlendAlpha) + nextInterval * Self.intervalBlendAlpha
        }
    }

    /// Speed controller: turns the low-passed phase error into a slew-limited
    /// speed multiplier and returns the delay (ms) until the next `tick()`.
    public mutating func nextDelayMs(nowMs: Double) -> Double {
        if let aligned = nextAlignedTickMs {
            nextAlignedTickMs = nil
            return max(1, aligned - nowMs)
        }
        guard timelineId != nil, frameCount > 0 else {
            lockState = .free
            previewSpeedMultiplier = 1
            previewTargetSpeedMultiplier = 1
            lastSpeedUpdateMs = nowMs
            return userFps > 0 ? 1000.0 / userFps : previewIntervalMs
        }

        let base = previewIntervalMs
        let err = phaseError
        let absErr = abs(err)
        let target: Double
        if absErr < Self.phaseDeadband {
            target = 1.0
            lockState = .locked
        } else {
            let horizonFrames = max(1.0, measuredFps * (Self.alignHorizonMs / 1000.0))
            let catchup = absErr >= Self.catchupThreshold
            lockState = catchup ? .catchup : .gentle
            let minMul = catchup ? Self.catchupMin : Self.gentleMin
            let maxMul = catchup ? Self.catchupMax : Self.gentleMax
            target = min(max(1 + err / horizonFrames, minMul), maxMul)
        }
        previewTargetSpeedMultiplier = target

        let last = lastSpeedUpdateMs ?? nowMs
        let dt = max(0, (nowMs - last) / 1000.0)
        lastSpeedUpdateMs = nowMs
        let maxDelta = Self.slewPerSec * dt
        let diff = min(max(target - previewSpeedMultiplier, -maxDelta), maxDelta)
        previewSpeedMultiplier += diff

        return max(1.0, (base / previewSpeedMultiplier).rounded())
    }
}

/// Signed shortest distance from `current` to `target` on a ring of
/// `frameCount`, in `[-frameCount/2, frameCount/2]`.
public func shortestRingDelta(_ target: Int, _ current: Int, _ frameCount: Int) -> Double {
    guard frameCount > 0 else { return 0 }
    let fc = Double(frameCount)
    var d = (Double(target - current)).truncatingRemainder(dividingBy: fc)
    if d < 0 { d += fc }
    if d > fc / 2 { d -= fc }
    return d
}

/// Forward (always non-negative) advance from `prevIndex` to `nextIndex` on
/// the ring, used to unwrap presented-frame samples for the rate estimator.
public func forwardFrameDelta(_ nextIndex: Int, _ prevIndex: Int, _ frameCount: Int) -> Int {
    guard frameCount > 0 else { return 0 }
    return (((nextIndex - prevIndex) % frameCount) + frameCount) % frameCount
}
