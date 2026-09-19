import XCTest
@testable import RinaCore

/// `GroupSchedule.rolledForward` / `speedChange`: the timeline math behind a
/// rejoin after a reboot and a jump-free live speed change.
final class GroupTimelineMathTests: XCTestCase {
    private typealias Anchor = GroupSchedule.Anchor

    /// Distance between two frames on a looping ring of `n` frames.
    private func ringDistance(_ a: Int, _ b: Int, _ n: Int) -> Int {
        let d = abs(a - b) % n
        return min(d, n - d)
    }

    // MARK: rolledForward

    func testRollForwardKeepsTheSameFrameAtEveryInstant() {
        let old = Anchor(phoneUs: 1_000_000, startFrame: 7, intervalMs: 50, loop: true)
        let rolled = GroupSchedule.rolledForward(old, toUs: 61_234_567, frameCount: 300)
        XCTAssertLessThanOrEqual(rolled.phoneUs, 61_234_567)
        XCTAssertLessThan(61_234_567 - rolled.phoneUs, 50_000)
        for t in stride(from: rolled.phoneUs, to: rolled.phoneUs + 3_000_000, by: 7_919) {
            XCTAssertEqual(GroupSchedule.frame(of: rolled, atPhoneUs: t, frameCount: 300),
                           GroupSchedule.frame(of: old, atPhoneUs: t, frameCount: 300))
        }
    }

