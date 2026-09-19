import Foundation

/// Pure scheduling helpers that turn a shared phone-clock anchor into each
/// board's `group_start{atUs, bootId, ...}` command (BOARD_GROUP_SPEC.md
/// §1.5/§2), via each board's `ClockOffsetEstimator`. Contains no networking
/// or timers — callers (the app's `BoardGroupCoordinator`) own those.
public enum GroupSchedule {
    /// Maps a desired phone start time to each board's `group_start` command,
    /// via `estimator.boardTime(forPhone:)`. A board is omitted from the
    /// result when its estimator has no sample yet (`offsetUs == nil`) or its
    /// estimator's `bootId` doesn't match the board's current `bootId` — the
    /// caller must treat a missing entry as "cannot start this board yet",
    /// never silently skip it while claiming the group started.
    public static func startCommands<Key: Hashable & Sendable>(
        phoneStartUs: Int64,
        estimators: [Key: ClockOffsetEstimator],
        bootIds: [Key: String],
        intervalMs: Int,
        startFrame: Int? = nil,
        loop: Bool? = nil
    ) -> [Key: RinaCommand] {
        var out: [Key: RinaCommand] = [:]
        for (key, estimator) in estimators {
            guard let bootId = bootIds[key], estimator.bootId == bootId,
                  let atUs = estimator.boardTime(forPhone: phoneStartUs) else { continue }
            out[key] = .groupStart(
                atUs: atUs, bootId: bootId, intervalMs: intervalMs, startFrame: startFrame, loop: loop
            )
        }
        return out
    }

    /// Re-anchors a running group: the group's anchor is one phone time
    /// (`phoneAnchorUs`) plus `startFrame` (BOARD_GROUP_SPEC.md §1.5's
    /// "replaces (atUs, startFrame, intervalMs, loop) atomically"); returns
    /// each board's replacement `group_start` command mapped through its
    /// *current* (possibly updated) clock estimate. Same omission rule as
    /// `startCommands`.
    public static func reanchorCommands<Key: Hashable & Sendable>(
        phoneAnchorUs: Int64,
        startFrame: Int,
        intervalMs: Int,
        loop: Bool? = nil,
        estimators: [Key: ClockOffsetEstimator],
        bootIds: [Key: String]
    ) -> [Key: RinaCommand] {
        startCommands(
            phoneStartUs: phoneAnchorUs, estimators: estimators, bootIds: bootIds,
            intervalMs: intervalMs, startFrame: startFrame, loop: loop
        )
    }

    /// A group timeline: global frame `startFrame` is shown at phone time
    /// `phoneUs`, then advances one frame per `intervalMs` (wrapping when
    /// `loop`, otherwise stopping on the last frame).
    public struct Anchor: Equatable, Sendable {
        public var phoneUs: Int64
        public var startFrame: Int
        public var intervalMs: Int
        public var loop: Bool

        public init(phoneUs: Int64, startFrame: Int, intervalMs: Int, loop: Bool) {
            self.phoneUs = phoneUs
            self.startFrame = startFrame
            self.intervalMs = intervalMs
            self.loop = loop
        }

        var intervalUs: Int64 { Int64(max(intervalMs, 1)) * 1000 }

        /// `startFrame + steps`, wrapped (loop) or clamped (no loop).
        func frame(advancedBy steps: Int64, frameCount: Int) -> Int {
            guard frameCount > 0 else { return 0 }
            let raw = Int64(startFrame) + steps
            if loop {
                let m = Int64(frameCount)
                return Int(((raw % m) + m) % m)
            }
            return Int(min(max(raw, 0), Int64(frameCount - 1)))
        }
    }

    /// The same timeline re-expressed with its anchor at the last frame
    /// boundary at or before `toUs`, so every board keeps showing the same
    /// frame at the same instant.
    ///
    /// A rejoin sends the group's anchor mapped onto the board's clock. A
    /// board that rebooted has a clock that started seconds ago, so an old
    /// anchor maps to a negative `atUs`, which firmware rejects. Rolling the
    /// anchor up to "now" keeps the mapped time inside the board's uptime.
    /// It rounds down, never up: firmware holds `startFrame` until `atUs`,
    /// so an anchor even one frame in the future would show the next frame
    /// early and freeze on it. Never moves an anchor backwards.
    public static func rolledForward(_ anchor: Anchor, toUs: Int64, frameCount: Int) -> Anchor {
        guard toUs > anchor.phoneUs else { return anchor }
        let intervalUs = anchor.intervalUs
        let steps = (toUs - anchor.phoneUs) / intervalUs
        var out = anchor
        out.phoneUs = anchor.phoneUs + steps * intervalUs
        out.startFrame = anchor.frame(advancedBy: steps, frameCount: frameCount)
        return out
    }

    /// The anchor for a live speed/loop change taking effect at `switchUs`,
    /// continuing from exactly where the old timeline is at that instant:
    /// the same frame, and the same fraction of that frame already shown.
    ///
    /// Firmware applies a `group_start` on receipt and holds `startFrame`
    /// until `atUs`. The old code re-anchored at a future instant, so a
    /// playing board jumped ahead to that frame and froze until then. Here
    /// the anchor sits at `switchUs` minus the elapsed part of the current
    /// frame (rescaled to the new interval), so it is never later than
    /// `switchUs`, and a board that applies the change at `switchUs` shows
    /// no jump at all. A board that applies it a little earlier or later is
    /// off by about that delay divided by the frame interval.
    ///
    /// A finished non-looping timeline stays on its last frame. Before the
    /// old anchor time, the old `startFrame` is kept and only re-timed.
    public static func speedChange(
        from old: Anchor,
        intervalMs: Int,
        loop: Bool,
        frameCount: Int,
        switchUs: Int64
    ) -> Anchor {
        let newIntervalUs = Int64(max(intervalMs, 1)) * 1000
        guard frameCount > 0 else {
            return Anchor(phoneUs: switchUs, startFrame: 0, intervalMs: intervalMs, loop: loop)
        }
        guard switchUs > old.phoneUs else {
            return Anchor(phoneUs: old.phoneUs, startFrame: old.startFrame, intervalMs: intervalMs, loop: loop)
        }
        let oldIntervalUs = old.intervalUs
        let elapsed = switchUs - old.phoneUs
        let steps = elapsed / oldIntervalUs
        if !old.loop, Int64(old.startFrame) + steps >= Int64(frameCount - 1) {
            return Anchor(phoneUs: switchUs, startFrame: frameCount - 1, intervalMs: intervalMs, loop: loop)
        }
        let intoFrameUs = elapsed - steps * oldIntervalUs
        let rescaled = intoFrameUs * newIntervalUs / oldIntervalUs
        return Anchor(phoneUs: switchUs - rescaled, startFrame: old.frame(advancedBy: steps, frameCount: frameCount),
                      intervalMs: intervalMs, loop: loop)
    }

    /// The global frame `anchor` shows at `phoneUs` (its `startFrame` before
    /// the anchor time).
    public static func frame(of anchor: Anchor, atPhoneUs phoneUs: Int64, frameCount: Int) -> Int {
        let steps = phoneUs > anchor.phoneUs ? (phoneUs - anchor.phoneUs) / anchor.intervalUs : 0
        return anchor.frame(advancedBy: steps, frameCount: frameCount)
    }
}
