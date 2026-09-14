import XCTest
import RinaCore
@testable import RinaBoard

final class BoardResumeModeTests: XCTestCase {
    func testAnotherClientPausePreventsAutomaticPlaybackWithoutLosingThePage() {
        let status = DeviceStatus(v: 10, renderer: RendererStatus(
            mode: "manual", playback: "paused", outputMode: "video"
        ))
        let stale = PreviewSync(v: 9, playback: "idle", outputMode: "video")
        XCTAssertEqual(BoardResumeMode.resolve(status: status, preview: stale), .video)
        XCTAssertTrue(BoardResumeMode.isPlaybackPaused(status: status, preview: stale))
    }

    func testLegacyFirmwareRetainsAnUpdatedAppsOriginalStream() {
        let id = "126FC15E-8B54-43BF-A2EC-31F347BDF791"
        let status = DeviceStatus(renderer: RendererStatus(
            mode: "manual", playback: "idle", lastReason: "live_preset:\(id):42000"
        ))
        XCTAssertEqual(BoardResumeMode.resolve(status: status, preview: nil), .performance)
        let stream = BoardResumeMode.streamState(status: status, preview: nil)
        XCTAssertEqual(stream.id, id)
        XCTAssertEqual(stream.positionMs, 42000)
    }

    func testReturnsNilWithoutFirmwareState() {
        XCTAssertNil(BoardResumeMode.resolve(status: DeviceStatus(), preview: PreviewSync()))
    }

    func testAutoModeResumesControlDespiteAStaleLiveReason() {
        XCTAssertEqual(resolve(mode: "auto", playback: "idle", reason: "video"), .control)
    }

    func testOutputModeSurvivesAButtonOverwritingLastReason() {
        let status = DeviceStatus(renderer: RendererStatus(
            mode: "manual",
            playback: "idle",
            lastReason: "gpio_B5_brightness_up",
            outputMode: "video"
        ))

        XCTAssertEqual(BoardResumeMode.resolve(status: status, preview: nil), .video)
    }

    func testExplicitOutputModesTakePrecedenceOverLegacyState() {
        let expected: [(String, BoardResumeMode)] = [
            ("control", .control),
            ("text", .text),
            ("lipSync", .lipSync),
            ("performance", .performance),
            ("video", .video)
        ]

        for (outputMode, mode) in expected {
            let status = DeviceStatus(renderer: RendererStatus(
                mode: "auto",
                playback: "scroll",
                lastReason: "firmware_text_scroll_start",
                firmwareScrollActive: true,
                outputMode: outputMode
            ))
            XCTAssertEqual(BoardResumeMode.resolve(status: status, preview: nil), mode)
        }
    }

    func testActiveFirmwareScrollResumesTextEvenWhenPaused() {
        XCTAssertEqual(
            resolve(mode: "manual", playback: "scroll", reason: "video", scrollActive: true),
            .text
        )
    }

    func testNewerPreviewCanReportAnActiveScrollBeforeStatusCatchesUp() {
        let status = DeviceStatus(v: 8, renderer: RendererStatus(
            mode: "manual", playback: "idle", firmwareScrollActive: false, outputMode: "control"
        ))
        let preview = PreviewSync(v: 9, mode: "manual", playback: "scroll",
                                  firmwareScrollActive: true, outputMode: "text")

        XCTAssertEqual(BoardResumeMode.resolve(status: status, preview: preview), .text)
    }

    func testNewerStatusPreventsStalePreviewFromReopeningText() {
        let status = DeviceStatus(v: 9, renderer: RendererStatus(
            mode: "manual", playback: "idle", firmwareScrollActive: false, outputMode: "control"
        ))
        let preview = PreviewSync(v: 8, mode: "manual", playback: "scroll",
                                  reason: "firmware_text_scroll_start",
                                  presentedFrameCount: 42,
                                  firmwareScrollActive: true,
                                  outputMode: "text")

        XCTAssertEqual(BoardResumeMode.resolve(status: status, preview: preview), .control)
    }

    func testStreamStateUsesTheSameNewestSnapshotAsResumeMode() {
        let status = DeviceStatus(v: 9, renderer: RendererStatus(
            mode: "manual",
            playback: "idle",
            outputMode: "video",
            outputStreamID: "video-current",
            outputPositionMs: 12_345
        ))
        let stalePreview = PreviewSync(
            v: 8,
            mode: "manual",
            playback: "idle",
            outputMode: "performance",
            outputStreamID: "performance-old",
            outputPositionMs: 9_876
        )

        let stream = BoardResumeMode.streamState(status: status, preview: stalePreview)
        XCTAssertEqual(BoardResumeMode.resolve(status: status, preview: stalePreview), .video)
        XCTAssertEqual(stream.id, "video-current")
        XCTAssertEqual(stream.positionMs, 12_345)
    }

    func testResolvesEachExternalLiveFrameReason() {
        XCTAssertEqual(resolve(mode: "manual", playback: "idle", reason: "lipsync"), .lipSync)
        XCTAssertEqual(resolve(mode: "manual", playback: "idle", reason: "live_preset"), .performance)
        XCTAssertEqual(resolve(mode: "manual", playback: "idle", reason: "video"), .video)
    }

    func testNonIdleAndUnknownManualStateResumeControl() {
        XCTAssertEqual(resolve(mode: "manual", playback: "paused", reason: "lipsync"), .control)
        XCTAssertEqual(resolve(mode: "manual", playback: "auto", reason: "live_preset"), .control)
        XCTAssertEqual(resolve(mode: "manual", playback: "scroll", reason: "video"), .control)
        XCTAssertEqual(resolve(mode: "manual", playback: "idle", reason: "custom_live_send"), .control)
    }

    func testUnknownFirmwareModeReturnsNil() {
        XCTAssertNil(resolve(mode: "unsupported", playback: "idle", reason: "video"))
    }

    @MainActor
    func testRouterSelectsTheVideoAndPerformancePages() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: PerformanceTabMode.storageKey)
        defer { defaults.removeObject(forKey: PerformanceTabMode.storageKey) }

        let router = AppRouter()
        router.showBoardMode(.video)
        XCTAssertEqual(router.selectedTab, .presetLive)
        XCTAssertEqual(defaults.string(forKey: PerformanceTabMode.storageKey), PerformanceTabMode.video.rawValue)

        router.showBoardMode(.performance)
        XCTAssertEqual(router.selectedTab, .presetLive)
        XCTAssertEqual(defaults.string(forKey: PerformanceTabMode.storageKey), PerformanceTabMode.performance.rawValue)
    }

    private func resolve(mode: String, playback: String, reason: String,
                         scrollActive: Bool = false) -> BoardResumeMode? {
        BoardResumeMode.resolve(status: DeviceStatus(renderer: RendererStatus(
            mode: mode,
            playback: playback,
            lastReason: reason,
            firmwareScrollActive: scrollActive
        )), preview: nil)
    }
}
