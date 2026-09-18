import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

// MARK: - Store tests

@MainActor
final class BoardGroupStoreTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, String) {
        let suiteName = "BoardGroupStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    func testPersistenceRoundTrip() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        let group = store.create(name: "客厅两块")
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA1111", displayName: "左"))
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB2222", displayName: "右"))
        store.setMode(id: group.id, mode: .mirror)

        let reloaded = BoardGroupStore(defaults: defaults)
        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups[0].name, "客厅两块")
        XCTAssertEqual(reloaded.groups[0].members.map(\.physicalBoardID), ["AAAA1111", "BBBB2222"])
        XCTAssertEqual(reloaded.groups[0].mode, .mirror)
        XCTAssertEqual(reloaded.groups[0].gapsAfter, [0])
    }

    func testCorruptDataToleratesAndKeepsInMemoryState() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        let group = store.create(name: "组一")

        // Simulate another process writing corrupt JSON to the same key.
        defaults.set(Data("not json".utf8), forKey: "com.rinachan.board.groups")

        let reloaded = BoardGroupStore(defaults: defaults)
        // Decode failure must not wipe the in-memory list of the *new*
        // instance either -- it just keeps whatever load() left it with,
        // which for a fresh instance reading corrupt data is empty, not a
        // crash and not silently discarding the previously-valid group's id.
        XCTAssertEqual(reloaded.groups.count, 0)
        XCTAssertEqual(store.groups.first?.id, group.id, "the original in-memory store must be untouched")
    }

    func testReorderBumpsLayoutRevision() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        let group = store.create(name: "三块")
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "C", displayName: "C"))
        let revisionBefore = store.groups[0].layoutRevision

        store.moveMember(groupID: group.id, from: 2, to: 0)

        XCTAssertEqual(store.groups[0].members.map(\.physicalBoardID), ["C", "A", "B"])
        XCTAssertGreaterThan(store.groups[0].layoutRevision, revisionBefore)
    }

    func testSetModeBumpsLayoutRevision() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        let group = store.create(name: "模式组")
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        let revisionBefore = store.groups[0].layoutRevision

        store.setMode(id: group.id, mode: .mirror)

        XCTAssertEqual(store.groups[0].mode, .mirror)
        XCTAssertGreaterThan(store.groups[0].layoutRevision, revisionBefore)
    }

    func testMaxMembersAndDuplicateRejected() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        let group = store.create(name: "满员")
        for index in 0..<5 {
            try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "ID\(index)", displayName: "板\(index)"))
        }
        XCTAssertThrowsError(try store.addMember(groupID: group.id, member: .init(physicalBoardID: "ID5", displayName: "多余"))) { error in
            XCTAssertEqual(error as? BoardGroupStore.GroupError, .tooManyMembers)
        }
        // Re-fetch a fresh group value (the 6th add above must not have mutated it).
        store.remove(id: group.id)
        let second = store.create(name: "重复")
        try? store.addMember(groupID: second.id, member: .init(physicalBoardID: "DUP", displayName: "甲"))
        XCTAssertThrowsError(try store.addMember(groupID: second.id, member: .init(physicalBoardID: "DUP", displayName: "乙"))) { error in
            XCTAssertEqual(error as? BoardGroupStore.GroupError, .duplicateMember)
        }
    }
}

// MARK: - Coordinator tests

@MainActor
final class BoardGroupCoordinatorTests: XCTestCase {
    /// A `Sendable` monotonically increasing counter used as the coordinator's
    /// injected `nowUs` clock, so a scripted clock-sample exchange is fully
    /// reproducible byte-for-byte instead of depending on wall-clock timing.
    private final class Counter: @unchecked Sendable {
        private var value: Int64
        init(_ start: Int64 = 0) { value = start }
        func next() -> Int64 {
            defer { value += 1 }
            return value
        }
    }

    private func connectedSession(
        sessions: BoardSessionStore, identity: String, transport: GroupFakeTransport
    ) async -> BoardSession {
        let session = sessions.session(for: identity, name: identity)
        transport.wifiBoardId = identity
        _ = await session.connection.connect(using: transport)
        return session
    }

