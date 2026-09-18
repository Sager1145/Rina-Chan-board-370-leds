import XCTest
@testable import RinaCore

final class GroupScheduleTests: XCTestCase {
    private func estimator(offsetUs: Int64, bootId: String) -> ClockOffsetEstimator {
        var e = ClockOffsetEstimator()
        // m1=0, m4=2*offsetUs magnitude irrelevant to rtt=0 case; craft b2/b3 so offsetUs matches exactly.
        e.addSample(ClockSample(m1: 0, b2: offsetUs, b3: offsetUs, m4: 0), bootId: bootId)
        return e
    }

    func testStartCommandsMapPhoneTimeThroughEachBoardsEstimate() {
        let estimators: [String: ClockOffsetEstimator] = [
            "A": estimator(offsetUs: 100, bootId: "boot-a"),
            "B": estimator(offsetUs: -50, bootId: "boot-b"),
        ]
        let bootIds = ["A": "boot-a", "B": "boot-b"]
        let commands = GroupSchedule.startCommands(
            phoneStartUs: 1_000_000, estimators: estimators, bootIds: bootIds, intervalMs: 120
        )
        XCTAssertEqual(commands.count, 2)
        guard case .groupStart(let atUsA, let bootIdA, let intervalMsA, let startFrameA, let loopA)? = commands["A"] else {
            return XCTFail("missing A")
        }
        XCTAssertEqual(atUsA, 1_000_100)
        XCTAssertEqual(bootIdA, "boot-a")
        XCTAssertEqual(intervalMsA, 120)
        XCTAssertNil(startFrameA)
        XCTAssertNil(loopA)
        guard case .groupStart(let atUsB, _, _, _, _)? = commands["B"] else { return XCTFail("missing B") }
        XCTAssertEqual(atUsB, 999_950)
    }

    /// A board with no clock sample yet is omitted, never silently defaulted.
    func testBoardWithoutSampleIsOmitted() {
        let estimators: [String: ClockOffsetEstimator] = [
            "A": estimator(offsetUs: 100, bootId: "boot-a"),
            "B": ClockOffsetEstimator(),
        ]
        let bootIds = ["A": "boot-a", "B": "boot-b"]
        let commands = GroupSchedule.startCommands(
            phoneStartUs: 1_000_000, estimators: estimators, bootIds: bootIds, intervalMs: 120
        )
        XCTAssertEqual(commands.count, 1)
        XCTAssertNotNil(commands["A"])
        XCTAssertNil(commands["B"])
    }

    /// A stale estimator (samples from a previous boot) must not be used.
    func testBoardWithStaleBootIdIsOmitted() {
        let estimators: [String: ClockOffsetEstimator] = [
            "A": estimator(offsetUs: 100, bootId: "old-boot"),
        ]
        let bootIds = ["A": "new-boot"]
        let commands = GroupSchedule.startCommands(
            phoneStartUs: 1_000_000, estimators: estimators, bootIds: bootIds, intervalMs: 120
        )
        XCTAssertTrue(commands.isEmpty)
    }

    func testReanchorCommandsUseCurrentEstimateAndStartFrame() {
        let estimators: [String: ClockOffsetEstimator] = ["A": estimator(offsetUs: 200, bootId: "boot-a")]
        let bootIds = ["A": "boot-a"]
        let commands = GroupSchedule.reanchorCommands(
            phoneAnchorUs: 500_000, startFrame: 42, intervalMs: 80, loop: false,
            estimators: estimators, bootIds: bootIds
        )
        guard case .groupStart(let atUs, let bootId, let intervalMs, let startFrame, let loop)? = commands["A"] else {
            return XCTFail("missing A")
        }
        XCTAssertEqual(atUs, 500_200)
        XCTAssertEqual(bootId, "boot-a")
        XCTAssertEqual(intervalMs, 80)
        XCTAssertEqual(startFrame, 42)
        XCTAssertEqual(loop, false)
    }
}
