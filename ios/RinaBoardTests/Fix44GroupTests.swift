import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Group sync clock (30), adoption after a reorder made while orphaned (31),
/// and the held frame of a pause that follows a restart (32).
@MainActor
final class Fix44GroupTests: XCTestCase {
    private static let longScrollText = String(repeating: "你好世界，这是分步测试文字。", count: 3)

    private func connectedSession(
        sessions: BoardSessionStore, identity: String, transport: Fix44GroupTransport
    ) async -> BoardSession {
        let session = sessions.session(for: "ble:\(UUID().uuidString)", name: identity)
        transport.wifiBoardId = identity
        _ = await session.connection.connect(using: transport)
        return session
    }

    private func runningMeta(timelineId: String, text: String, frameCount: Int, frameIndex: Int,
                             paused: Bool) -> [String: Any] {
        [
            "ok": true, "scrollTimelineId": timelineId, "hasSourceText": true, "sourceText": text,
            "frameCount": frameCount, "frameIndex": frameIndex, "scrollIntervalMs": 100,
            "firmwareScrollActive": true, "firmwareScrollPaused": paused, "scrollLoop": true,
            "groupTimed": !paused,
        ]
    }

    // MARK: - 30

    /// The default group clock must include time asleep: it can never read
    /// less than the uptime clock, which stops while the device sleeps.
    func testDefaultGroupClockIsMonotonicAndNotBehindUptime() {
        let uptimeUs = Int64(DispatchTime.now().uptimeNanoseconds / 1000)
        let first = BoardGroupCoordinator.continuousNowUs()
        let second = BoardGroupCoordinator.continuousNowUs()
        XCTAssertGreaterThanOrEqual(first, uptimeUs)
        XCTAssertGreaterThanOrEqual(second, first)
    }

    // MARK: - 31

    func testPlayedLayoutPersistsAndDropsRemovedGroups() throws {
        let defaults = makeIsolatedDefaults()
        let store = BoardGroupStore(defaults: defaults)
        let kept = store.create(name: "保留")
        let removed = store.create(name: "删除")
        let layout = BoardGroupStore.PlayedLayout(timelineId: "T1", virtualWidth: 44, viewportXs: ["A": 0, "B": 22])
        store.recordPlayedLayout(layout, groupID: removed.id)
        XCTAssertEqual(BoardGroupStore(defaults: defaults).playedLayout(groupID: removed.id), layout)
        XCTAssertNil(store.playedLayout(groupID: kept.id))

        store.remove(id: removed.id)
        store.recordPlayedLayout(layout, groupID: kept.id)

        let reloaded = BoardGroupStore(defaults: defaults)
        XCTAssertEqual(reloaded.playedLayout(groupID: kept.id), layout)
        XCTAssertNil(reloaded.playedLayout(groupID: removed.id))
    }

    /// A reorder while nothing drives the group changes neither the text nor
    /// the frame count the boards report. Adoption must then upload the new
    /// layout's viewports instead of silently keeping the old ones.
    func testAdoptionAfterReorderWhileOrphanedReuploadsNewViewports() async throws {
        let sessions = BoardSessionStore()
        let defaults = makeIsolatedDefaults()
        let store = BoardGroupStore(defaults: defaults)
        let first = BoardGroupCoordinator(store: store, sessions: sessions)
        let ids = ["A", "B", "C"]
        var transports: [String: Fix44GroupTransport] = [:]
        let group = store.create(name: "重排接管组")
        for id in ids {
            let transport = Fix44GroupTransport()
            transports[id] = transport
            _ = await connectedSession(sessions: sessions, identity: id, transport: transport)
            try store.addMember(groupID: group.id, member: .init(physicalBoardID: id, displayName: id))
        }
        try await first.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        let frameCount = try XCTUnwrap(first.playbackSnapshot?.frameCount)
        let timelineId = try XCTUnwrap(transports["A"]?.lastBlobBeginMeta?["timelineId"] as? String)
        XCTAssertEqual(store.playedLayout(groupID: group.id)?.timelineId, timelineId)
        XCTAssertEqual(store.playedLayout(groupID: group.id)?.viewportXs,
                       ["A": 0, "B": MatrixGeometry.cols, "C": 2 * MatrixGeometry.cols])
        for transport in transports.values {
            transport.scrollMeta = runningMeta(timelineId: timelineId, text: Self.longScrollText,
                                               frameCount: frameCount, frameIndex: 5, paused: false)
        }
        let uploadsBefore = transports.mapValues { $0.blobBeginCount }

        // App relaunch: new store and coordinator, then a reorder before adoption.
        first.markSupersededByControl()
        let relaunchedStore = BoardGroupStore(defaults: defaults)
        relaunchedStore.swapMembers(groupID: group.id, 0, 2)
        let relaunched = BoardGroupCoordinator(store: relaunchedStore, sessions: sessions)

        let adopted = await relaunched.adoptRunningScroll(group: relaunchedStore.groups[0], loop: true)

        XCTAssertTrue(adopted)
        XCTAssertTrue(relaunched.isPlaying)
        for id in ids {
            XCTAssertEqual(transports[id]?.blobBeginCount, (uploadsBefore[id] ?? 0) + 1,
                           "board \(id) must be uploaded the new layout")
        }
        XCTAssertEqual(transports["C"]?.lastBlobBeginMeta?["viewportX"] as? Int, 0)
        XCTAssertEqual(transports["B"]?.lastBlobBeginMeta?["viewportX"] as? Int, MatrixGeometry.cols)
        XCTAssertEqual(transports["A"]?.lastBlobBeginMeta?["viewportX"] as? Int, 2 * MatrixGeometry.cols)
        XCTAssertEqual(relaunched.playbackSnapshot?.memberOrder.map(\.physicalBoardID), ["C", "B", "A"])
        let newTimelineId = try XCTUnwrap(transports["A"]?.lastBlobBeginMeta?["timelineId"] as? String)
        XCTAssertNotEqual(newTimelineId, timelineId)
        XCTAssertEqual(relaunchedStore.playedLayout(groupID: group.id)?.timelineId, newTimelineId)
        XCTAssertGreaterThanOrEqual(transports["A"]?.sentGroupStartFrames.last ?? -1, 5,
                                    "the restart continues from where the boards were")
        await relaunched.stop(group: relaunchedStore.groups[0])
    }

