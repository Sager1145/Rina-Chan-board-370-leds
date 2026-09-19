import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// `TextViewModel.isForeignGroupScroll` and the `boardHasScroll`/`phaseKey`
/// guards built on it: a group-timed scroll this page never bound belongs to
/// `BoardGroupCoordinator`, so the single-board Text page must not claim
/// 播放中/暂停 for it. Style follows `AcceptanceTextTests` (offline
/// preflight/state) plus a minimal transport for the reachable-offline
/// `phaseKey`/`boardHasScroll` cases (like `TextTransportTests`).
@MainActor
final class TextViewModelGroupScrollTests: XCTestCase {
    // MARK: - isForeignGroupScroll (pure, no connection needed)

    func testIsForeignGroupScrollTrueWhenRendererReportsGroupTimed() {
        var renderer = RendererStatus()
        renderer.groupTimed = true
        XCTAssertTrue(TextViewModel.isForeignGroupScroll(renderer: renderer, preview: nil))
    }

    func testIsForeignGroupScrollTrueWhenOnlyPreviewReportsGroupTimed() {
        var preview = PreviewSync()
        preview.groupTimed = true
        XCTAssertTrue(TextViewModel.isForeignGroupScroll(renderer: nil, preview: preview))
    }

    func testIsForeignGroupScrollFalseWhenNeitherReportsGroupTimed() {
        XCTAssertFalse(TextViewModel.isForeignGroupScroll(renderer: RendererStatus(), preview: PreviewSync()))
        XCTAssertFalse(TextViewModel.isForeignGroupScroll(renderer: nil, preview: nil))
    }

    func testIsForeignGroupScrollFalseWhenRendererExplicitlyNotGroupTimed() {
        var renderer = RendererStatus()
        renderer.groupTimed = false
        XCTAssertFalse(TextViewModel.isForeignGroupScroll(renderer: renderer, preview: nil))
    }

    // MARK: - boardHasScroll / phaseKey with a live (unbound) group-timed board

    func testBoardHasScrollFalseForUnboundGroupTimedScroll() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        XCTAssertNil(model.boundTimelineId)

        transport.pushStatus(#"{"renderer":{"firmwareScrollActive":true,"scrollFrameCount":40,"scrollFrameIndex":3,"groupTimed":true}}"#)
        await waitUntil { connection.status?.renderer?.groupTimed == true }

        XCTAssertFalse(model.boardHasScroll(connection: connection),
                       "a group-timed scroll this page never bound must not read as this page's own scroll")
    }

    func testPhaseKeyIsIdleForUnboundGroupTimedScrollEvenThoughFirmwareIsActive() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        XCTAssertNil(model.boundTimelineId)

        transport.pushStatus(#"{"renderer":{"firmwareScrollActive":true,"scrollFrameCount":40,"scrollFrameIndex":3,"groupTimed":true}}"#)
        await waitUntil { connection.status?.renderer?.groupTimed == true }

        XCTAssertEqual(model.phaseKey(connection: connection), "IDLE",
                       "the single-board page must not claim 播放中/PAUSED for a group scroll it doesn't render")
    }

    /// Once this page actually binds a timeline (`boundTimelineId != nil`),
    /// the `groupTimed` guard must not suppress its own normal reporting —
    /// only an *unbound* group-timed scroll is foreign.
    func testBoardHasScrollStillTrueWhenBoundEvenIfGroupTimedFlagIsSet() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        model.boundTimelineId = "some-timeline"

        transport.pushStatus(#"{"renderer":{"firmwareScrollActive":true,"scrollFrameCount":40,"scrollFrameIndex":3,"groupTimed":true}}"#)
        await waitUntil { connection.status?.renderer?.groupTimed == true }

        XCTAssertTrue(model.boardHasScroll(connection: connection))
    }

    /// A paused group leaves firmware group-timed mode, so `groupTimed` is
    /// false while the scroll is still the group's: the output owner decides.
    func testPausedGroupScrollIsNotThisPagesWhileTheGroupOwnsTheOutput() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        _ = connection.output.claim(.group)

        transport.pushStatus(#"{"renderer":{"firmwareScrollActive":true,"firmwareScrollPaused":true,"scrollFrameCount":40,"scrollFrameIndex":3,"groupTimed":false}}"#)
        await waitUntil { connection.status?.renderer?.scrollFrameCount == 40 }

        XCTAssertFalse(model.boardHasScroll(connection: connection))
        XCTAssertEqual(model.phaseKey(connection: connection), "IDLE")
    }

    // MARK: - Helpers

    private func connectedBoard() async throws -> (BoardConnection, MinimalStatusPushTransport) {
        let transport = MinimalStatusPushTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Replies `{"ok":true}` to every request and can push an unsolicited
/// EV_STATUS frame, like `RecordingTextTransport` in `TextTransportTests`
/// but pared down to only what these offline-reachable tests need.
@MainActor
private final class MinimalStatusPushTransport: @MainActor RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512

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
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0,
                              payload: Data(#"{"ok":true}"#.utf8))
            ))
        }
    }

    func pushStatus(_ json: String) {
        incomingContinuation?.yield(try! RinaLinkEncoder.encode(
            RinaLinkFrame(type: RinaLinkMessageType.evStatus.rawValue, seq: 0, flags: 0, payload: Data(json.utf8))
        ))
    }
}
