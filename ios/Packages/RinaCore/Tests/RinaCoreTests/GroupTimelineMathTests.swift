import XCTest
@testable import RinaCore

/// `GroupSchedule.rolledForward` / `speedChange`: the timeline math behind a
/// rejoin after a reboot and a jump-free live speed change.
final class GroupTimelineMathTests: XCTestCase {
    private typealias Anchor = GroupSchedule.Anchor

    // MARK: rolledForward

    func testRollForwardKeepsTheSameFrameAtEveryInstant() {
        let old = Anchor(phoneUs: 1_000_000, startFrame: 7, intervalMs: 50, loop: true)
        let rolled = GroupSchedule.rolledForward(old, notBeforeUs: 61_234_567, frameCount: 300)
        XCTAssertGreaterThanOrEqual(rolled.phoneUs, 61_234_567)
        XCTAssertLessThan(rolled.phoneUs - 61_234_567, 50_000)
        for t in stride(from: rolled.phoneUs, to: rolled.phoneUs + 3_000_000, by: 7_919) {
            XCTAssertEqual(GroupSchedule.frame(of: rolled, atPhoneUs: t, frameCount: 300),
                           GroupSchedule.frame(of: old, atPhoneUs: t, frameCount: 300))
        }
    }

    func testRollForwardNeverMovesBackwards() {
        let old = Anchor(phoneUs: 5_000_000, startFrame: 3, intervalMs: 17, loop: false)
        XCTAssertEqual(GroupSchedule.rolledForward(old, notBeforeUs: 4_000_000, frameCount: 100), old)
    }

