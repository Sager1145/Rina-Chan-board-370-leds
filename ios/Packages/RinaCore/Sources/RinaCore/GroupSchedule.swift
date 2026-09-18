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
}
