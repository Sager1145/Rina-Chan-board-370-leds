import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Text tab transport row, progress bar and loop toggle against a recording
/// fake board: every control must reach the wire as the right command.
@MainActor
final class TextTransportTests: XCTestCase {
    func testTransportButtonsReachBoardEvenWhenAnotherTabOwnsOutput() async throws {
        let (connection, transport) = try await connectedBoard()
        _ = connection.output.begin(.manual)
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId

        await model.stepFrame(direction: 1, connection: connection)
        await model.stepFrame(direction: -1, connection: connection)
        XCTAssertTrue(model.boardPaused, "The firmware latches a pause on step")
        model.boardPaused = false
        await model.pause(connection: connection)
        XCTAssertTrue(model.boardPaused, "An accepted pause must flip the play/pause button at once")
        // pause/resume share a 250 ms double-tap lockout.
        try await Task.sleep(for: .milliseconds(300))
        await model.resume(connection: connection)
        XCTAssertFalse(model.boardPaused)
        await model.seek(toFrame: 2, connection: connection)
        await model.stop(connection: connection)

        XCTAssertEqual(transport.scrollCommands.map(\.name),
                       ["scroll_step", "scroll_step", "pause_scroll", "resume_scroll", "scroll_seek", "stop_scroll"])
        XCTAssertEqual(transport.scrollCommands[0].fields["direction"] as? Int, 1)
        XCTAssertEqual(transport.scrollCommands[1].fields["direction"] as? Int, -1)
        XCTAssertEqual(transport.scrollCommands[4].fields["frameIndex"] as? Int, 2)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(connection.output.source, .text)
        XCTAssertNil(model.boundTimelineId, "Stop unbinds, which greys out the bar and buttons")
        XCTAssertEqual(model.frameCount, 0)
    }

    /// A scroll the app did not upload or could not restore (WebUI, another
    /// phone, a font mismatch) left pause/step/stop greyed out, although the
    /// firmware commands act on the board's own session.
    func testBoardScrollEnablesTransportWithoutBoundTimeline() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        XCTAssertFalse(model.boardHasScroll(connection: connection))

        transport.pushStatus(#"{"renderer":{"firmwareScrollActive":true,"scrollFrameCount":40,"scrollFrameIndex":3}}"#)
        let deadline = Date().addingTimeInterval(2)
        while connection.status?.renderer?.scrollFrameCount == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(model.boundTimelineId)
        XCTAssertTrue(model.boardHasScroll(connection: connection))

        await model.pause(connection: connection)
        XCTAssertTrue(model.boardPaused)
        await model.stepFrame(direction: 1, connection: connection)
        await model.stop(connection: connection)
        XCTAssertEqual(transport.scrollCommands.map(\.name), ["pause_scroll", "scroll_step", "stop_scroll"])
        XCTAssertNil(model.errorMessage)

        transport.pushStatus(#"{"renderer":{"firmwareScrollActive":false,"scrollFrameCount":0}}"#)
        while connection.status?.renderer?.scrollFrameCount != 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.boardHasScroll(connection: connection))
    }

    func testSeekClampsToTimelineAndClearsScrub() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        model.scrubIndex = 9999

        await model.seek(toFrame: 9999, connection: connection)