    /// The record survives a relaunch: an unchanged layout is still adopted
    /// without re-uploading by a store freshly loaded from the same defaults.
    func testAdoptionWithUnchangedLayoutAfterRelaunchDoesNotReupload() async throws {
        let sessions = BoardSessionStore()
        let defaults = makeIsolatedDefaults()
        let store = BoardGroupStore(defaults: defaults)
        let first = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = Fix44GroupTransport()
        let transportB = Fix44GroupTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "原样接管组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await first.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        let frameCount = try XCTUnwrap(first.playbackSnapshot?.frameCount)
        let timelineId = try XCTUnwrap(transportA.lastBlobBeginMeta?["timelineId"] as? String)
        for transport in [transportA, transportB] {
            transport.scrollMeta = runningMeta(timelineId: timelineId, text: Self.longScrollText,
                                               frameCount: frameCount, frameIndex: 5, paused: false)
        }
        let uploadsBefore = transportA.blobBeginCount + transportB.blobBeginCount

        first.markSupersededByControl()
        let relaunchedStore = BoardGroupStore(defaults: defaults)
        let relaunched = BoardGroupCoordinator(store: relaunchedStore, sessions: sessions)
        let adopted = await relaunched.adoptRunningScroll(group: relaunchedStore.groups[0], loop: true)

        XCTAssertTrue(adopted)
        XCTAssertTrue(relaunched.isPlaying)
        XCTAssertEqual(transportA.blobBeginCount + transportB.blobBeginCount, uploadsBefore)
        await relaunched.stop(group: relaunchedStore.groups[0])
    }

    // MARK: - 32

