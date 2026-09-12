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

    // MARK: Helpers

    private func connectedBoard() async throws -> (BoardConnection, RecordingTextTransport) {
        let transport = RecordingTextTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func makeTimeline() throws -> ScrollTimeline {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"),
                                "Hosted tests need the app's bundled font")
        let font = try ArkPixelFont.loadBundled(url: url)
        let timeline = try ScrollRasterizer.makeTimeline(text: "Rina", font: font, fps: 10)
        XCTAssertGreaterThan(timeline.frameCount, 3)
        return timeline
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
    private(set) var scrollCommands: [Command] = []

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
            var reply = #"{"ok":true}"#
            if request.type == RinaLinkMessageType.cmd.rawValue,
               let fields = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
               let name = fields["cmd"] as? String {
                if name.contains("scroll") {
                    scrollCommands.append(Command(name: name, fields: fields))
                }
                if rejectCommands { reply = #"{"ok":false,"error":"denied"}"# }
            }
            incomingContinuation?.yield(RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80,
                              seq: request.seq,
                              flags: 0,
                              payload: Data(reply.utf8))
            ))
        }
    }
}