        XCTAssertEqual(transport.scrollCommands.last?.name, "scroll_seek")
        XCTAssertEqual(transport.scrollCommands.last?.fields["frameIndex"] as? Int, timeline.frameCount - 1)
        XCTAssertNil(model.scrubIndex)
    }

    func testScrubOnlySendsFinalFrameOnRelease() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId

        model.beginScrub()
        for index in [1, 3, 8, 12] { model.updateScrub(toFrame: index) }
        XCTAssertEqual(model.previewFrame, timeline.frames[12])
        XCTAssertTrue(transport.scrollCommands.isEmpty)
        // Even a stray direct seek cannot write while the finger is down.
        await model.seek(toFrame: 3, connection: connection)
        XCTAssertTrue(transport.scrollCommands.isEmpty)

        let commit = try XCTUnwrap(model.endScrub())
        XCTAssertNil(model.endScrub(), "A duplicate release must not queue a second seek")
        await model.commitScrub(commit, connection: connection)
        XCTAssertEqual(transport.scrollCommands.map(\.name), ["scroll_seek"])
        XCTAssertEqual(transport.scrollCommands[0].fields["frameIndex"] as? Int, 12)
        XCTAssertNil(model.scrubIndex)
    }

    func testCancelledOrSupersededDragDoesNotCommit() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId

        model.beginScrub()
        model.updateScrub(toFrame: 4)
        let stale = try XCTUnwrap(model.endScrub())
        model.beginScrub()
        model.updateScrub(toFrame: 9)
        await model.commitScrub(stale, connection: connection)
        XCTAssertTrue(transport.scrollCommands.isEmpty)
        XCTAssertEqual(model.scrubIndex, 9)
        model.cancelScrub()
        XCTAssertNil(model.endScrub())
        XCTAssertNil(model.scrubIndex)
        XCTAssertTrue(transport.scrollCommands.isEmpty)
    }

    func testPreviousSeekReplyCannotClearNextReleasedDrag() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        model.beginScrub()
        model.updateScrub(toFrame: 4)
        let first = try XCTUnwrap(model.endScrub())
        var second: TextViewModel.ScrubCommit?
        transport.onScrollSeek = {
            model.beginScrub()
            model.updateScrub(toFrame: 9)
            second = model.endScrub()
        }
        await model.commitScrub(first, connection: connection)
        XCTAssertEqual(model.scrubIndex, 9, "An older ack must preserve the next release target")
        transport.onScrollSeek = nil
        await model.commitScrub(try XCTUnwrap(second), connection: connection)
        XCTAssertEqual(transport.scrollCommands.map { $0.fields["frameIndex"] as? Int }, [4, 9])
        XCTAssertNil(model.scrubIndex)
    }

    func testLoopToggleSendsPreferenceWithoutTakingOutput() async throws {
        let key = TextViewModel.loopPlaybackKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let (connection, transport) = try await connectedBoard()
        let owner = connection.output.begin(.performance)
        let model = TextViewModel()

        await model.setLoopPlayback(false, connection: connection)
        XCTAssertEqual(transport.scrollCommands.last?.name, "set_scroll_loop")
        XCTAssertEqual(transport.scrollCommands.last?.fields["loop"] as? Bool, false)
        XCTAssertFalse(model.loopPlayback)
        XCTAssertTrue(connection.output.isCurrent(owner), "A preference change must not stop another tab's output")

        await model.setLoopPlayback(true, connection: connection)
        XCTAssertEqual(transport.scrollCommands.last?.fields["loop"] as? Bool, true)
        XCTAssertNil(model.errorMessage)
    }

    func testStatusReportsPauseThatPreviewSamplesNeverCarry() throws {
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId

        model.observe(status: DeviceStatus(renderer: RendererStatus(
            firmwareScrollActive: true, firmwareScrollPaused: true,
            scrollFrameCount: timeline.frameCount, scrollFrameIndex: timeline.frameCount - 1,
            scrollTimelineId: timeline.timelineId, scrollLoop: false)))
        XCTAssertTrue(model.boardPaused, "End of a non-looping scroll must show the play button")

        model.observe(status: DeviceStatus(renderer: RendererStatus(
            firmwareScrollActive: true, firmwareScrollPaused: false)))
        XCTAssertFalse(model.boardPaused)
    }

    func testSpeedChangeRetunesWithoutTakingOutput() async throws {
        let (connection, transport) = try await connectedBoard()
        let owner = connection.output.begin(.performance)
        let model = TextViewModel()
        model.boundTimelineId = "t"

        model.setRequestedFps(20, connection: connection)
        let deadline = Date().addingTimeInterval(2)
        while transport.scrollCommands.last?.name != "set_scroll_interval", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(transport.scrollCommands.last?.name, "set_scroll_interval")
        XCTAssertTrue(connection.output.isCurrent(owner), "A speed tweak must not pause another tab's playback")
    }

    func testUploadCarriesIntervalMatchingRequestedFps() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        model.text = "Speed check"
        model.requestedFps = 30

        await model.send(connection: connection)
        model.suspendPreviewLoop()

        // The recorder's bare `ok` fails the bitmap check, so both upload paths run.
        let begins = transport.blobBegins.filter { ($0["kind"] as? String)?.hasPrefix("scroll") == true }
        XCTAssertEqual(begins.map { $0["kind"] as? String }, ["scroll_bitmap", "scroll"])
        for begin in begins {
            XCTAssertEqual(begin["fps"] as? Int, 30)
            XCTAssertEqual(begin["intervalMs"] as? Int, 33,
                           "Without intervalMs the board keeps ticking at its previous interval")
        }
    }

    func testBoardFpsFollowsTickIntervalOverStaleLabel() {
        XCTAssertEqual(TextViewModel.boardFps(intervalMs: 100, uiFps: 30), 10,
                       "An fps-only upload used to leave the label ahead of the real interval")
        XCTAssertEqual(TextViewModel.boardFps(intervalMs: 33, uiFps: 30), 30)
        XCTAssertEqual(TextViewModel.boardFps(intervalMs: 17, uiFps: 60), 60)
        XCTAssertEqual(TextViewModel.boardFps(intervalMs: 17, uiFps: 59), 59)
        XCTAssertEqual(TextViewModel.boardFps(intervalMs: 50, uiFps: nil), 20)
        XCTAssertEqual(TextViewModel.boardFps(intervalMs: nil, uiFps: 25), 25)
        XCTAssertNil(TextViewModel.boardFps(intervalMs: 0, uiFps: 0))
    }

    func testQuickDragBackDoesNotFlickerThroughIntermediateEcho() async throws {
        let (connection, _) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        func status(intervalMs: Int, fps: Int) -> DeviceStatus {
            DeviceStatus(renderer: RendererStatus(
                firmwareScrollActive: true, firmwareScrollPaused: false,
                scrollFrameCount: timeline.frameCount, scrollIntervalMs: intervalMs, uiFps: fps,
                scrollTimelineId: timeline.timelineId))
        }
        model.observe(status: status(intervalMs: 50, fps: 20))

        // 20 → 25 → 20 before anything reaches the board (no await in between).
        model.setRequestedFps(25, connection: connection)
        model.setRequestedFps(20, connection: connection)
        model.observe(status: status(intervalMs: 50, fps: 20))
        XCTAssertEqual(model.requestedFps, 20)
        model.observe(status: status(intervalMs: 40, fps: 25))
        XCTAssertEqual(model.requestedFps, 20,
                       "A stale matching report must not let the 25 echo jump the slider")
    }

    func testStatusSyncsSpeedToBoardWithoutUndoingInFlightRetune() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        func status(intervalMs: Int, fps: Int) -> DeviceStatus {
            DeviceStatus(renderer: RendererStatus(
                firmwareScrollActive: true, firmwareScrollPaused: false,
                scrollFrameCount: timeline.frameCount, scrollIntervalMs: intervalMs, uiFps: fps,
                scrollTimelineId: timeline.timelineId))
        }

        model.observe(status: status(intervalMs: 50, fps: 20))
        XCTAssertEqual(model.requestedFps, 20, "The slider must show the rate the board is running")

        model.setRequestedFps(30, connection: connection)
        model.observe(status: status(intervalMs: 50, fps: 20))
        XCTAssertEqual(model.requestedFps, 30, "A status from before the retune must not snap the slider back")

        // Only an echo after the board accepted the retune ends the guard.
        let deadline = Date().addingTimeInterval(2)
        while transport.scrollCommands.last?.name != "set_scroll_interval", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        model.observe(status: status(intervalMs: 33, fps: 30))
        model.observe(status: status(intervalMs: 100, fps: 10))
        XCTAssertEqual(model.requestedFps, 10, "Once confirmed, a later retune from elsewhere is adopted")
    }

    func testSliderMovedDuringUploadIsAppliedOnceBound() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        model.text = "Speed check"
        model.requestedFps = 30
        // Nothing is bound yet, so the move itself sends nothing.
        transport.onBlobBegin = { model.setRequestedFps(45, connection: connection) }

        await model.send(connection: connection)
        let deadline = Date().addingTimeInterval(2)
        while transport.scrollCommands.last?.name != "set_scroll_interval", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.suspendPreviewLoop()

        XCTAssertEqual(transport.scrollCommands.last?.name, "set_scroll_interval")
        XCTAssertEqual(transport.scrollCommands.last?.fields["fps"] as? Int, 45)
        XCTAssertEqual(transport.scrollCommands.last?.fields["intervalMs"] as? Int, 22)
        XCTAssertEqual(model.requestedFps, 45)
    }

    func testRejectedRetuneFallsBackToBoardSpeed() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        model.observe(status: DeviceStatus(renderer: RendererStatus(
            firmwareScrollActive: true, firmwareScrollPaused: false,
            scrollFrameCount: timeline.frameCount, scrollIntervalMs: 50, uiFps: 20,
            scrollTimelineId: timeline.timelineId)))
        transport.rejectCommands = true

        model.setRequestedFps(30, connection: connection)
        // A rejected command leaves the board unchanged, so no new status comes;
        // the slider has to return to the speed the board last reported.
        let deadline = Date().addingTimeInterval(2)
        while model.requestedFps != 20, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(transport.scrollCommands.last?.name, "set_scroll_interval")
        XCTAssertEqual(model.requestedFps, 20, "A retune the board never took must not stay on the slider")
    }

    func testTickSamplesKeepSpeedInSyncButPausedSamplesDoNot() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        transport.scrollMeta = restoreMeta(
            text: timeline.text, timelineId: timeline.timelineId, timeline: timeline
        )
        transport.previewSync = restorePreview(
            timelineId: timeline.timelineId, timeline: timeline, frameIndex: 1
        )
        // Binds the preview lock to this timeline, as a real reconnect does.
        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()
        XCTAssertEqual(model.requestedFps, 10)
        func sample(seq: Int, intervalMs: Int, fps: Int, playing: Bool) -> PreviewSync {
            PreviewSync(ok: true, playback: playing ? "scroll" : "scroll_paused", valid: true,
                        presentedSeq: seq, source: "scroll_tick", scrollTimelineId: timeline.timelineId,
                        presentedFrameIndex: seq % timeline.frameCount, presentedFrameCount: timeline.frameCount,
                        presentedAtUs: Int64(seq) * 50_000, scrollIntervalMs: intervalMs, uiFps: fps,
                        firmwareScrollActive: true, firmwareScrollPaused: !playing, rateEligible: playing)
        }

        model.observe(preview: sample(seq: 5, intervalMs: 50, fps: 20, playing: true))
        XCTAssertNotNil(model.boundTimelineId)
        XCTAssertEqual(model.requestedFps, 20)

        model.observe(preview: sample(seq: 6, intervalMs: 100, fps: 10, playing: false))
        XCTAssertEqual(model.requestedFps, 20, "A paused sample's interval may predate the latest retune")
    }

    func testMeasuredSpeedIsHiddenUnlessBoardIsPlaying() throws {
        let model = TextViewModel()
        XCTAssertNil(model.measuredFps, "Nothing bound: no measurement to show")

        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        XCTAssertNotNil(model.measuredFps)

        model.boardPaused = true
        XCTAssertNil(model.measuredFps)
    }

    func testStatusWithoutScrollUnbindsControls() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        transport.scrollMeta = restoreMeta(
            text: timeline.text, timelineId: timeline.timelineId, timeline: timeline
        )
        transport.previewSync = restorePreview(
            timelineId: timeline.timelineId, timeline: timeline, frameIndex: 3
        )
        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()
        XCTAssertEqual(model.frameCount, timeline.frameCount)
        XCTAssertEqual(model.displayIndex, 3)

        model.observe(status: DeviceStatus(renderer: RendererStatus(
            firmwareScrollActive: false, firmwareScrollPaused: false, scrollFrameCount: 0)))

        XCTAssertNil(model.boundTimelineId, "Stopped elsewhere: buttons and bar must grey out")
        XCTAssertEqual(model.frameCount, 0, "An idle board must not leave the previous timeline in the progress bar")
        XCTAssertEqual(model.displayIndex, 0)
        XCTAssertEqual(model.previewFrame, PackedFrame())
        XCTAssertFalse(model.boardPaused)
    }

    /// Fix for "text page stays cleared while the board scrolls": a
    /// `getScrollMeta` failure (or anything else that makes `restoreOnConnect`
    /// bail) during resync must not strand the Text page empty until the next
    /// connection change — a later status push reporting the firmware scroll
    /// as active must retry the restore.
    func testFailedFirstRestoreIsRetriedOnLaterStatusPush() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()

        // No `scrollMeta` configured yet: `getScrollMeta` replies `{"ok":true}`
        // with everything else nil, so `restoreOnConnect`'s `uploadComplete`
        // guard fails silently and nothing gets bound.
        await model.restoreOnConnect(connection: connection)
        XCTAssertNil(model.boundTimelineId)
        XCTAssertEqual(model.frameCount, 0)

        // The board is actually mid-scroll; only now does the board reply
        // with the metadata a retry needs to succeed.
        transport.scrollMeta = restoreMeta(
            text: timeline.text, timelineId: timeline.timelineId, timeline: timeline
        )
        transport.previewSync = restorePreview(
            timelineId: timeline.timelineId, timeline: timeline, frameIndex: 0
        )
        model.observe(status: DeviceStatus(renderer: RendererStatus(
            firmwareScrollActive: true, firmwareScrollPaused: false,
            scrollFrameCount: timeline.frameCount)), connection: connection)

        let deadline = Date().addingTimeInterval(2)
        while model.boundTimelineId == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.suspendPreviewLoop()

        XCTAssertEqual(model.boundTimelineId, timeline.timelineId,
                       "a later status push must retry the restore instead of waiting for a connection change")
        XCTAssertEqual(model.frameCount, timeline.frameCount)
    }

    func testConnectionChangeClearsBoardProgressButKeepsDraftForResend() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        let draft = "Keep this unsent draft"
        model.editText(draft)
        transport.scrollMeta = restoreMeta(
            text: timeline.text, timelineId: timeline.timelineId, timeline: timeline
        )
        transport.previewSync = restorePreview(
            timelineId: timeline.timelineId, timeline: timeline, frameIndex: 3
        )
        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()
        XCTAssertEqual(model.frameCount, timeline.frameCount)
        XCTAssertEqual(model.displayIndex, 3)

        // Restoring an active scroll adopts its real speed. A subsequent
        // draft preference must survive invalidating that board session.
        model.requestedFps = 27
        model.connectionChanged()

        XCTAssertNil(model.boundTimelineId)
        XCTAssertEqual(model.frameCount, 0)
        XCTAssertEqual(model.displayIndex, 0)
        XCTAssertEqual(model.previewFrame, PackedFrame())
        XCTAssertEqual(model.text, draft)
        XCTAssertTrue(model.userEditedText)
        XCTAssertEqual(model.requestedFps, 27)
    }

    func testMissingStatusClearsProgressSnapshot() throws {
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        XCTAssertEqual(model.frameCount, timeline.frameCount)

        model.observe(status: nil)

        XCTAssertNil(model.boundTimelineId)
        XCTAssertEqual(model.frameCount, 0, "Disconnect clears status before a new board snapshot exists")
        XCTAssertEqual(model.displayIndex, 0)
    }

    func testRejectedCommandShowsReadableReason() async throws {
        let (connection, transport) = try await connectedBoard()
        transport.rejectCommands = true
        let model = TextViewModel()
        model.boundTimelineId = "t"

        await model.pause(connection: connection)

        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertFalse(message.contains("RinaTransportError"), "Got the generic system text: \(message)")
        XCTAssertFalse(model.boardPaused)
    }

    func testActiveReconnectRestoresBoardTextAtFreshPreviewFrame() async throws {
        let (connection, transport) = try await connectedBoard()
        // Connection setup reads its own board snapshot. Measure only the
        // subsequent text restoration's metadata-then-fresh-preview sequence.
        transport.clearRecordedRequests()
        let boardText = "Fresh reconnect"
        let expected = try makeTimeline(text: boardText, fps: 20)
        let boardTimelineId = "board-active"
        let freshIndex = min(5, expected.frameCount - 1)
        let model = TextViewModel()
        let staleTimeline = try makeTimeline(text: "Old board text", fps: 10)
        transport.scrollMeta = restoreMeta(
            text: staleTimeline.text, timelineId: staleTimeline.timelineId, timeline: staleTimeline
        )
        transport.previewSync = restorePreview(
            timelineId: staleTimeline.timelineId, timeline: staleTimeline, frameIndex: 3
        )
        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()
        XCTAssertEqual(model.frameCount, staleTimeline.frameCount)
        XCTAssertEqual(model.displayIndex, 3)
        model.connectionChanged()
        transport.clearRecordedRequests()
        transport.scrollMeta = ScrollMeta(
            ok: true,
            scrollTimelineId: boardTimelineId,
            hasSourceText: true,
            sourceText: boardText,
            sourceTextBytes: boardText.utf8.count,
            fontId: ScrollRasterizer.fontId,
            generatorVersion: ScrollRasterizer.generatorVersion,
            uiFps: 20,
            scrollIntervalMs: 50,
            frameCount: expected.frameCount,
            frameIndex: 1,
            uploadComplete: true,
            firmwareScrollActive: true,
            firmwareScrollPaused: false,
            scrollLoop: true
        )
        transport.previewSync = PreviewSync(
            ok: true,
            playback: "scroll",
            valid: true,
            presentedSeq: 41,
            source: "scroll_tick",
            scrollTimelineId: boardTimelineId,
            presentedFrameIndex: freshIndex,
            presentedFrameCount: expected.frameCount,
            presentedAtUs: 1_000_000,
            scrollIntervalMs: 50,
            uiFps: 20,
            firmwareScrollActive: true,
            firmwareScrollPaused: false,
            rateEligible: true
        )

        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()

        XCTAssertEqual(model.text, boardText)
        XCTAssertFalse(model.userEditedText)
        XCTAssertEqual(model.boundTimelineId, boardTimelineId)
        XCTAssertEqual(model.frameCount, expected.frameCount)
        XCTAssertEqual(model.displayIndex, freshIndex,
                       "The post-build preview cursor must replace the stale metadata cursor")
        XCTAssertEqual(model.previewFrame, expected.frames[freshIndex])
        XCTAssertEqual(transport.restoreRequests, [.getScrollMeta, .getPreviewSync])
        XCTAssertEqual(connection.output.source, .text)
    }

    func testPausedReconnectDoesNotAdvanceAndRestoresBoardLoopSetting() async throws {
        let key = TextViewModel.loopPlaybackKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let (connection, transport) = try await connectedBoard()
        let boardText = "Paused reconnect"
        let expected = try makeTimeline(text: boardText, fps: 60)
        let boardTimelineId = "board-paused"
        let pausedIndex = min(4, expected.frameCount - 1)
        transport.scrollMeta = ScrollMeta(
            ok: true,
            scrollTimelineId: boardTimelineId,
            hasSourceText: true,
            sourceText: boardText,
            sourceTextBytes: boardText.utf8.count,
            fontId: ScrollRasterizer.fontId,
            generatorVersion: ScrollRasterizer.generatorVersion,
            uiFps: 60,
            scrollIntervalMs: 17,
            frameCount: expected.frameCount,
            frameIndex: 1,
            uploadComplete: true,
            firmwareScrollActive: true,
            firmwareScrollPaused: true,
            scrollLoop: false
        )
        transport.previewSync = PreviewSync(
            ok: true,
            playback: "scroll",
            valid: true,
            presentedSeq: 82,
            source: "scroll_tick",
            scrollTimelineId: boardTimelineId,
            presentedFrameIndex: pausedIndex,
            presentedFrameCount: expected.frameCount,
            scrollIntervalMs: 17,
            uiFps: 60,
            firmwareScrollActive: true,
            firmwareScrollPaused: true
        )
        let model = TextViewModel()
        model.loopPlayback = true

        await model.restoreOnConnect(connection: connection)
        let restoredIndex = model.displayIndex
        try await Task.sleep(for: .milliseconds(80))
        model.suspendPreviewLoop()

        XCTAssertTrue(model.boardPaused)
        XCTAssertFalse(model.loopPlayback, "Reconnect must adopt the board's current loop mode")
        XCTAssertEqual(restoredIndex, pausedIndex)
        XCTAssertEqual(model.displayIndex, pausedIndex,
                       "A paused board must keep the local preview on its reported frame")
    }

    func testReconnectPreservesUnsentDraftAndReportsBoardConflict() async throws {
        let (connection, transport) = try await connectedBoard()
        let boardText = "Already on board"
        let expected = try makeTimeline(text: boardText)
        let boardTimelineId = "board-conflict"
        transport.scrollMeta = restoreMeta(
            text: boardText, timelineId: boardTimelineId, timeline: expected
        )
        transport.previewSync = restorePreview(
            timelineId: boardTimelineId, timeline: expected, frameIndex: 2
        )
        let model = TextViewModel()
        let localDraft = "Unsent local edit"
        model.editText(localDraft)
        model.requestedFps = 27

        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()

        XCTAssertEqual(model.text, localDraft)
        XCTAssertEqual(model.requestedFps, 10,
                       "The bound controls retune the board's running scroll, so they show its speed")
        XCTAssertTrue(model.userEditedText)
        XCTAssertTrue(model.restoreConflict)
        XCTAssertEqual(model.boardText, boardText)
        XCTAssertEqual(model.boundTimelineId, boardTimelineId,
                       "The transport controls still bind to the scroll already running on the board")
    }

    /// A group-timed scroll is BoardGroupCoordinator's: binding it here would
    /// claim `.text` on the primary and block the group from rejoining it.
    func testReconnectLeavesGroupTimedScrollToGroupCoordinator() async throws {
        let (connection, transport) = try await connectedBoard()
        let boardText = "Group scroll"
        let expected = try makeTimeline(text: boardText, fps: 30)
        var meta = restoreMeta(text: boardText, timelineId: "group-timed", timeline: expected, fps: 30)
        meta.groupTimed = true
        transport.scrollMeta = meta
        transport.previewSync = restorePreview(
            timelineId: "group-timed", timeline: expected, frameIndex: 2, fps: 30
        )
        let model = TextViewModel()
        model.requestedFps = 12

        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()

        XCTAssertNil(model.boundTimelineId)
        XCTAssertNil(connection.output.source)
        XCTAssertEqual(model.requestedFps, 12)
    }

    func testAdoptGroupFpsFollowsBoardsWithoutSending() async throws {
        let (_, transport) = try await connectedBoard()
        let sentBefore = transport.requests.count
        let model = TextViewModel()
        model.requestedFps = 10

        model.adoptGroupFps(30)
        XCTAssertEqual(model.requestedFps, 30)
        model.adoptGroupFps(10_000)
        XCTAssertEqual(model.requestedFps, Double(RinaLinkConstants.scrollFpsMax))
        XCTAssertEqual(transport.requests.count, sentBefore)

        // 60 fps ticks at 17 ms, which reads back as 59: the label must not drift.
        model.requestedFps = 60
        model.adoptGroupFps(59)
        XCTAssertEqual(model.requestedFps, 60)
    }

    func testReconnectRestoresAlreadySentDraftWithoutConflict() async throws {
        let (connection, transport) = try await connectedBoard()
        let boardText = "Previously sent text"
        let expected = try makeTimeline(text: boardText, fps: 15)
        let boardTimelineId = "board-sent-draft"
        transport.scrollMeta = restoreMeta(
            text: boardText, timelineId: boardTimelineId, timeline: expected, fps: 15
        )
        transport.previewSync = restorePreview(
            timelineId: boardTimelineId, timeline: expected, frameIndex: 3, fps: 15
        )
        let model = TextViewModel()
        model.text = boardText
        model.userEditedText = false

        await model.restoreOnConnect(connection: connection)
        model.suspendPreviewLoop()

        XCTAssertEqual(model.text, boardText)
        XCTAssertFalse(model.userEditedText)
        XCTAssertFalse(model.restoreConflict)
        XCTAssertNil(model.boardText)
        XCTAssertEqual(model.requestedFps, 15)
    }

    // MARK: Cross-session ownership, with a held request (audit A25, A26)

    /// A speed change queued for one board must never be delivered to another.
    ///
    /// `set_scroll_interval` for board A is parked in flight, so a second slider
    /// move only becomes `pending` in the coalescing sender. The board then
    /// switches and board B binds its own timeline. When A's send finally
    /// returns, the drain loop wakes and drains that pending value — and used to
    /// resolve its destination from `activeConnection` at that moment, which by
    /// then is B.
    func testQueuedSpeedChangeIsNotDeliveredToAnotherBoard() async throws {
        let (boardA, transportA) = try await connectedBoard()
        let (boardB, transportB) = try await connectedBoard()
        let model = TextViewModel()
        model.text = "Speed"
        model.requestedFps = 10
        await model.send(connection: boardA)
        model.suspendPreviewLoop()

        // Park A's retune so the next move can only queue behind it.
        transportA.shouldHold = { type, name in type == .cmd && name == "set_scroll_interval" }
        model.setRequestedFps(45, connection: boardA)
        try await transportA.waitForHeld()
        model.setRequestedFps(50, connection: boardA)

        // The board switch, then B binds a timeline of its own.
        model.connectionChanged()
        await model.send(connection: boardB)
        model.suspendPreviewLoop()

        // A's send completes; the drain loop resumes with 50 still pending.
        transportA.releaseHeld()
        try await Task.sleep(for: .milliseconds(400))

        let leaked = transportB.scrollCommands.filter { $0.name == "set_scroll_interval" }
        XCTAssertTrue(leaked.isEmpty,
                      "board B received a speed change made for board A: \(leaked.map(\.fields))")
    }

    /// A superseded upload must not write over the upload that replaced it.
    ///
    /// The first upload is parked at its blob begin, then `releaseOutput()` (what
    /// `connectionChanged` / `observe(status: nil)` call) clears the busy flag and
    /// only cooperatively cancels it. A second upload runs to completion, and
    /// only then is the first released: its `catch` used to write `errorMessage`
    /// and its `defer` used to clear the *second* upload's `isUploading`.
    func testSupersededUploadDoesNotWriteOverTheUploadThatReplacedIt() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        model.text = "Cross talk"

        // Park the blob begin of both uploads, so each can be unwound on its own.
        var parked = 0
        transport.shouldHold = { type, _ in
            guard type == .blobBegin, parked < 2 else { return false }
            parked += 1
            return true
        }

        let first = Task { await model.send(connection: connection) }
        try await transport.waitForHeld(count: 1)

        // Supersede it, exactly as `connectionChanged` / `observe(status: nil)` do.
        model.releaseOutput()
        let second = Task { await model.send(connection: connection) }
        try await transport.waitForHeld(count: 2)
        XCTAssertTrue(model.isUploading, "the replacement upload owns the busy flag")

        // Unwind only the superseded upload, while the replacement is still in
        // flight. Its `defer` used to clear the replacement's busy flag and its
        // `catch` used to report the failure as the replacement's.
        transport.releaseHeld(count: 1)
        await first.value

        XCTAssertTrue(model.isUploading,
                      "a superseded upload must not clear the busy flag of the upload that replaced it")
        XCTAssertNil(model.errorMessage,
                     "nor report its own failure as the replacement's")

        transport.releaseHeld()
        await second.value
        model.suspendPreviewLoop()
        XCTAssertFalse(model.isUploading, "the replacement finished, so the flag is clear now")
    }

    /// R20: `getPreviewSync()`'s stale-token `CancellationError` is `try?`-
    /// swallowed, so a `releaseOutput()` that lands while it is in flight
    /// must still stop the success tail from resurrecting a preview loop or
    /// reporting the upload complete.
    func testReleaseOutputDuringGetPreviewSyncSuppressesTheSuccessTail() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        model.text = "Superseded during preview sync"
        transport.shouldHold = { type, _ in type == .getPreviewSync }

        let send = Task { await model.send(connection: connection) }
        try await transport.waitForHeld(count: 1)
        model.releaseOutput()
        transport.releaseHeld()
        await send.value

        XCTAssertNotEqual(model.uploadProgress, 1.0,
                          "a superseded upload must not report completion")
        XCTAssertFalse(model.isUploading, "releaseOutput must still clear the busy flag")
    }

    // MARK: Upload ownership, happy paths
    //
    // Scope: both tests below pass against the pre-fix code too, so neither
    // pins A26 — they only characterize the properties revision ownership is
    // meant to guarantee. The tests that actually fail without the fixes are
    // the two above, which use the transport's hold hook; `Task.yield()` is too
    // coarse for this, because the pre-fix code set `isUploading` before its
    // first real `await` and the second send was rejected anyway.

    /// Admission is synchronous, so one send produces one upload.
    func testSecondSendIsRejectedWhileTheFirstUploadIsStarting() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        model.text = "Race"

        let first = Task { await model.send(connection: connection) }
        await Task.yield()
        await model.send(connection: connection)
        await first.value

        // One upload produces two begins against this recorder: `scroll_bitmap`
        // fails its timeline check on the bare `ok` reply and falls back to the
        // per-frame `scroll` path. The bitmap begins are the upload attempts.
        let attempts = transport.blobBegins.filter { ($0["kind"] as? String) == "scroll_bitmap" }
        XCTAssertEqual(attempts.count, 1,
                       "a second send must not start a second upload")
        XCTAssertFalse(model.isUploading, "the finished upload must leave the flag clear")
        XCTAssertNil(model.errorMessage, "a rejected second send must not report an error")
    }

    /// A superseded upload's unwinding leaves no stuck busy flag or phase.
    func testUploadSupersededMidFlightLeavesNoStuckStateOrSpuriousError() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        model.text = "Superseded"
        transport.onBlobBegin = { model.releaseOutput() }

        await model.send(connection: connection)

        XCTAssertFalse(model.isUploading, "a superseded upload must not leave the model busy")
        XCTAssertNil(model.localPhase, "the phase must not be left mid-upload")
    }

    // MARK: R02 — hostile/corrupt blob offsets never reach `Data.subdata`

    func testBlobBeginNegativeOffsetThrowsInvalidResponseInsteadOfTrapping() async throws {
        let (connection, transport) = try await connectedBoard()
        transport.blobBeginReplyOverride = Data(#"{"ok":true,"offset":-1}"#.utf8)

        do {
            _ = try await connection.startScrollUpload(
                frames: [PackedFrame()], fps: 10, timelineId: "t", fontId: "f",
                generatorVersion: "v", sourceText: "x")
            XCTFail("expected invalidResponse")
        } catch RinaTransportError.invalidResponse {
            // expected
        }
    }

    func testBlobChunkResyncToNegativeExpectedOffsetThrows() async throws {
        let (connection, transport) = try await connectedBoard()
        let errorPayload = try JSONEncoder().encode(
            RinaLinkError(ok: false, error: "bad offset", code: 400, expectedOffset: -1))
        transport.blobChunkReplyOverrides = [(data: errorPayload, isError: true)]

        do {
            _ = try await connection.startScrollUpload(
                frames: [PackedFrame()], fps: 10, timelineId: "t", fontId: "f",
                generatorVersion: "v", sourceText: "x")
            XCTFail("expected invalidResponse")
        } catch RinaTransportError.invalidResponse {
            // expected
        }
    }

    func testBlobChunkAckOffsetBeyondDataThrows() async throws {
        let (connection, transport) = try await connectedBoard()
        // A single-frame upload's data is exactly `PackedFrame.byteCount` bytes;
        // an ACK past that end is out of range no matter what firmware meant.
        let ackPayload = try JSONEncoder().encode(
            BlobChunkReply(ok: true, offset: PackedFrame.byteCount + 1, frames: nil))
        transport.blobChunkReplyOverrides = [(data: ackPayload, isError: false)]

        do {
            _ = try await connection.startScrollUpload(
                frames: [PackedFrame()], fps: 10, timelineId: "t", fontId: "f",
                generatorVersion: "v", sourceText: "x")
            XCTFail("expected invalidResponse")
        } catch RinaTransportError.invalidResponse {
            // expected
        }
    }

    // MARK: Helpers

    private func connectedBoard() async throws -> (BoardConnection, RecordingTextTransport) {
        let transport = RecordingTextTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func makeTimeline(text: String = "Rina", fps: Int = 10) throws -> ScrollTimeline {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"),
                                "Hosted tests need the app's bundled font")
        let font = try ArkPixelFont.loadBundled(url: url)
        let timeline = try ScrollRasterizer.makeTimeline(text: text, font: font, fps: fps)
        XCTAssertGreaterThan(timeline.frameCount, 3)
        return timeline
    }

    private func restoreMeta(text: String, timelineId: String, timeline: ScrollTimeline,
                             fps: Int = 10, paused: Bool = false, loop: Bool = true) -> ScrollMeta {
        ScrollMeta(
            ok: true,
            scrollTimelineId: timelineId,
            hasSourceText: true,
            sourceText: text,
            sourceTextBytes: text.utf8.count,
            fontId: ScrollRasterizer.fontId,
            generatorVersion: ScrollRasterizer.generatorVersion,
            uiFps: fps,
            scrollIntervalMs: ScrollRasterizer.intervalMs(forFps: fps),
            frameCount: timeline.frameCount,
            frameIndex: 0,
            uploadComplete: true,
            firmwareScrollActive: true,
            firmwareScrollPaused: paused,
            scrollLoop: loop
        )
    }

    private func restorePreview(timelineId: String, timeline: ScrollTimeline, frameIndex: Int,
                                fps: Int = 10, paused: Bool = false) -> PreviewSync {
        PreviewSync(
            ok: true,
            playback: "scroll",
            valid: true,
            presentedSeq: 1,
            source: "scroll_tick",
            scrollTimelineId: timelineId,
            presentedFrameIndex: frameIndex,
            presentedFrameCount: timeline.frameCount,
            scrollIntervalMs: ScrollRasterizer.intervalMs(forFps: fps),
            uiFps: fps,
            firmwareScrollActive: true,
            firmwareScrollPaused: paused
        )
    }
}