    /// Polls `condition` instead of a fixed sleep, so a test only waits as
    /// long as the async work it's racing actually takes.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testUnsupportedMemberBlocksPlay() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportB.caps = ["identify", "clock_sample"] // missing scroll_viewport/group_start
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "测试组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        do {
            try await coordinator.play(group: store.groups[0], text: "你好", fps: 10, loop: true)
            XCTFail("Expected unsupportedMembers to block play")
        } catch BoardGroupCoordinator.GroupPlayError.unsupportedMembers(let names) {
            XCTAssertEqual(names, ["B"])
        }
        XCTAssertFalse(coordinator.isPlaying)
    }

    func testAtUsMatchesAcrossBoardsWithIdenticalClocks() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let counter = Counter()
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions, nowUs: { counter.next() })

        let transportA = GroupFakeTransport()
        transportA.bootId = "boot0001"
        transportA.clockRxUs = 100_000
        transportA.clockTxUs = 100_200
        let transportB = GroupFakeTransport()
        transportB.bootId = "boot0002"
        transportB.clockRxUs = 100_000
        transportB.clockTxUs = 100_200
        _ = await connectedSession(sessions: sessions, identity: "ONLINE1", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "ONLINE2", transport: transportB)

        let group = store.create(name: "两块在线")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "ONLINE1", displayName: "左"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "ONLINE2", displayName: "右"))
        try store.setGap(groupID: group.id, afterSlot: 0, columns: 3)

        try await coordinator.play(group: store.groups[0], text: "A", fps: 10, loop: true)

        XCTAssertEqual(transportA.lastBlobBeginMeta?["virtualWidth"] as? Int, MatrixGeometry.cols * 2 + 3)
        XCTAssertTrue(coordinator.isPlaying)
        // Both boards saw the same (rx, tx) clock exchange shape, so their
        // computed `atUs` (phone anchor mapped through each board's own
        // offset) must be close -- not necessarily bit-identical, since the
        // two boards' 8-sample clock loops run concurrently and interleave
        // draws from the shared `nowUs` counter, giving each board slightly
        // different (m1, m4) phone-side timestamps for its best sample.
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, 1)
        let atUsA = try XCTUnwrap(transportA.sentGroupStartAtUs.last)
        let atUsB = try XCTUnwrap(transportB.sentGroupStartAtUs.last)
        XCTAssertLessThan(abs(atUsA - atUsB), 1_000, "atUs should agree within microseconds of interleave noise")
    }

    func testOfflineMemberBlocksPlay() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)

        let group = store.create(name: "含离线组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        do {
            try await coordinator.play(group: store.groups[0], text: "你好", fps: 10, loop: true)
            XCTFail("Expected offlineMembers to block play")
        } catch BoardGroupCoordinator.GroupPlayError.offlineMembers(let names) {
            XCTAssertEqual(names, ["B"])
        }
        XCTAssertFalse(coordinator.isPlaying)
    }

    func testAbortsWhenMemberGenerationChangesMidPlay() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        transportA.clockSampleReplyDelay = 0.3 // slow board, keeps its clock loop running
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "SLOW", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "FAST", transport: transportB)
        _ = sessionA

        let group = store.create(name: "掉线组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "SLOW", displayName: "慢"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "FAST", displayName: "快"))

        let playTask = Task { try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true) }
        // Give the fast board time to finish its whole clock-sample loop
        // while the slow board is still working through its 8 delayed
        // samples, then change the fast board's connection generation.
        try await Task.sleep(nanoseconds: 100_000_000)
        sessionB.connection.disconnect()

        do {
            try await playTask.value
            XCTFail("Expected play() to abort when a member's generation changed mid-flight")
        } catch BoardGroupCoordinator.GroupPlayError.aborted {
        }
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.activeGroupID)
        // The disconnect happened during clock sampling, before the
        // group_start phase is ever reached -- neither board should have
        // received one.
        XCTAssertTrue(transportA.sentGroupStartAtUs.isEmpty, "no group_start reached the still-connected board")
        XCTAssertTrue(transportB.sentGroupStartAtUs.isEmpty, "no group_start reached the aborted board")
    }

    func testStopDuringPlaySendsNoFurtherGroupStart() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "停止组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)

        await coordinator.stop(group: store.groups[0])

        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.activeGroupID)
        XCTAssertTrue(transportA.receivedStopScroll)
        XCTAssertTrue(transportB.receivedStopScroll)
        // stop() releases the lease, so the board falls back to plain
        // "connected" rather than staying stuck reporting group ownership.
        XCTAssertEqual(coordinator.status(for: store.groups[0].members[0]), .connected)
        XCTAssertNotEqual(sessionA.connection.output.source, .group)

        // No re-anchor pass can have run (the loop was cancelled), so no
        // further group_start should ever arrive.
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, 1)
    }

    func testPartialGroupStartFailureStopsTheSuccessfulBoard() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportB.cmdReplyDelay["group_start"] = 0.3 // gives the test a window to disconnect B mid-command
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "部分失败组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        let playTask = Task { try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true) }
        // Wait until both boards have uploaded (the group_start phase is
        // reached), then disconnect B while its delayed group_start reply is
        // still pending so that command throws.
        await waitUntil { transportA.lastBlobBeginMeta != nil && transportB.lastBlobBeginMeta != nil }
        try await Task.sleep(nanoseconds: 50_000_000)
        sessionB.connection.disconnect()

        do {
            try await playTask.value
            XCTFail("Expected the partial group_start failure to abort play()")
        } catch {
            // B's disconnect surfaces as either "no transport" (if the
            // disconnect lands before B's own `group_start` send) or a
            // generation-mismatch cancellation (if it lands after) --
            // assert one of those two specific shapes rather than
            // swallowing every error.
            let isExpectedShape: Bool
            if case RinaTransportError.notConnected = error {
                isExpectedShape = true
            } else if error is CancellationError {
                isExpectedShape = true
            } else {
                isExpectedShape = false
            }
            XCTAssertTrue(isExpectedShape, "unexpected error: \(error)")
        }
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.activeGroupID)
        // A did start, so the abort must have sent it a best-effort
        // stop_scroll and released its lease.
        XCTAssertTrue(transportA.receivedStopScroll)
        XCTAssertNotEqual(sessionA.connection.output.source, .group)
    }

    func testReanchorAfterSingleBoardTakeoverSkipsThatMember() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "抢占组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)

        // Some other single-board feature takes A's output lease away from
        // the group.
        sessionA.connection.output.begin(.text)
        XCTAssertFalse(coordinator.isGroupOwned(sessionA))

        await coordinator.debugReanchorNow()

        // A must not have been sent a new group_start (re-anchor never
        // steals a board back), and its lease must still belong to .text.
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)
        XCTAssertEqual(sessionA.connection.output.source, .text)
        // B is still a legitimate participant and gets re-anchored.
        XCTAssertGreaterThan(transportB.sentGroupStartAtUs.count, 1)
    }

    func testReanchorNeverSendsGroupStartToANonMember() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "旁观组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)

        // A board connects that isn't part of this group at all.
        let strayTransport = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "STRAY", transport: strayTransport)

        await coordinator.debugReanchorNow()

        XCTAssertTrue(strayTransport.sentGroupStartAtUs.isEmpty)
    }

    func testSelectDoesNotInvalidateGroupOwnedSession() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        sessions.isGroupOwned = { [weak coordinator] session in coordinator?.isGroupOwned(session) ?? false }

        let transportA = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "OWNED", transport: transportA)
        let other = sessions.session(for: "OTHER", name: "other")
        _ = await other.connection.connect(using: GroupFakeTransport())
        sessions.select(sessionA)

        let token = sessionA.connection.output.claim(.group)
        XCTAssertTrue(coordinator.isGroupOwned(sessionA))

        sessions.select(other)

        XCTAssertTrue(sessionA.connection.output.isCurrent(token), "group lease must survive a tab switch")
    }

    func testRequestReliableNotDroppedUnderBurst() async throws {
        let transport = GroupFakeTransport()
        transport.cmdReplyDelay["set_color"] = 0.3
        let connection = BoardConnection()
        _ = await connection.connect(using: transport)

        // Occupy the depth-4 drop-oldest command pump with one slow command.
        let occupier = Task { try await connection.command(.setColor(hex: "#ffffff")) }
        try await Task.sleep(nanoseconds: 20_000_000)

        var results: [Task<CommandReply, Error>] = []
        for _ in 0..<10 {
            results.append(Task { try await connection.requestReliable(.clockSample) })
        }
        for result in results {
            let reply = try await result.value
            XCTAssertEqual(reply.ok, true)
        }
        _ = try await occupier.value
    }
}