    func testRollForwardWithoutLoopStopsOnLastFrame() {
        let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: 20, loop: false)
        let rolled = GroupSchedule.rolledForward(old, notBeforeUs: 10_000_000, frameCount: 40)
        XCTAssertEqual(rolled.startFrame, 39)
    }

    /// The rebooted-board case: an anchor older than the board's uptime maps
    /// to a negative board time; rolled forward to "now" it no longer does.
    func testRolledAnchorMapsToAPositiveBoardTimeAfterReboot() {
        let phoneNow: Int64 = 3_600_000_000 // group started an hour ago
        let old = Anchor(phoneUs: 1_000_000, startFrame: 0, intervalMs: 33, loop: true)
        var estimator = ClockOffsetEstimator()
        // The board rebooted 5 s ago: its clock reads 5 s at phone time `phoneNow`.
        let offset = 5_000_000 - phoneNow
        estimator.addSample(ClockSample(m1: phoneNow, b2: phoneNow + offset, b3: phoneNow + offset, m4: phoneNow),
                            bootId: "b")
        XCTAssertLessThan(estimator.boardTime(forPhone: old.phoneUs) ?? 0, 0)
        let rolled = GroupSchedule.rolledForward(old, notBeforeUs: phoneNow, frameCount: 500)
        XCTAssertGreaterThanOrEqual(estimator.boardTime(forPhone: rolled.phoneUs) ?? -1, 5_000_000)
    }

    // MARK: speedChange

    func testSpeedChangeAnchorIsNeverInTheFuture() {
        let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: 50, loop: true)
        let new = GroupSchedule.speedChange(from: old, intervalMs: 17, loop: true, frameCount: 400,
                                            sendAtUs: 10_012_345, switchNotBeforeUs: 10_072_345)
        XCTAssertLessThanOrEqual(new.phoneUs, 10_012_345)
    }

    /// From the switch instant on, the new timeline runs at the new rate from
    /// exactly the frame the old one reached: nothing skipped, and that frame
    /// starts fresh at the switch.
    func testSpeedChangeContinuesFromTheOldFrameAtASwitchBoundary() {
        let old = Anchor(phoneUs: 1_000_000, startFrame: 12, intervalMs: 50, loop: true)
        let send: Int64 = 9_987_654
        let new = GroupSchedule.speedChange(from: old, intervalMs: 25, loop: true, frameCount: 300,
                                            sendAtUs: send, switchNotBeforeUs: send + 60_000)
        let switchUs = old.phoneUs + ((send + 60_000 - old.phoneUs + 49_999) / 50_000) * 50_000
        let atSwitch = GroupSchedule.frame(of: old, atPhoneUs: switchUs, frameCount: 300)
        XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: switchUs, frameCount: 300), atSwitch)
        XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: switchUs + 24_999, frameCount: 300), atSwitch)
        XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: switchUs + 25_000, frameCount: 300), (atSwitch + 1) % 300)
    }

    /// Before the switch instant, a board that already has the new timeline
    /// is at most one frame away from one still on the old timeline.
    func testSpeedChangeEarlyErrorStaysBelowOneFrame() {
        for (oldMs, newMs) in [(50, 17), (17, 50), (33, 20), (20, 33), (100, 17)] {
            let old = Anchor(phoneUs: 0, startFrame: 5, intervalMs: oldMs, loop: true)
            let send: Int64 = 12_345_678
            let new = GroupSchedule.speedChange(from: old, intervalMs: newMs, loop: true, frameCount: 10_000,
                                                sendAtUs: send, switchNotBeforeUs: send + 40_000)
            for t in stride(from: send, to: send + 40_000, by: 997) {
                let a = GroupSchedule.frame(of: old, atPhoneUs: t, frameCount: 10_000)
                let b = GroupSchedule.frame(of: new, atPhoneUs: t, frameCount: 10_000)
                XCTAssertLessThanOrEqual(abs(a - b), 1 + 40_000 / (min(oldMs, newMs) * 1000),
                                         "old \(oldMs) new \(newMs) t \(t)")
            }
        }
    }

    func testSpeedChangeWrapsBackwardsAcrossFrameZeroWhenLooping() {
        let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: 50, loop: true)
        let new = GroupSchedule.speedChange(from: old, intervalMs: 17, loop: true, frameCount: 100,
                                            sendAtUs: 0, switchNotBeforeUs: 60_000)
        XCTAssertTrue((0..<100).contains(new.startFrame))
        XCTAssertLessThanOrEqual(new.phoneUs, 0)
        XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: 100_000, frameCount: 100), 2)
    }

    func testSpeedChangeWithoutLoopNeverWalksBelowFrameZero() {
        let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: 50, loop: false)
        let new = GroupSchedule.speedChange(from: old, intervalMs: 17, loop: false, frameCount: 100,
                                            sendAtUs: 0, switchNotBeforeUs: 60_000)
        XCTAssertEqual(new.startFrame, 0)
        XCTAssertGreaterThanOrEqual(new.phoneUs, 0)
    }

    func testSpeedChangeOnAFinishedNonLoopingTimelineStaysOnTheLastFrame() {
        let old = Anchor(phoneUs: 0, startFrame: 0, intervalMs: 20, loop: false)
        let new = GroupSchedule.speedChange(from: old, intervalMs: 50, loop: false, frameCount: 30,
                                            sendAtUs: 5_000_000, switchNotBeforeUs: 5_050_000)
        XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: 6_000_000, frameCount: 30), 29)
    }

    func testRandomSpeedChangesKeepTheSwitchFrame() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let n = Int.random(in: 1...2_000, using: &rng)
            let loop = Bool.random(using: &rng)
            let old = Anchor(phoneUs: Int64.random(in: 0...10_000_000, using: &rng),
                             startFrame: Int.random(in: 0..<n, using: &rng),
                             intervalMs: Int.random(in: 17...1000, using: &rng), loop: loop)
            let send = old.phoneUs + Int64.random(in: -1_000_000...60_000_000, using: &rng)
            let lead = Int64.random(in: 0...400_000, using: &rng)
            let newLoop = Bool.random(using: &rng)
            let new = GroupSchedule.speedChange(from: old, intervalMs: Int.random(in: 17...1000, using: &rng),
                                                loop: newLoop, frameCount: n,
                                                sendAtUs: send, switchNotBeforeUs: send + lead)
            XCTAssertTrue((0..<n).contains(new.startFrame))
            if newLoop || new.startFrame > 0 { XCTAssertLessThanOrEqual(new.phoneUs, send) }
            let target = max(send + lead, send)
            let steps = target > old.phoneUs ? (target - old.phoneUs + old.intervalUs - 1) / old.intervalUs : 0
            let switchUs = old.phoneUs + steps * old.intervalUs
            let expected = GroupSchedule.frame(of: old, atPhoneUs: switchUs, frameCount: n)
            XCTAssertEqual(GroupSchedule.frame(of: new, atPhoneUs: switchUs, frameCount: n), expected)
        }
    }
}