/// Replies `ok` to everything (or rejects CMDs on request) and records every
/// scroll-related `CMD` it sees, in order.
@MainActor
private final class RecordingTextTransport: @MainActor RinaTransport {
    struct Command {
        let name: String
        let fields: [String: Any]
    }

    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var rejectCommands = false
    var onScrollSeek: (() -> Void)?
    var onBlobBegin: (() -> Void)?
    var scrollMeta: ScrollMeta?
    var previewSync: PreviewSync?
    private(set) var scrollCommands: [Command] = []
    private(set) var requests: [RinaLinkMessageType] = []
    private(set) var blobBegins: [[String: Any]] = []

    // MARK: Holding a request in flight
    //
    // Several defects only appear while one operation is still in flight and a
    // newer one runs (a queued speed change draining after a board switch, a
    // superseded upload unwinding onto the next upload's state). This parks a
    // selected request instead of replying to it, so a test can create that
    // interleaving deterministically instead of racing `Task.yield()`.
    // Parking happens inside `send`, which leaves the caller's write awaiting;
    // other operations keep running, because this transport is main-actor
    // isolated rather than exclusive.

    /// Return true to park the request. `name` is the `cmd` for a CMD frame.
    var shouldHold: ((RinaLinkMessageType?, _ name: String?) -> Bool)?
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []

