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

    /// The same timeline re-expressed with an anchor time no earlier than
    /// `notBeforeUs`, moved forward by whole frames so every board keeps
    /// showing the same frame at the same instant.
    ///
    /// A rejoin sends the group's anchor mapped onto the board's clock. A
    /// board that rebooted has a clock that started seconds ago, so an old
    /// anchor maps to a negative `atUs`, which firmware rejects. Rolling the
    /// anchor forward to "now" keeps the mapped time inside the board's
    /// uptime. Never moves an anchor backwards.
    public static func rolledForward(_ anchor: Anchor, notBeforeUs: Int64, frameCount: Int) -> Anchor {
        guard notBeforeUs > anchor.phoneUs else { return anchor }
        let intervalUs = anchor.intervalUs
        let steps = (notBeforeUs - anchor.phoneUs + intervalUs - 1) / intervalUs
        var out = anchor
        out.phoneUs = anchor.phoneUs + steps * intervalUs
        out.startFrame = anchor.frame(advancedBy: steps, frameCount: frameCount)
        return out
    }

    /// The anchor for a live speed/loop change that boards can apply the
    /// moment they receive it, with no jump.
    ///
    /// Firmware applies a `group_start` on receipt and holds `startFrame`
    /// until `atUs`. Sending a future `atUs` therefore makes a playing board
    /// jump ahead to that frame and freeze until then. Instead:
    ///
    /// 1. The switch instant `T` is the first frame boundary of the old
    ///    timeline at or after `switchNotBeforeUs`, so the frame shown at `T`
    ///    starts fresh and no part of it is lost.
    /// 2. The new timeline passes through (`T`, frame at `T`) and is walked
    ///    back by whole new-rate frames to an anchor at or before
    ///    `sendAtUs`, so no board ever sees a future `atUs` and holds.
    ///
    /// Between receipt and `T` a board runs the new rate a little early; the
    /// error is below one frame when `T - sendAtUs` is about one round trip.
    /// Without looping the walk-back stops at frame 0, which can leave a
    /// short hold on a timeline that has only just started.
    public static func speedChange(
        from old: Anchor,
        intervalMs: Int,
        loop: Bool,
        frameCount: Int,
        sendAtUs: Int64,
        switchNotBeforeUs: Int64
    ) -> Anchor {
        let oldIntervalUs = old.intervalUs
        let target = max(switchNotBeforeUs, sendAtUs)
        let oldSteps = target > old.phoneUs ? (target - old.phoneUs + oldIntervalUs - 1) / oldIntervalUs : 0
        let switchUs = old.phoneUs + oldSteps * oldIntervalUs
        let switchFrame = old.frame(advancedBy: oldSteps, frameCount: frameCount)

        let next = Anchor(phoneUs: switchUs, startFrame: switchFrame, intervalMs: intervalMs, loop: loop)
        let newIntervalUs = next.intervalUs
        var backSteps = switchUs > sendAtUs ? (switchUs - sendAtUs + newIntervalUs - 1) / newIntervalUs : 0
        if !loop { backSteps = min(backSteps, Int64(switchFrame)) }
        var out = next
        out.phoneUs = switchUs - backSteps * newIntervalUs
        out.startFrame = next.frame(advancedBy: -backSteps, frameCount: frameCount)
        return out
    }

    /// The global frame `anchor` shows at `phoneUs` (its `startFrame` before
    /// the anchor time).
    public static func frame(of anchor: Anchor, atPhoneUs phoneUs: Int64, frameCount: Int) -> Int {
        let steps = phoneUs > anchor.phoneUs ? (phoneUs - anchor.phoneUs) / anchor.intervalUs : 0
        return anchor.frame(advancedBy: steps, frameCount: frameCount)
    }
}
