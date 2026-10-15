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

    // MARK: Fix — the live scene phase is re-checked after BLE round trips

    /// R19: a BLE round trip inside `getStatus` can outlast foregrounding —
    /// if the phase closure reports `.background` by the time it answers,
    /// the resync must not start the scroll restore (or any other
    /// playback/mic start) it would otherwise begin.
    func testBackgroundingDuringGetStatusBlocksRestoreEvenAfterRelease() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        var phase = ScenePhase.active
        let deps = makeDeps(sessions: sessions, scenePhase: { phase })
        let timeline = try makeTimeline(text: "Scrolling while backgrounding")
        let transport = SyncTransport()
        transport.status = scrollingStatus(timeline: timeline)
        transport.scrollMeta = scrollingMeta(timeline: timeline)
        transport.preview = scrollingPreview(timeline: timeline)
        let gate = SyncGate()
        transport.statusGate = gate
        let connected = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected)

        let syncTask = Task {
            await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)
        }
        await gate.waitUntilReached()
        phase = .background
        await gate.release()
        await syncTask.value

        XCTAssertEqual(deps.textModel.frameCount, 0,
                       "backgrounding mid-round-trip must not start the scroll restore")
        XCTAssertFalse(deps.video.isPlaying, "backgrounding mid-round-trip must not start video playback")
        XCTAssertFalse(deps.performance.isPlaying, "backgrounding mid-round-trip must not start a performance")
    }

    // MARK: Connecting from Settings stays in Settings

    /// Before iOS 26 the Control Center is a page pushed inside Settings, so a
    /// board switch made there must not throw the user onto the tab that owns
    /// the board's mode. From any other tab the jump still happens.
    func testConnectingFromSettingsDoesNotSwitchTabs() async throws {
        let timeline = try makeTimeline(text: "Scrolling")

        for (startTab, expectedTab) in [(AppTab.settings, AppTab.settings), (.control, .text)] {
            let sessions = BoardSessionStore()
            let coordinator = BoardSyncCoordinator()
            let deps = makeDeps(sessions: sessions)
            deps.router.selectedTab = startTab
            let transport = SyncTransport()
            transport.status = scrollingStatus(timeline: timeline)
            transport.scrollMeta = scrollingMeta(timeline: timeline)
            transport.preview = scrollingPreview(timeline: timeline)
            let connected = await sessions.active.connection.connect(using: transport)
            XCTAssertTrue(connected)

            await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)
            XCTAssertEqual(deps.router.selectedTab, expectedTab, "connected from \(startTab)")
        }
    }

    // MARK: Reconnection preserves the user's tab

    func testIdleBoardReconnectPreservesTextTabAndReconcilesBoardState() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        let connection = sessions.active.connection
        let connected = await connection.connect(using: SyncTransport())
        XCTAssertTrue(connected)
        await synchronize(coordinator, connection: connection, deps: deps, draftsRestored: true)

        deps.router.selectedTab = .text
        deps.textModel.editText("draft survives reconnect")
        deps.textModel.boundTimelineId = "stale-board-timeline"
        connection.disconnect()
        await synchronize(coordinator, connection: connection, deps: deps, draftsRestored: true)

        let reconnectTransport = SyncTransport()
        reconnectTransport.status = DeviceStatus(ok: true, renderer: RendererStatus(
            brightness: 73, mode: "manual", playback: "idle"
        ))
        let reconnected = await connection.connect(using: reconnectTransport)
        XCTAssertTrue(reconnected)
        deps.controlCenter.brightnessDraft = 12
        await synchronize(coordinator, connection: connection, deps: deps, draftsRestored: true)

        XCTAssertEqual(deps.router.selectedTab, .text,
                       "recovering the same idle board must preserve the user's Text tab")
        XCTAssertNil(deps.textModel.boundTimelineId, "reconnection must still clear stale board-relative state")
        XCTAssertEqual(deps.textModel.text, "draft survives reconnect")
        XCTAssertEqual(deps.controlCenter.brightnessDraft, 73,
                       "reconnection must still read and synchronize board controls")
    }

    func testInitialConnectionAndExplicitBoardSwitchRestoreIdleBoardTab() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        let sessionA = sessions.session(for: "board-a", name: "A")
        let sessionB = sessions.session(for: "board-b", name: "B")

        deps.router.selectedTab = .text
        let connectedA = await sessionA.connection.connect(using: SyncTransport())
        XCTAssertTrue(connectedA)
        await synchronize(coordinator, connection: sessionA.connection, deps: deps, draftsRestored: true)
        XCTAssertEqual(deps.router.selectedTab, .control, "initial connection must restore the board's mode")

        deps.router.selectedTab = .text
        let connectedB = await sessionB.connection.connect(using: SyncTransport())
        XCTAssertTrue(connectedB)
        sessions.select(sessionB)
        await synchronize(coordinator, connection: sessionB.connection, deps: deps, draftsRestored: true)
        XCTAssertEqual(deps.router.selectedTab, .control, "explicit board selection must restore its mode")
    }

    // MARK: Launch preview gate release points

    /// The connected resync path (§40's re-read-then-reconcile) is the only
    /// place that opens `AppRouter`'s launch preview gate; the initial,
    /// still-disconnected `synchronize` call above it must leave the gate
    /// alone so `AppRouter`'s own timeout — not a spurious early release —
    /// is what protects a board that never connects.
    func testConnectedResyncReleasesTheLaunchGate() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        deps.router.armLaunchPreviewGate(timeout: .seconds(8))
        let transport = SyncTransport()
        let connected = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected)

        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)
        XCTAssertFalse(deps.router.launchPreviewPending,
                       "a connected resync must open the launch preview gate")
    }

    func testFailedGetStatusStillReleasesTheLaunchGate() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        deps.router.armLaunchPreviewGate(timeout: .seconds(8))
        let transport = SyncTransport()
        transport.failGetStatus = true
        let connected = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected)

        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)
        XCTAssertFalse(deps.router.launchPreviewPending,
                       "a failed getStatus must still open the gate, not leave every preview blank")
    }

    // MARK: Handshake snapshot is not read twice

    /// A non-resume sync whose handshake already decoded status must not
    /// send another `GET_STATUS`. Preview rides along. The control frame is
    /// read again: the handshake frame is not updated by later events.
    func testNonResumeSyncWithPopulatedHandshakeSendsNoSecondGetStatus() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        let transport = SyncTransport()
        transport.status = DeviceStatus(ok: true, renderer: RendererStatus(
            brightness: 55, mode: "manual", playback: "idle"
        ))
        let connected = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected)
        XCTAssertNotNil(sessions.active.connection.status)
        let statusBefore = transport.getStatusCount
        let previewBefore = transport.getPreviewSyncCount
        let frameBefore = transport.getFrameCount

        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)

        XCTAssertEqual(transport.getStatusCount, statusBefore,
                       "a populated handshake must not be followed by another getStatus")
        XCTAssertEqual(transport.getPreviewSyncCount, previewBefore,
                       "a populated handshake preview must not be fetched again")
        XCTAssertEqual(transport.getFrameCount, frameBefore + 1,
                       "control mode must send getFrame even when the handshake already has a frame")
        XCTAssertEqual(deps.controlCenter.brightnessDraft, 55,
                       "the handshake status must still drive the control draft")
    }

    /// `setupStatusReadFailed` leaves `status` nil. That sync still sends one
    /// `GET_STATUS` and returns through today's failure path when it fails.
    func testNilHandshakeStatusStillSendsOneGetStatus() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        let transport = SyncTransport()
        transport.status = DeviceStatus(ok: true, renderer: RendererStatus(
            brightness: 41, mode: "manual", playback: "idle"
        ))
        transport.failNextGetStatus = 1
        let connected = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected)
        XCTAssertNil(sessions.active.connection.status)
        let statusBefore = transport.getStatusCount

        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)

        XCTAssertEqual(transport.getStatusCount, statusBefore + 1,
                       "a nil handshake status must still send one getStatus")
        XCTAssertEqual(deps.controlCenter.brightnessDraft, 41,
                       "the wire getStatus must still synchronize controls")
    }

    /// R19's resume path: same generation and session, foreground return.
    /// That re-run still hits `GET_STATUS` even when the handshake is populated.
    func testResumeOnlySyncStillSendsGetStatus() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        let transport = SyncTransport()
        let connected = await sessions.active.connection.connect(using: transport)
        XCTAssertTrue(connected)

        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)
        let statusBefore = transport.getStatusCount
        let previewBefore = transport.getPreviewSyncCount

        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: true)

        XCTAssertEqual(transport.getStatusCount, statusBefore + 1,
                       "a resume-only re-run must still send getStatus")
        XCTAssertEqual(transport.getPreviewSyncCount, previewBefore + 1,
                       "a resume-only re-run must still send getPreviewSync")
    }

    func testInitialDisconnectedSynchronizeDoesNotReleaseTheLaunchGate() async throws {
        let sessions = BoardSessionStore()
        let coordinator = BoardSyncCoordinator()
        let deps = makeDeps(sessions: sessions)
        deps.router.armLaunchPreviewGate(timeout: .seconds(8))

        // Still disconnected: `draftsRestored` is false, matching the very
        // first `.task(id:)` run in `RootTabView` before drafts restore.
        await synchronize(coordinator, connection: sessions.active.connection, deps: deps, draftsRestored: false)
        XCTAssertTrue(deps.router.launchPreviewPending,
                       "the initial disconnected synchronize must not open the gate on its own")
    }

    // MARK: Helpers

    private func synchronize(
        _ coordinator: BoardSyncCoordinator, connection: BoardConnection,
        deps: BoardSyncCoordinator.Dependencies, draftsRestored: Bool
    ) async {
        await coordinator.synchronize(
            connection: connection, deps: deps, draftsRestored: draftsRestored,
            showControlCenter: .constant(false), configureOutputHandlers: {}
        )
    }

    private func makeDeps(
        sessions: BoardSessionStore, scenePhase: @escaping @MainActor () -> ScenePhase = { .active }
    ) -> BoardSyncCoordinator.Dependencies {
        let defaults = makeIsolatedDefaults()
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
            video: VideoPlayerModel(),
            scenePhase: scenePhase
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
    /// When set, `send(_:)` suspends before replying to a `getStatus`
    /// request until the test calls `SyncGate.release()` — lets a test flip
    /// the live scene-phase closure while a resync round trip is in flight.
    var statusGate: SyncGate?
    /// Forces `getStatus` to fail decode, so a test can drive the resync
    /// path's early-return branch without a real transport error.
    var failGetStatus = false
    /// The next this-many `GET_STATUS` replies are not JSON. One leaves the
    /// handshake `status` nil while a later resync read can still succeed.
    var failNextGetStatus = 0
    private(set) var getStatusCount = 0
    private(set) var getPreviewSyncCount = 0
    private(set) var getFrameCount = 0

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }

    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            switch RinaLinkMessageType(rawValue: request.type) {
            case .getStatus:
                getStatusCount += 1
                if let statusGate { await statusGate.hold() }
            case .getPreviewSync:
                getPreviewSyncCount += 1
            case .getFrame:
                getFrameCount += 1
            default:
                break
            }
            let payload = replyPayload(for: request)
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
            ))
        }
    }

    private func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            if failNextGetStatus > 0 {
                failNextGetStatus -= 1
                return Data("not json".utf8)
            }
            if failGetStatus { return Data("not json".utf8) }
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

/// Deterministically suspends one round trip so a test can flip the live
/// scene-phase closure while `BoardSyncCoordinator` is mid-await. No sleeps:
/// backed by `CheckedContinuation`.
private actor SyncGate {
    private var released = false
    private var reached = false
    private var reachedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    /// Called from the transport. Suspends until `release()`.
    func hold() async {
        reached = true
        let waiters = reachedContinuations
        reachedContinuations = []
        for continuation in waiters { continuation.resume() }
        if released { return }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    /// Suspends until a `hold()` call has been reached.
    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { reachedContinuations.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseContinuations
        releaseContinuations = []
        for continuation in waiters { continuation.resume() }
    }
}
