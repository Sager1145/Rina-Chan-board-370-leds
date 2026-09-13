import XCTest
@testable import RinaCore

final class ScrollPreviewControllerTests: XCTestCase {
    // MARK: Ring delta math

    func testShortestRingDelta() {
        XCTAssertEqual(shortestRingDelta(1, 299, 300), 2)
        XCTAssertEqual(shortestRingDelta(299, 1, 300), -2)
        XCTAssertEqual(shortestRingDelta(0, 0, 300), 0)
    }

    func testSnapJumpsDisplayIndexOnRing() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)
        controller.snap(to: 120)
        XCTAssertEqual(controller.displayIndex, 120)
        XCTAssertEqual(controller.phaseError, 0)
        controller.snap(to: 305)
        XCTAssertEqual(controller.displayIndex, 5)
    }

    func testSeekWhilePlayingKeepsMeasuredSpeed() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)

        var nowMs: Double = 0
        var seq = 1
        var frameIndex = 250
        func feedTicks(for durationMs: Double) {
            let end = nowMs + durationMs
            while nowMs < end {
                _ = controller.record(sample: PreviewSync(
                    presentedSeq: seq,
                    source: "tick",
                    scrollTimelineId: "tl-1",
                    presentedFrameIndex: frameIndex,
                    presentedFrameCount: 300,
                    presentedAtUs: Int64(nowMs * 1000),
                    firmwareScrollActive: true,
                    firmwareScrollPaused: false,
                    rateEligible: true
                ), nowMs: nowMs)
                // 4 Hz like BLE: every sample is 2–3 frames apart.
                nowMs += 250
                seq += 3
                frameIndex = (frameIndex + 3) % 300
            }
        }

        feedTicks(for: 4000)
        // Backward seek 250-ish → 50, as the app does after the board acks.
        frameIndex = 50
        controller.snap(to: 50)
        feedTicks(for: 4000)

        XCTAssertEqual(controller.measuredFps, 12, accuracy: 1.5)
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

    func testReconnectAnchorsImmediatelyAndUsesRemainingFrameTime() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)
        _ = controller.record(sample: PreviewSync(
            presentedSeq: 10, source: "scroll_tick", scrollTimelineId: "tl-1",
            presentedFrameIndex: 180, presentedFrameCount: 300,
            presentedAtUs: 1_000_000, scrollIntervalMs: 100,
            sampledAtUs: 1_075_000), nowMs: 5000)
        XCTAssertEqual(controller.displayIndex, 180)
        XCTAssertEqual(controller.nextDelayMs(nowMs: 5000), 25)
    }

    func testDuplicateSampleDoesNotPullPreviewBack() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)
        let sample = PreviewSync(presentedSeq: 10, source: "scroll_tick",
            scrollTimelineId: "tl-1", presentedFrameIndex: 180, presentedFrameCount: 300)
        _ = controller.record(sample: sample, nowMs: 0)
        controller.tick()
        _ = controller.record(sample: sample, nowMs: 100)
        XCTAssertEqual(controller.displayIndex, 181)
        XCTAssertEqual(controller.phaseError, 0)
    }

    func testAdvanceCounterMeasuresMultipleLoopsBetweenSparseSamples() {
        var controller = ScrollPreviewController(frameCount: 5, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 5)
        for i in 0...30 {
            _ = controller.record(sample: PreviewSync(
                presentedSeq: i + 1, source: "scroll_tick", scrollTimelineId: "tl-1",
                presentedFrameIndex: 0, presentedFrameCount: 5,
                presentedAtUs: Int64(i * 500_000), rateEligible: true,
                scrollAdvanceSeq: UInt32(i * 20)), nowMs: Double(i * 500))
        }
        XCTAssertEqual(controller.measuredFps, 40, accuracy: 0.5)
    }

    func testBoardIntervalChangeRetunesWithoutWaitingForRegression() {
        var controller = ScrollPreviewController(frameCount: 300, userFps: 10)
        controller.bind(timelineId: "tl-1", frameCount: 300)
        _ = controller.record(sample: PreviewSync(presentedSeq: 1,
            presentedFrameIndex: 0, presentedFrameCount: 300,
            scrollIntervalMs: 25), nowMs: 0)
        XCTAssertEqual(controller.previewIntervalMs, 25)
        XCTAssertEqual(controller.measuredFps, 40)
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
