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

    func testStatusWithoutScrollUnbindsControls() throws {
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        model.boardPaused = true

        model.observe(status: DeviceStatus(renderer: RendererStatus(
            firmwareScrollActive: false, firmwareScrollPaused: false, scrollFrameCount: 0)))

        XCTAssertNil(model.boundTimelineId, "Stopped elsewhere: buttons and bar must grey out")
        XCTAssertFalse(model.boardPaused)
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
        let freshIndex = min(5, expected.frameCount - 1)
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
        let model = TextViewModel()

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
        XCTAssertEqual(model.requestedFps, 27, "The unsent draft's speed must survive the reconnect too")
        XCTAssertTrue(model.userEditedText)
        XCTAssertTrue(model.restoreConflict)
        XCTAssertEqual(model.boardText, boardText)
        XCTAssertEqual(model.boundTimelineId, boardTimelineId,
                       "The transport controls still bind to the scroll already running on the board")
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
    var scrollMeta: ScrollMeta?
    var previewSync: PreviewSync?
    private(set) var scrollCommands: [Command] = []
    private(set) var requests: [RinaLinkMessageType] = []

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

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            let messageType = RinaLinkMessageType(rawValue: request.type)
            if let messageType { requests.append(messageType) }
            var reply = Data(#"{"ok":true}"#.utf8)
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
            }
            incomingContinuation?.yield(RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80,
                              seq: request.seq,
                              flags: 0,
                              payload: reply)
            ))
        }
    }
}