// MARK: - Fake transport

/// A `RinaTransport` fake that replies to board-group commands (`get_info`,
/// `clock_sample`, `identify`, `group_start`) and `scroll_bitmap` blob
/// uploads by inspecting the decoded `cmd`/frame type, unlike
/// `FakeRinaTransport`'s single fixed `commandReply` for every `CMD`.
@MainActor
private final class GroupFakeTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var bootId = "aaaaaaaa"
    var caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
    var wifiBoardId: String?
    var clockRxUs: Int64 = 1_000
    var clockTxUs: Int64 = 1_200
    /// Per-`cmd`-name reply delay, so a burst test can keep one slot of the
    /// command pump busy without delaying every reply.
    var cmdReplyDelay: [String: TimeInterval] = [:]
    var clockSampleReplyDelay: TimeInterval = 0
    private(set) var sentGroupStartAtUs: [Int64] = []
    private(set) var lastBlobBeginMeta: [String: Any]?
    private(set) var receivedStopScroll = false

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

    private func delay(for request: RinaLinkFrame) -> TimeInterval {
        guard request.type == RinaLinkMessageType.cmd.rawValue,
              let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
              let cmd = object["cmd"] as? String else { return 0 }
        if cmd == "clock_sample" { return clockSampleReplyDelay }
        return cmdReplyDelay[cmd] ?? 0
    }

    private func emitReply(_ request: RinaLinkFrame, payload: Data) {
        incomingContinuation?.yield(try! RinaLinkEncoder.encode(
            RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
        ))
    }

    private func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            var wifi: [String: Any] = ["ip": "192.168.4.1"]
            if let wifiBoardId { wifi["boardId"] = wifiBoardId }
            let object: [String: Any] = ["ok": true, "renderer": ["mode": "manual"], "power": [:], "wifi": wifi]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        case .getPreviewSync:
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "mode": "manual"])) ?? Data()
        case .getFrame:
            return PackedFrame().data
        case .blobBegin:
            if let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any] {
                lastBlobBeginMeta = object
            }
            return Data(#"{"ok":true,"offset":0,"chunkMax":512}"#.utf8)
        case .blobChunk:
            let offset = request.payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            let newOffset = Int(offset) + max(0, request.payload.count - 4)
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "offset": newOffset])) ?? Data()
        case .blobEnd:
            return Data(#"{"ok":true}"#.utf8)
        case .cmd:
            guard let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
                  let cmd = object["cmd"] as? String else {
                return Data(#"{"ok":true}"#.utf8)
            }
            switch cmd {
            case "get_info":
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "proto": 1, "bootId": bootId, "caps": caps])) ?? Data()
            case "clock_sample":
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "rxUs": clockRxUs, "txUs": clockTxUs, "bootId": bootId])) ?? Data()
            case "group_start":
                if let atUs = object["atUs"] as? NSNumber { sentGroupStartAtUs.append(atUs.int64Value) }
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "nowUs": 0, "frameCount": 10])) ?? Data()
            case "identify":
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "shown": true, "number": object["number"] ?? 1, "ttlMs": object["ttlMs"] ?? 5000,
                ])) ?? Data()
            case "stop_scroll":
                receivedStopScroll = true
                return Data(#"{"ok":true}"#.utf8)
            default:
                return Data(#"{"ok":true}"#.utf8)
            }
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
