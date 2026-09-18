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

    /// `BoardGroup.Member.knownBoardIDs` (GroupAutoConnector addendum) must
    /// default to `[]` decoding JSON written before the field existed,
    /// rather than failing to decode the whole group.
    func testMemberDecodesOldJSONWithoutKnownBoardIDs() throws {
        let json = """
        {"physicalBoardID":"AAAA","displayName":"A"}
        """
        let member = try JSONDecoder().decode(BoardGroup.Member.self, from: Data(json.utf8))
        XCTAssertEqual(member.physicalBoardID, "AAAA")
        XCTAssertEqual(member.displayName, "A")
        XCTAssertEqual(member.knownBoardIDs, [])
    }

    func testMemberRoundTripsKnownBoardIDs() throws {
        let member = BoardGroup.Member(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-1", "known-2"])
        let data = try JSONEncoder().encode(member)
        let decoded = try JSONDecoder().decode(BoardGroup.Member.self, from: data)
        XCTAssertEqual(decoded.knownBoardIDs, ["known-1", "known-2"])
    }

    func testRememberKnownBoardIDUpdatesMatchingMembersAcrossGroups() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        let groupA = store.create(name: "组甲")
        let groupB = store.create(name: "组乙")
        try? store.addMember(groupID: groupA.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try? store.addMember(groupID: groupB.id, member: .init(physicalBoardID: "AAAA", displayName: "A（乙组）"))
        try? store.addMember(groupID: groupB.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        store.rememberKnownBoardID("known-A", forPhysicalBoardID: "AAAA")

        XCTAssertEqual(store.groups.first { $0.id == groupA.id }?.members.first?.knownBoardIDs, ["known-A"])
        let membersB = store.groups.first { $0.id == groupB.id }?.members ?? []
        XCTAssertEqual(membersB.first { $0.physicalBoardID == "AAAA" }?.knownBoardIDs, ["known-A"])
        XCTAssertEqual(membersB.first { $0.physicalBoardID == "BBBB" }?.knownBoardIDs, [])

        // Idempotent: remembering the same id again must not duplicate it.
        store.rememberKnownBoardID("known-A", forPhysicalBoardID: "AAAA")
        XCTAssertEqual(store.groups.first { $0.id == groupA.id }?.members.first?.knownBoardIDs, ["known-A"])
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
        // Deliberately a BLE-UUID-like session key, distinct from `identity`
        // (the firmware `boardIdentity`/`physicalBoardID` a group member is
        // keyed by): a regression that resolves group members by
        // `BoardSession.boardID` instead of `BoardConnection.boardIdentity`
        // must fail tests that use this helper, not pass by both happening
        // to be the same string (F1).
        let sessionKey = "ble:\(UUID().uuidString)"
        let session = sessions.session(for: sessionKey, name: identity)
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

    /// B3: an upload failure on one member must abort the whole attempt and
    /// release every board it touched — not just the board that failed.
    func testUploadFailureOnOneBoardAbortsBothWithNoGroupStart() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportB.failBlobBegin = true
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "上传失败组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        do {
            try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
            XCTFail("Expected B's upload failure to abort play()")
        } catch {
            // The undecodable BLOB_BEGIN reply surfaces as a decoding error,
            // not one of BoardGroupCoordinator's own cases -- any throw is
            // the point here.
        }
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.activeGroupID)
        XCTAssertNil(sessionA.connection.output.source, "A's successful upload must still be released on B's failure")
        XCTAssertNil(sessionB.connection.output.source)
        XCTAssertTrue(transportA.sentGroupStartAtUs.isEmpty, "the failure happened during upload, before group_start")
        XCTAssertTrue(transportB.sentGroupStartAtUs.isEmpty)
    }

    /// B4: a second `play()` must invalidate the first run's re-anchor state
    /// so it can never send a stale `group_start` once the second run has
    /// begun. `debugReanchorNow` is fixed to use the revision/epoch frozen
    /// at play() time (B4), so this exercises the guard the fix depends on.
    func testSecondPlaySupersedesFirstRunsReanchor() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "二次播放组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "第一次", fps: 10, loop: true)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)
        let firstGroupID = try XCTUnwrap(coordinator.activeGroupID)
        let firstRevision = store.groups[0].layoutRevision
        let firstEpoch = coordinator.debugPlayEpoch

        try await coordinator.play(group: store.groups[0], text: "第二次", fps: 10, loop: true)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 2, "the second play's own group_start")

        // A re-anchor pass using the *first* run's now-stale (groupID,
        // revision, epoch) must be a no-op: play() bumped playEpoch, so
        // reanchor()'s epoch guard rejects it outright.
        await coordinator.debugReanchor(groupID: firstGroupID, revision: firstRevision, epoch: firstEpoch)

        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 2, "no group_start from the superseded first run")
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, 2, "no group_start from the superseded first run")
    }

    /// N1: only a member dropped for a generation/bootId change is
    /// auto-rejoined — the rejoin re-uploads and sends exactly one
    /// group_start, to that board only, mapped to the same phone anchor the
    /// original play() established.
    func testGenerationChangeTriggersRejoinOfThatBoardOnly() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "重连组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)
        XCTAssertNotNil(transportB.lastBlobBeginMeta, "B's original upload happened on the pre-reconnect transport")

        // B reconnects with a new transport/connection generation. Its
        // output ownership was never taken by anything else, so this is the
        // generation-changed rejoin path (N1), not the ownership-eviction
        // path -- `evictedByOwnership` must stay empty for it.
        let newTransportB = GroupFakeTransport()
        newTransportB.wifiBoardId = "B" // matches connectedSession's own setup, so boardIdentity re-resolves to "B"
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.debugReanchorNow()

        XCTAssertEqual(newTransportB.sentGroupStartAtUs.count, 1,
                       "the reconnected board is rejoined with exactly one group_start")
        XCTAssertNotNil(newTransportB.lastBlobBeginMeta, "rejoin re-uploads the bitmap to the reconnected board")
        // A stayed a live participant throughout and is unaffected by B's
        // reconnect.
        XCTAssertEqual(sessionA.connection.output.source, .group)
    }

    /// stop() only ever acts on a board it currently owns (H6/M3): a member
    /// some other single-board action already took over must be left
    /// completely alone.
    func testStopLeavesNonGroupOwnedMemberUntouched() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "旁路组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)

        // Something else takes over B's output before stop() runs.
        sessionB.connection.output.begin(.text)
        let tokenBeforeStop = sessionB.connection.output.session

        await coordinator.stop(group: store.groups[0])

        XCTAssertTrue(transportA.receivedStopScroll)
        XCTAssertFalse(transportB.receivedStopScroll, "stop() must never touch a board it no longer owns")
        XCTAssertEqual(sessionB.connection.output.source, .text)
        XCTAssertEqual(sessionB.connection.output.session, tokenBeforeStop, "B's lease token must be untouched by stop()")
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

    // MARK: - updatePlayback

    func testUpdatePlaybackSendsOneGroupStartPerParticipantWithNewIntervalAndFrame() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let counter = Counter()
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions, nowUs: { counter.next() })

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "更新播放")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "AB", fps: 10, loop: true)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, 1)

        await coordinator.updatePlayback(group: store.groups[0], fps: 20, loop: nil)

        // One additional `group_start` per participant, at the new interval.
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 2)
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, 2)
        let expectedIntervalMs = ScrollRasterizer.intervalMs(forFps: 20)
        XCTAssertEqual(transportA.sentGroupStartIntervalMs.last, expectedIntervalMs)
        XCTAssertEqual(transportB.sentGroupStartIntervalMs.last, expectedIntervalMs)
        XCTAssertTrue(coordinator.isPlaying)
    }

    func testUpdatePlaybackDoesNothingWhenNotPlaying() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        let group = store.create(name: "未播放")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        await coordinator.updatePlayback(group: store.groups[0], fps: 20, loop: true)

        XCTAssertTrue(transportA.sentGroupStartAtUs.isEmpty)
        XCTAssertFalse(coordinator.isPlaying)
    }

    // MARK: - Pause / resume / step

    /// Long enough that the group bitmap spans several frames at the
    /// stitched two-board virtual width, so step/resume assertions on
    /// `pausedFrame` aren't trivially always 0.
    private static let longScrollText = String(repeating: "你好世界，这是分步测试文字。", count: 3)

    func testPauseSendsPauseScrollThenSameFrameSeekToEveryParticipantAndStopsReanchor() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "暂停组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)

        await coordinator.pause(group: store.groups[0])

        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(transportA.receivedPauseScrollCount, 1)
        XCTAssertEqual(transportB.receivedPauseScrollCount, 1)
        XCTAssertEqual(transportA.sentScrollSeekFrames.count, 1)
        XCTAssertEqual(transportB.sentScrollSeekFrames.count, 1)
        let frameA = try XCTUnwrap(transportA.sentScrollSeekFrames.last)
        let frameB = try XCTUnwrap(transportB.sentScrollSeekFrames.last)
        XCTAssertEqual(frameA, frameB, "every participant must pause on the identical frame")
        XCTAssertEqual(coordinator.pausedFrame, frameA)

        // No further group_start can arrive once paused: the re-anchor loop
        // was stopped, not just skipped for one pass.
        let startsAfterPause = transportA.sentGroupStartAtUs.count
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, startsAfterPause)
    }

    func testResumeSendsGroupStartWithStartFrameEqualToPausedFrame() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "恢复组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPaused)
        let pausedFrame = coordinator.pausedFrame
        let groupStartsBeforeResume = transportA.sentGroupStartAtUs.count

        await coordinator.resume(group: store.groups[0])

        XCTAssertFalse(coordinator.isPaused)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, groupStartsBeforeResume + 1)
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, groupStartsBeforeResume + 1)
        XCTAssertEqual(transportA.sentGroupStartFrames.last, pausedFrame)
        XCTAssertEqual(transportB.sentGroupStartFrames.last, pausedFrame)
    }

    func testStepWhilePausedSeeksAllParticipantsToPausedFramePlusDirection() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "单步组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        let before = coordinator.pausedFrame

        await coordinator.step(group: store.groups[0], direction: 1)

        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(transportA.sentScrollSeekFrames.last, coordinator.pausedFrame)
        XCTAssertEqual(transportB.sentScrollSeekFrames.last, coordinator.pausedFrame)
        XCTAssertEqual(transportA.sentScrollSeekFrames.last, transportB.sentScrollSeekFrames.last)
        XCTAssertNotEqual(coordinator.pausedFrame, before, "the frame counter must have advanced by the given group's frame count")
    }

    func testStepWhilePlayingPausesFirstThenSeeks() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "播放中单步组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertFalse(coordinator.isPaused)

        await coordinator.step(group: store.groups[0], direction: 1)

        // step() while playing pauses first (pause_scroll sent), then seeks.
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(transportA.receivedPauseScrollCount, 1)
        XCTAssertEqual(transportB.receivedPauseScrollCount, 1)
        // One scroll_seek from pause() itself, one more from the step nudge.
        XCTAssertEqual(transportA.sentScrollSeekFrames.count, 2)
        XCTAssertEqual(transportB.sentScrollSeekFrames.count, 2)
        XCTAssertEqual(transportA.sentScrollSeekFrames.last, transportB.sentScrollSeekFrames.last)
    }

    func testStopFromPausedWorks() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "暂停后停止组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPaused)

        await coordinator.stop(group: store.groups[0])

        XCTAssertFalse(coordinator.isPaused)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.activeGroupID)
        XCTAssertTrue(transportA.receivedStopScroll)
        XCTAssertTrue(transportB.receivedStopScroll)
        XCTAssertNotEqual(sessionA.connection.output.source, .group)
    }

    /// N1, unit-level: the same `isPlaying || isPaused` combination the UI
    /// gates the stop button on (BoardGroupPlayView.isPlayingOrPaused,
    /// BoardGroupListView's row label, BoardControlCenterAccessory's
    /// subtitle) must read "active" while paused, and stop must still work
    /// from there.
    func testStopEnabledFromPausedCoordinatorState() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "停止可用组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPlaying || coordinator.isPaused, "stop must read enabled while paused")

        await coordinator.stop(group: store.groups[0])

        XCTAssertFalse(coordinator.isPlaying || coordinator.isPaused, "stop must read disabled once actually stopped")
    }

    /// B1: a re-anchor pass already mid-clock-sampling when `pause()` lands
    /// must abort before it ever sends a `group_start`, instead of racing
    /// one out after the pause.
    func testPauseDuringMidSamplingReanchorSendsNoFurtherGroupStart() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "重锚定暂停组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)
        let startsBefore = transportA.sentGroupStartAtUs.count

        // Slow the clock-sample exchange so a re-anchor pass is still in its
        // sampling loop when pause() lands.
        transportA.clockSampleReplyDelay = 0.3
        transportB.clockSampleReplyDelay = 0.3

        #if DEBUG
        let reanchorTask = Task { await coordinator.debugReanchorNow() }
        // Give the re-anchor pass time to reach its (slowed) sampling loop
        // before pausing.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await coordinator.pause(group: store.groups[0])
        await reanchorTask.value
        #endif

        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, startsBefore,
                        "no group_start must arrive from a reanchor pass that started before pause")
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, startsBefore)
    }

    /// B2: `updatePlayback` while paused must only remember the new
    /// interval/loop — never send anything on the wire.
    func testUpdatePlaybackWhilePausedSendsNothing() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "暂停中更新组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPaused)
        let startsBeforeUpdate = transportA.sentGroupStartAtUs.count

        await coordinator.updatePlayback(group: store.groups[0], fps: 20, loop: nil)

        XCTAssertEqual(transportA.sentGroupStartAtUs.count, startsBeforeUpdate)
        XCTAssertEqual(transportB.sentGroupStartAtUs.count, startsBeforeUpdate)
        XCTAssertTrue(coordinator.isPaused, "updatePlayback must not itself resume playback")
    }

    /// N5: two pause taps racing each other (e.g. a fast double-tap) must
    /// still land every participant on one identical frame — the second
    /// tap is ignored outright, not sent as a second, possibly different, n.
    func testOverlappingPauseTapsSendASingleConsistentFrame() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "并发暂停组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)

        async let firstTap: Void = coordinator.pause(group: store.groups[0])
        async let secondTap: Void = coordinator.pause(group: store.groups[0])
        _ = await (firstTap, secondTap)

        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(transportA.receivedPauseScrollCount, 1, "the overlapping tap must be ignored, not sent twice")
        XCTAssertEqual(transportB.receivedPauseScrollCount, 1)
        XCTAssertEqual(transportA.sentScrollSeekFrames.count, 1)
        XCTAssertEqual(transportB.sentScrollSeekFrames.count, 1)
        let frameA = try XCTUnwrap(transportA.sentScrollSeekFrames.last)
        let frameB = try XCTUnwrap(transportB.sentScrollSeekFrames.last)
        XCTAssertEqual(frameA, frameB, "every participant must still pause on the identical frame")
        XCTAssertEqual(coordinator.pausedFrame, frameA)
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
    /// B3: makes `BLOB_BEGIN` reply with undecodable JSON, so
    /// `uploadGroupScrollBitmap` throws for this board's upload without
    /// needing a timeout.
    var failBlobBegin = false
    private(set) var sentGroupStartAtUs: [Int64] = []
    private(set) var sentGroupStartIntervalMs: [Int] = []
    private(set) var sentGroupStartFrames: [Int] = []
    private(set) var lastBlobBeginMeta: [String: Any]?
    private(set) var receivedStopScroll = false
    /// One entry per `pause_scroll` this board received.
    private(set) var receivedPauseScrollCount = 0
    /// One entry per `scroll_seek{frameIndex}` this board received, in order.
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
            if failBlobBegin { return Data("not json".utf8) }
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
                if let intervalMs = object["intervalMs"] as? NSNumber { sentGroupStartIntervalMs.append(intervalMs.intValue) }
                sentGroupStartFrames.append(object["startFrame"] as? Int ?? 0)
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "nowUs": 0, "frameCount": 10])) ?? Data()
            case "identify":
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "shown": true, "number": object["number"] ?? 1, "ttlMs": object["ttlMs"] ?? 5000,
                ])) ?? Data()
            case "stop_scroll":
                receivedStopScroll = true
                return Data(#"{"ok":true}"#.utf8)
            case "pause_scroll":
                receivedPauseScrollCount += 1
                return Data(#"{"ok":true}"#.utf8)
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
