import XCTest
@testable import RinaCore

final class ScrollPreviewControllerTests: XCTestCase {
    // MARK: Ring delta math

    func testShortestRingDelta() {
        XCTAssertEqual(shortestRingDelta(1, 299, 300), 2)
        XCTAssertEqual(shortestRingDelta(299, 1, 300), -2)
        XCTAssertEqual(shortestRingDelta(0, 0, 300), 0)
    }

    // MARK: Steady-state rate lock

    func testLocksOntoSteadyTenFpsSamples() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        var nowMs: Double = 0
        var seq = 1
        var frameIndex = 0
        // Feed 5 s of samples at exactly 10 fps (100 ms apart), keeping the
        // local display index perfectly in step so the phase error stays 0.
        while nowMs <= 5000 {
            let sample = PreviewSync(
                presentedSeq: seq,
                source: "tick",
                scrollTimelineId: "tl-1",
                presentedFrameIndex: frameIndex,
                presentedFrameCount: 300,
                presentedAtUs: Int64(nowMs * 1000),
                firmwareScrollActive: true,
                firmwareScrollPaused: false,
                rateEligible: true
            )
            let outcome = controller.record(sample: sample, nowMs: nowMs)
            XCTAssertEqual(outcome, .ok)
            _ = controller.nextDelayMs(nowMs: nowMs)
            controller.tick()

            nowMs += 100
            seq += 1
            frameIndex = (frameIndex + 1) % 300
        }

        XCTAssertEqual(controller.measuredFps, 10, accuracy: 0.5, "measured fps should be within 5% of 10")
        XCTAssertEqual(controller.lockState, .locked)
    }

    // MARK: Phase catch-up / lead

    func testLaggingDisplayIndexTriggersCatchup() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        // Prime measuredFps so `base` and `horizonFrames` are sane, then feed
        // a single sample where the firmware is 6 frames ahead of our display.
        let sample = PreviewSync(
            presentedSeq: 10,
            source: "tick",
            scrollTimelineId: "tl-1",
            presentedFrameIndex: 6,
            presentedFrameCount: 300,
            presentedAtUs: 1_000_000,
            firmwareScrollActive: true,
            firmwareScrollPaused: false,
            rateEligible: true
        )
        // displayIndex starts at 0; feed the sample 4 times so the low-passed
        // phase error converges close to the raw +6 delta.
        for _ in 0..<4 {
            _ = controller.record(sample: sample, nowMs: 0)
        }
        // Prime `lastSpeedUpdateMs` at t=0 (no slew yet), then advance wall
        // time so the multiplier has room to slew toward the target.
        _ = controller.nextDelayMs(nowMs: 0)
        let delay = controller.nextDelayMs(nowMs: 1000)
        XCTAssertEqual(controller.lockState, .catchup)
        XCTAssertLessThan(delay, controller.previewIntervalMs)
    }

    func testLeadingDisplayIndexSlowsDown() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        // Push displayIndex ahead of the firmware by ticking first, then feed
        // a sample where the firmware is 6 frames behind our display.
        for _ in 0..<6 { controller.tick() }
        let sample = PreviewSync(
            presentedSeq: 10,
            source: "tick",
            scrollTimelineId: "tl-1",
            presentedFrameIndex: 0,
            presentedFrameCount: 300,
            presentedAtUs: 1_000_000,
            firmwareScrollActive: true,
            firmwareScrollPaused: false,
            rateEligible: true
        )
        for _ in 0..<4 {
            _ = controller.record(sample: sample, nowMs: 0)
        }
        _ = controller.nextDelayMs(nowMs: 0)
        let delay = controller.nextDelayMs(nowMs: 1000)
        XCTAssertEqual(controller.lockState, .catchup)
        XCTAssertGreaterThan(delay, controller.previewIntervalMs)
    }

    // MARK: Identity mismatch

    func testIdentityMismatchOnTimelineChange() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        let sample = PreviewSync(
            presentedSeq: 1,
            source: "tick",
            scrollTimelineId: "tl-2",
            presentedFrameIndex: 0,
            presentedFrameCount: 300,
            presentedAtUs: 0,
            firmwareScrollActive: true,
            firmwareScrollPaused: false,
            rateEligible: true
        )
        XCTAssertEqual(controller.record(sample: sample, nowMs: 0), .identityMismatch)
    }

    func testIdentityMismatchOnFrameCountChange() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        let sample = PreviewSync(
            presentedSeq: 1,
            source: "tick",
            scrollTimelineId: "tl-1",
            presentedFrameIndex: 0,
            presentedFrameCount: 150,
            presentedAtUs: 0,
            firmwareScrollActive: true,
            firmwareScrollPaused: false,
            rateEligible: true
        )
        XCTAssertEqual(controller.record(sample: sample, nowMs: 0), .identityMismatch)
    }

    // MARK: Paused sample snaps

    func testPausedSampleSnapsDisplayIndex() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        let sample = PreviewSync(
            presentedSeq: 5,
            source: "tick",
            scrollTimelineId: "tl-1",
            presentedFrameIndex: 42,
            presentedFrameCount: 300,
            presentedAtUs: 0,
            firmwareScrollActive: true,
            firmwareScrollPaused: true,
            rateEligible: false
        )
        let outcome = controller.record(sample: sample, nowMs: 0)
        XCTAssertEqual(outcome, .snapped(42))
        XCTAssertEqual(controller.displayIndex, 42)
    }

    func testSteppingSourceSnapsDisplayIndex() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        let sample = PreviewSync(
            presentedSeq: 5,
            source: "manual",
            scrollTimelineId: "tl-1",
            presentedFrameIndex: 7,
            presentedFrameCount: 300,
            presentedAtUs: 0,
            firmwareScrollActive: true,
            firmwareScrollPaused: false,
            rateEligible: false
        )
        let outcome = controller.record(sample: sample, nowMs: 0)
        XCTAssertEqual(outcome, .snapped(7))
    }
}