    /// A `group_start` reply that outlasts the start margin puts the new
    /// anchor in the past before the re-pause runs. The step must still land
    /// on the requested frame.
    func testStepRestartWithSlowGroupStartHoldsRequestedFrame() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: makeIsolatedDefaults())
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = Fix44GroupTransport()
        let transportB = Fix44GroupTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "慢回复逐帧组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPaused)
        let frameCount = try XCTUnwrap(coordinator.playbackSnapshot?.frameCount)
        XCTAssertGreaterThan(frameCount, 30)
        let target = (coordinator.pausedFrame + 1) % frameCount

        let newTransportB = Fix44GroupTransport()
        newTransportB.wifiBoardId = "B"
        // Well past the 400 ms start margin, at 100 ms per frame.
        newTransportB.cmdReplyDelay["group_start"] = 0.9
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.step(group: store.groups[0], direction: 1)

        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(coordinator.pausedFrame, target)
        XCTAssertEqual(transportA.sentScrollSeekFrames.last, target)
        XCTAssertEqual(newTransportB.sentScrollSeekFrames.last, target)
        await coordinator.stop(group: store.groups[0])
    }

    /// Same for taking back a paused group: it stays on the frame the boards
    /// were paused on, however long the adoption's `group_start` took.
    func testPausedAdoptionWithSlowGroupStartHoldsBoardFrame() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: makeIsolatedDefaults())
        let first = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = Fix44GroupTransport()
        let transportB = Fix44GroupTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "慢回复暂停接管组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await first.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        let frameCount = try XCTUnwrap(first.playbackSnapshot?.frameCount)
        XCTAssertGreaterThan(frameCount, 30)
        let timelineId = try XCTUnwrap(transportA.lastBlobBeginMeta?["timelineId"] as? String)
        for transport in [transportA, transportB] {
            transport.scrollMeta = runningMeta(timelineId: timelineId, text: Self.longScrollText,
                                               frameCount: frameCount, frameIndex: 5, paused: true)
        }
        transportB.cmdReplyDelay["group_start"] = 0.9
        first.markSupersededByControl()
        let relaunched = BoardGroupCoordinator(store: store, sessions: sessions)

        let adopted = await relaunched.adoptRunningScroll(group: store.groups[0], loop: true)

        XCTAssertTrue(adopted)
        XCTAssertTrue(relaunched.isPaused)
        XCTAssertEqual(relaunched.pausedFrame, 5)
        XCTAssertEqual(transportA.sentScrollSeekFrames.last, 5)
        XCTAssertEqual(transportB.sentScrollSeekFrames.last, 5)
        await relaunched.stop(group: store.groups[0])
    }
}

// MARK: - Fake transport

/// The subset of `BoardGroupTests`' file-private `GroupFakeTransport` these
/// tests need: replies to the board-group commands and `scroll_bitmap`
/// uploads, and records what each board was sent.
@MainActor
private final class Fix44GroupTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var bootId = "aaaaaaaa"
    var caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
    var wifiBoardId: String?
    /// Per-`cmd`-name reply delay.
    var cmdReplyDelay: [String: TimeInterval] = [:]
    /// `GET_SCROLL_META` reply; `nil` replies with an empty meta.
    var scrollMeta: [String: Any]?
    private(set) var blobBeginCount = 0
    private(set) var lastBlobBeginMeta: [String: Any]?
    private(set) var sentGroupStartFrames: [Int] = []
    private(set) var sentScrollSeekFrames: [Int] = []

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            let delay = delay(for: request)
            if delay > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self else { return }
                    self.emitReply(request, payload: self.replyPayload(for: request))
                }
            } else {
                emitReply(request, payload: replyPayload(for: request))
            }
        }
    }

    private func commandObject(_ request: RinaLinkFrame) -> [String: Any]? {
        guard request.type == RinaLinkMessageType.cmd.rawValue else { return nil }
        return try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
    }

    private func delay(for request: RinaLinkFrame) -> TimeInterval {
        guard let cmd = commandObject(request)?["cmd"] as? String else { return 0 }
        return cmdReplyDelay[cmd] ?? 0
    }

    private func emitReply(_ request: RinaLinkFrame, payload: Data) {
        incomingContinuation?.yield(try! RinaLinkEncoder.encode(
            RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
        ))
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            var wifi: [String: Any] = ["ip": "192.168.4.1"]
            if let wifiBoardId { wifi["boardId"] = wifiBoardId }
            return json(["ok": true, "renderer": ["mode": "manual"], "power": [String: Any](), "wifi": wifi])
        case .getPreviewSync:
            return json(["ok": true, "mode": "manual"])
        case .getFrame:
            return PackedFrame().data
        case .getScrollMeta:
            return json(scrollMeta ?? ["ok": true])
        case .blobBegin:
            blobBeginCount += 1
            if let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any] {
                lastBlobBeginMeta = object
            }
            return Data(#"{"ok":true,"offset":0,"chunkMax":512}"#.utf8)
        case .blobChunk:
            let offset = request.payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            return json(["ok": true, "offset": Int(offset) + max(0, request.payload.count - 4)])
        case .cmd:
            guard let object = commandObject(request), let cmd = object["cmd"] as? String else {
                return Data(#"{"ok":true}"#.utf8)
            }
            switch cmd {
            case "get_info":
                return json(["ok": true, "proto": 1, "bootId": bootId, "caps": caps])
            case "clock_sample":
                return json(["ok": true, "rxUs": 1_000, "txUs": 1_200, "bootId": bootId])
            case "group_start":
                sentGroupStartFrames.append(object["startFrame"] as? Int ?? 0)
                return json(["ok": true, "nowUs": 0, "frameCount": 10])
            case "scroll_seek":
                sentScrollSeekFrames.append(object["frameIndex"] as? Int ?? -1)
                return Data(#"{"ok":true}"#.utf8)
            default:
                return Data(#"{"ok":true}"#.utf8)
            }
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