    /// How many requests are parked right now.
    var heldCount: Int { heldContinuations.count }

    /// Lets parked requests reply and continue, oldest first. `count` nil
    /// releases all of them; releasing a subset is what lets a test unwind one
    /// operation while another is still deliberately in flight.
    func releaseHeld(count: Int? = nil) {
        let releasing = min(count ?? heldContinuations.count, heldContinuations.count)
        let parked = Array(heldContinuations.prefix(releasing))
        heldContinuations.removeFirst(releasing)
        for continuation in parked { continuation.resume() }
    }

    /// Waits until at least `count` requests are parked.
    func waitForHeld(count: Int = 1, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while heldContinuations.count < count {
            guard ContinuousClock.now < deadline else {
                throw HoldTimeout(parked: heldContinuations.count, wanted: count)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    struct HoldTimeout: Error, CustomStringConvertible {
        let parked: Int
        let wanted: Int
        var description: String { "timed out with \(parked) parked request(s), wanted \(wanted)" }
    }

    /// An unsolicited EV_STATUS frame, as the firmware broadcasts one.
    func pushStatus(_ json: String) {
        incomingContinuation?.yield(try! RinaLinkEncoder.encode(
            RinaLinkFrame(type: RinaLinkMessageType.evStatus.rawValue, seq: 0, flags: 0, payload: Data(json.utf8))
        ))
    }

    func clearRecordedRequests() { requests.removeAll() }

    var restoreRequests: [RinaLinkMessageType] {
        requests.filter { $0 == .getScrollMeta || $0 == .getPreviewSync }
    }

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> {
        AsyncStream { stateContinuation = $0 }
    }

    func incomingStream() -> AsyncStream<Data> {
        AsyncStream { incomingContinuation = $0 }
    }

    func connect() async throws {
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    /// Overrides the reply payload to the next BLOB_BEGIN, exactly once.
    var blobBeginReplyOverride: Data?
    /// Overrides the reply to successive BLOB_CHUNKs, one entry consumed per
    /// chunk sent; `isError` routes the reply through the 0xFF error frame
    /// type so it decodes as a `RinaLinkError` instead of a chunk ACK.
    var blobChunkReplyOverrides: [(data: Data, isError: Bool)] = []

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            let messageType = RinaLinkMessageType(rawValue: request.type)
            if let messageType { requests.append(messageType) }
            if messageType == .blobBegin,
               let fields = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any] {
                blobBegins.append(fields)
                onBlobBegin?()
            }
            var reply = Data(#"{"ok":true}"#.utf8)
            var replyType = request.type | 0x80
            if messageType == .getScrollMeta, let scrollMeta {
                reply = try JSONEncoder().encode(scrollMeta)
            } else if messageType == .getPreviewSync, let previewSync {
                reply = try JSONEncoder().encode(previewSync)
            } else if messageType == .cmd,
               let fields = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
               let name = fields["cmd"] as? String {
                if name.contains("scroll") {
                    scrollCommands.append(Command(name: name, fields: fields))
                }
                if name == "scroll_seek" { onScrollSeek?() }
                if rejectCommands { reply = Data(#"{"ok":false,"error":"denied"}"#.utf8) }
            } else if messageType == .blobBegin, let override = blobBeginReplyOverride {
                reply = override
                blobBeginReplyOverride = nil
            } else if messageType == .blobChunk, !blobChunkReplyOverrides.isEmpty {
                let override = blobChunkReplyOverrides.removeFirst()
                reply = override.data
                if override.isError { replyType = RinaLinkMessageType.error.rawValue }
            }
            if let shouldHold {
                let name = (try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any])?["cmd"] as? String
                if shouldHold(messageType, name) {
                    await withCheckedContinuation { heldContinuations.append($0) }
                }
            }
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: replyType,
                              seq: request.seq,
                              flags: 0,
                              payload: reply)
            ))
        }
    }
}
