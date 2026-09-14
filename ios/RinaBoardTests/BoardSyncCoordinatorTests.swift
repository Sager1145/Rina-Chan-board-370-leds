import Foundation
import XCTest
import SwiftUI
import RinaCore
@testable import RinaBoard

/// Host-level tests for `BoardSyncCoordinator`, the type extracted from
/// `RootTabView`'s `.task(id:)` closure so board-session switches and
/// foreground-resume behavior can be driven without a SwiftUI host.
@MainActor
final class BoardSyncCoordinatorTests: XCTestCase {

    // MARK: Fix — resumeGeneration bump must not cancel an in-flight text upload

    /// DB-RB-03: selecting another session, or a same-board reset (a new
    /// connection generation), must still clear the Text tab's board-relative
    /// state; a pure foreground-return resume (same generation, same active
    /// session) must not.
    func testResumeOnlyReRunDoesNotClearTextModelButARealChangeDoes() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        let transport = SyncTransport()
        let connected1 = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected1)

        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: false)
        deps.textModel.timeline = try makeTimeline()
        deps.textModel.boundTimelineId = "resume-check"

        // A pure foreground-return resume (RootTabView's `resumeGeneration`
        // bump): same connection generation, same active session.
        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: false)
        XCTAssertEqual(deps.textModel.boundTimelineId, "resume-check",
                       "a resume-only re-run must not cancel an in-flight text upload")

        // A same-board reset changes the connection generation.
        sessions.active.connection.disconnect()
        let connected2 = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected2)
        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: false)
        XCTAssertNil(deps.textModel.boundTimelineId, "a real generation change must still clear")
    }

    // MARK: Fix — root-level wiring: switching sessions resets, then rebinds

    /// Two sessions: A is restored with a bound scroll timeline; selecting B
    /// clears it; reselecting a since-reset, idle A leaves the Text page
    /// empty with the draft untouched; a later scrolling A rebinds a timeline.
    func testTwoSessionSwitchResetsThenRebindsTimeline() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        deps.textModel.editText("draft kept across board switches")

        let sessionA = sessions.session(for: "board-a", name: "A")
        let sessionB = sessions.session(for: "board-b", name: "B")
        XCTAssertTrue(sessions.active === sessionA)

        let timeline = try makeTimeline(text: "Scrolling on A")
        let transportA1 = SyncTransport()
        transportA1.status = scrollingStatus(timeline: timeline)
        transportA1.scrollMeta = scrollingMeta(timeline: timeline)
        transportA1.preview = scrollingPreview(timeline: timeline)
        let connectedA1 = await sessionA.connection.connect(using: transportA1)
        XCTAssertTrue(connectedA1)

        await synchronize(coordinator, connection: sessionA.connection, deps: deps, draftsRestored: true)
        XCTAssertEqual(deps.textModel.frameCount, timeline.frameCount,
                       "A's scroll timeline must be bound after its first sync")

        // Select B (idle): the active session changes.
        let transportB = SyncTransport()
        let connectedB = await sessionB.connection.connect(using: transportB)
        XCTAssertTrue(connectedB)
        sessions.select(sessionB)
        await synchronize(coordinator, connection: sessionB.connection, deps: deps, draftsRestored: true)
        XCTAssertEqual(deps.textModel.frameCount, 0)
        XCTAssertEqual(deps.textModel.previewFrame, PackedFrame())

        // A resets (a real reconnect: new connection generation) while B was
        // active, and comes back idle.
        sessionA.connection.disconnect()
        let transportA2 = SyncTransport()
        transportA2.status = idleStatus()
        let connectedA2 = await sessionA.connection.connect(using: transportA2)
        XCTAssertTrue(connectedA2)

        // Reselect A: idle.
        sessions.select(sessionA)
        await synchronize(coordinator, connection: sessionA.connection, deps: deps, draftsRestored: true)
        XCTAssertEqual(deps.textModel.frameCount, 0, "an idle board must not show a stale timeline")
        XCTAssertEqual(deps.textModel.previewFrame, PackedFrame(), "preview must be blank while idle")
        XCTAssertEqual(deps.textModel.text, "draft kept across board switches",
                       "the unsent draft must survive every board switch")

        // A resets again, now scrolling: selecting it rebinds the timeline.
        sessionA.connection.disconnect()
        let timeline2 = try makeTimeline(text: "Scrolling again on A")
        let transportA3 = SyncTransport()
        transportA3.status = scrollingStatus(timeline: timeline2)
        transportA3.scrollMeta = scrollingMeta(timeline: timeline2)
        transportA3.preview = scrollingPreview(timeline: timeline2)
        let connectedA3 = await sessionA.connection.connect(using: transportA3)
        XCTAssertTrue(connectedA3)
        await synchronize(coordinator, connection: sessionA.connection, deps: deps, draftsRestored: true)

        XCTAssertEqual(deps.textModel.frameCount, timeline2.frameCount,
                       "a scrolling A must rebind its timeline")
    }

    // MARK: Helpers

    private func synchronize(
        _ coordinator: BoardSyncCoordinator, connection: BoardConnection,
        deps: BoardSyncCoordinator.Dependencies, draftsRestored: Bool
    ) async {
        await coordinator.synchronize(
            connection: connection, deps: deps, draftsRestored: draftsRestored,
            scenePhase: .active, showControlCenter: .constant(false), configureOutputHandlers: {}
        )
    }

    private func makeDeps(sessions: BoardSessionStore) -> BoardSyncCoordinator.Dependencies {
        let suiteName = "BoardSyncCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return BoardSyncCoordinator.Dependencies(
            sessions: sessions,
            router: AppRouter(),
            boardStore: BoardStore(defaults: defaults),
            editor: ControlViewModel(),
            textModel: TextViewModel(),
            lipSyncModel: LipSyncModel(),
            controlCenter: BoardControlCenterModel(),
            faceLibrary: FaceLibraryModel(),
            performance: PresetLiveModel(),
            video: VideoPlayerModel()
        )
    }

    private func makeTimeline(text: String = "Rina") throws -> ScrollTimeline {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"),
                                "Hosted tests need the app's bundled font")
        let font = try ArkPixelFont.loadBundled(url: url)
        return try ScrollRasterizer.makeTimeline(text: text, font: font, fps: 10)
    }

    private func idleStatus() -> DeviceStatus {
        DeviceStatus(ok: true, renderer: RendererStatus(mode: "manual", playback: "idle"))
    }

    private func scrollingStatus(timeline: ScrollTimeline) -> DeviceStatus {
        DeviceStatus(ok: true, renderer: RendererStatus(
            mode: "manual", playback: "scroll", firmwareScrollActive: true, firmwareScrollPaused: false,
            scrollFrameCount: timeline.frameCount, scrollFrameIndex: 0, scrollIntervalMs: 100, uiFps: 10,
            scrollTimelineId: timeline.timelineId, scrollLoop: true
        ))
    }

    private func scrollingMeta(timeline: ScrollTimeline) -> ScrollMeta {
        ScrollMeta(
            ok: true, scrollTimelineId: timeline.timelineId, hasSourceText: true, sourceText: timeline.text,
            sourceTextBytes: timeline.text.utf8.count, fontId: ScrollRasterizer.fontId,
            generatorVersion: ScrollRasterizer.generatorVersion, uiFps: 10, scrollIntervalMs: 100,
            frameCount: timeline.frameCount, frameIndex: 0, uploadComplete: true,
            firmwareScrollActive: true, firmwareScrollPaused: false, scrollLoop: true
        )
    }

    private func scrollingPreview(timeline: ScrollTimeline) -> PreviewSync {
        PreviewSync(
            ok: true, playback: "scroll", valid: true, presentedSeq: 1, source: "scroll_tick",
            scrollTimelineId: timeline.timelineId, presentedFrameIndex: 0, presentedFrameCount: timeline.frameCount,
            scrollIntervalMs: 100, uiFps: 10, firmwareScrollActive: true, firmwareScrollPaused: false
        )
    }
}

/// A minimal `RinaTransport` fake that replies to every request the
/// connection setup and `BoardSyncCoordinator`'s resync path need
/// (`ping`, `cmd` subscribe/get_info, `get_status`, `get_frame`,
/// `get_preview_sync`, `get_scroll_meta`), with `status`/`preview`/`scrollMeta`
/// mutable so a test can change what the "board" reports between syncs.
@MainActor
private final class SyncTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var status = DeviceStatus(ok: true, renderer: RendererStatus(mode: "manual", playback: "idle"))
    var preview: PreviewSync?
    var scrollMeta: ScrollMeta?

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }

    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            let payload = replyPayload(for: request)
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
            ))
        }
    }

    private func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            return (try? JSONEncoder().encode(status)) ?? Data()
        case .getPreviewSync:
            return (try? JSONEncoder().encode(preview ?? PreviewSync(ok: true))) ?? Data()
        case .getScrollMeta:
            return (try? JSONEncoder().encode(scrollMeta ?? ScrollMeta(ok: true))) ?? Data()
        case .getFrame:
            return PackedFrame().data
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