    /// Rounding up would put the anchor in the future, and firmware would
    /// show the next frame early and hold it.
    func testRollForwardNeverLandsInTheFuture() {
        for interval in [17, 33, 50, 1000] {
            let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: interval, loop: true)
            for to in stride(from: Int64(1), to: 5_000_000, by: 12_347) {
                XCTAssertLessThanOrEqual(GroupSchedule.rolledForward(old, toUs: to, frameCount: 500).phoneUs, to)
            }
        }
    }

    func testRollForwardNeverMovesBackwards() {
        let old = Anchor(phoneUs: 5_000_000, startFrame: 3, intervalMs: 17, loop: false)
        XCTAssertEqual(GroupSchedule.rolledForward(old, toUs: 4_000_000, frameCount: 100), old)
    }

    func testRollForwardWithoutLoopStopsOnLastFrame() {
        let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: 20, loop: false)
        let rolled = GroupSchedule.rolledForward(old, toUs: 10_000_000, frameCount: 40)
        XCTAssertEqual(rolled.startFrame, 39)
    }

    /// The rebooted-board case: an anchor older than the board's uptime maps
    /// to a negative board time; rolled up to "now" it no longer does.
    func testRolledAnchorMapsToAPositiveBoardTimeAfterReboot() {
        let phoneNow: Int64 = 3_600_000_000 // group started an hour ago
        let old = Anchor(phoneUs: 1_000_000, startFrame: 0, intervalMs: 1000, loop: true)
        var estimator = ClockOffsetEstimator()
        // The board rebooted 5 s ago: its clock reads 5 s at phone time `phoneNow`.
        let offset = 5_000_000 - phoneNow
        estimator.addSample(ClockSample(m1: phoneNow, b2: phoneNow + offset, b3: phoneNow + offset, m4: phoneNow),
                            bootId: "b")
        XCTAssertLessThan(estimator.boardTime(forPhone: old.phoneUs) ?? 0, 0)
        let rolled = GroupSchedule.rolledForward(old, toUs: phoneNow, frameCount: 500)
        XCTAssertGreaterThanOrEqual(estimator.boardTime(forPhone: rolled.phoneUs) ?? -1, 4_000_000)
    }

    // MARK: speedChange

    /// At the switch instant the new timeline shows the old frame, with the
    /// same share of it already elapsed.
    func testSpeedChangeKeepsFrameAndPhaseAtTheSwitch() {
        let old = Anchor(phoneUs: 1_000_000, startFrame: 12, intervalMs: 50, loop: true)
        // 30 ms into frame 12 + 180 = 192.
        let switchUs: Int64 = 1_000_000 + 180 * 50_000 + 30_000
        let new = GroupSchedule.speedChange(from: old, intervalMs: 25, loop: true, frameCount: 300, switchUs: switchUs)
        XCTAssertEqual(new.startFrame, 192)
        XCTAssertEqual(new.phoneUs, switchUs - 15_000) // 60 % of a 25 ms frame already shown
        XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: switchUs + 9_999, frameCount: 300), 192)
        XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: switchUs + 10_000, frameCount: 300), 193)
    }

    /// A board that applies the change up to `delay` before or after the
    /// switch instant is at most about `delay / interval` + 1 frames away
    /// from where it should be — for every speed ratio, including 1 → 60
    /// fps, which the boundary-aligned version got badly wrong.
    func testSpeedChangeErrorAroundTheSwitchIsBoundedByTheDelay() {
        let n = 10_000
        let delay: Int64 = 20_000
        for (oldMs, newMs) in [(1000, 17), (500, 17), (100, 17), (50, 17), (17, 50), (17, 1000), (33, 20), (20, 33)] {
            let old = Anchor(phoneUs: 0, startFrame: 5, intervalMs: oldMs, loop: true)
            for switchUs in stride(from: Int64(3_000_000), to: 3_000_000 + Int64(oldMs) * 1000, by: 3_331) {
                let new = GroupSchedule.speedChange(from: old, intervalMs: newMs, loop: true, frameCount: n,
                                                    switchUs: switchUs)
                XCTAssertLessThanOrEqual(new.phoneUs, switchUs)
                let bound = 1 + Int(delay / Int64(min(oldMs, newMs) * 1000))
                for r in stride(from: switchUs - delay, through: switchUs + delay, by: 1_009) {
                    let expected = r < switchUs
                        ? GroupSchedule.frame(of: old, atPhoneUs: r, frameCount: n)
                        : GroupSchedule.frame(of: new, atPhoneUs: r, frameCount: n)
                    let applied = GroupSchedule.frame(of: new, atPhoneUs: r, frameCount: n)
                    let beforeSwitch = GroupSchedule.frame(of: old, atPhoneUs: r, frameCount: n)
                    XCTAssertLessThanOrEqual(ringDistance(applied, expected, n), bound, "\(oldMs)→\(newMs) r \(r)")
                    XCTAssertLessThanOrEqual(ringDistance(applied, beforeSwitch, n), bound, "\(oldMs)→\(newMs) r \(r)")
                }
            }
        }
    }

    func testSpeedChangeOnAFinishedNonLoopingTimelineStaysOnTheLastFrame() {
        let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: 20, loop: false)
        let new = GroupSchedule.speedChange(from: old, intervalMs: 50, loop: false, frameCount: 30, switchUs: 5_000_000)
        XCTAssertEqual(new.startFrame, 29)
        for t in stride(from: Int64(4_000_000), to: 8_000_000, by: 77_777) {
            XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: t, frameCount: 30), 29)
        }
    }

    func testSpeedChangeBeforeTheAnchorKeepsItsStartFrame() {
        let old = Anchor(phoneUs: 2_000_000, startFrame: 40, intervalMs: 50, loop: true)
        let new = GroupSchedule.speedChange(from: old, intervalMs: 17, loop: true, frameCount: 100, switchUs: 1_500_000)
        XCTAssertEqual(new.phoneUs, 2_000_000)
        XCTAssertEqual(new.startFrame, 40)
    }

    func testRandomSpeedChangesAreContinuousAtTheSwitch() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let n = Int.random(in: 1...2_000, using: &rng)
            let old = Anchor(phoneUs: Int64.random(in: 0...10_000_000, using: &rng),
                             startFrame: Int.random(in: 0..<n, using: &rng),
                             intervalMs: Int.random(in: 17...1000, using: &rng), loop: Bool.random(using: &rng))
            let switchUs = old.phoneUs + Int64.random(in: -1_000_000...60_000_000, using: &rng)
            let new = GroupSchedule.speedChange(from: old, intervalMs: Int.random(in: 17...1000, using: &rng),
                                                loop: Bool.random(using: &rng), frameCount: n, switchUs: switchUs)
            XCTAssertTrue((0..<n).contains(new.startFrame))
            XCTAssertLessThanOrEqual(new.phoneUs, max(switchUs, old.phoneUs))
            XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: switchUs, frameCount: n),
                           GroupSchedule.frame(of: old, atPhoneUs: switchUs, frameCount: n))
        }
    }
}
