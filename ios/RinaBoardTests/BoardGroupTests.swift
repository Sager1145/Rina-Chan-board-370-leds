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
        /// Reads the current value without advancing it -- used to snapshot
        /// "now" as a lower bound before an operation that will itself call
        /// `next()` many more times.
        func peek() -> Int64 { value }
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

    // MARK: - 4.1 firmware intervalMs floor

    /// 4.1: firmware `group_start` rejects `intervalMs < 20`. `play()` must
    /// clamp any fps above `RinaLinkConstants.groupScrollFpsMaxLegacy` (50) down to
    /// the 20 ms floor instead of passing `ScrollRasterizer.intervalMs(forFps:)`
    /// straight through.
    func testPlayAt60FpsClampsIntervalMsToFirmwareMinimum() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "六十帧组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "快", fps: 60, loop: true)

        XCTAssertEqual(transportA.sentGroupStartIntervalMs.last, RinaLinkConstants.groupStartIntervalMsMinLegacy)
        XCTAssertEqual(transportB.sentGroupStartIntervalMs.last, RinaLinkConstants.groupStartIntervalMsMinLegacy)
    }

    /// Same floor, via `updatePlayback` (the live fps-change path).
    func testUpdatePlaybackAt60FpsClampsIntervalMsToFirmwareMinimum() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "更新六十帧组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "AB", fps: 10, loop: true)

        await coordinator.updatePlayback(group: store.groups[0], fps: 60, loop: nil)

        XCTAssertEqual(transportA.sentGroupStartIntervalMs.last, RinaLinkConstants.groupStartIntervalMsMinLegacy)
        XCTAssertEqual(transportB.sentGroupStartIntervalMs.last, RinaLinkConstants.groupStartIntervalMsMinLegacy)
    }

    /// `group_60fps` firmware accepts 17 ms, so a group whose every member
    /// advertises it plays and updates at a real 60 fps.
    func testGroup60FpsCapableBoardsGet17Ms() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportA.caps.append("group_60fps")
        transportB.caps.append("group_60fps")
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "真六十帧组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))
        XCTAssertEqual(coordinator.maxFps(for: store.groups[0]), 60)

        try await coordinator.play(group: store.groups[0], text: "快", fps: 60, loop: true)
        XCTAssertEqual(transportA.sentGroupStartIntervalMs.last, 17)
        XCTAssertEqual(transportB.sentGroupStartIntervalMs.last, 17)

        await coordinator.updatePlayback(group: store.groups[0], fps: 30, loop: nil)
        await coordinator.updatePlayback(group: store.groups[0], fps: 60, loop: nil)
        XCTAssertEqual(transportA.sentGroupStartIntervalMs.last, 17)
        XCTAssertEqual(transportB.sentGroupStartIntervalMs.last, 17)
    }

    /// One legacy member holds the whole group to the 20 ms / 50 fps floor.
    func testGroupWithOneLegacyBoardStaysAt20Ms() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportA.caps.append("group_60fps")
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "混合固件组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))
        XCTAssertEqual(coordinator.maxFps(for: store.groups[0]), 50)

        try await coordinator.play(group: store.groups[0], text: "快", fps: 60, loop: true)
        XCTAssertEqual(transportA.sentGroupStartIntervalMs.last, 20)
        XCTAssertEqual(transportB.sentGroupStartIntervalMs.last, 20)
    }

    /// Starting group two stops group one's boards that group two doesn't
    /// Reconnect/relaunch bug: a fresh coordinator (app relaunched) takes a
    /// group scroll the boards are still playing back — no re-upload, the
    /// boards re-anchored in step from where they are — so pause/step/speed
    /// work again.
    func testFreshCoordinatorAdoptsStillRunningGroupScroll() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let first = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "接管组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await first.play(group: store.groups[0], text: "接管", fps: 10, loop: true)
        let frameCount = try XCTUnwrap(first.playbackSnapshot?.frameCount)
        let timelineId = try XCTUnwrap(transportA.lastBlobBeginMeta?["timelineId"] as? String)

        for transport in [transportA, transportB] {
            transport.scrollMeta = [
                "ok": true, "scrollTimelineId": timelineId, "hasSourceText": true, "sourceText": "接管",
                "frameCount": frameCount, "frameIndex": 5, "scrollIntervalMs": 100,
                "firmwareScrollActive": true, "firmwareScrollPaused": false, "scrollLoop": true, "groupTimed": true,
            ]
        }
        let uploadsBefore = transportA.blobBeginCount
        let relaunched = BoardGroupCoordinator(store: store, sessions: sessions)

        let adopted = await relaunched.adoptRunningScroll(group: store.groups[0])

        XCTAssertTrue(adopted)
        XCTAssertTrue(relaunched.isPlaying)
        XCTAssertEqual(relaunched.activeGroupID, group.id)
        XCTAssertEqual(transportA.blobBeginCount, uploadsBefore, "adoption must not re-upload")
        XCTAssertGreaterThanOrEqual(transportA.sentGroupStartFrames.last ?? -1, 5)
        XCTAssertEqual(transportA.sentGroupStartFrames.last, transportB.sentGroupStartFrames.last)

        await relaunched.pause(group: store.groups[0])
        XCTAssertTrue(relaunched.isPaused, "controls work again after adoption")
    }

    /// Boards that don't agree (different text) are not adopted, and nothing
    /// is sent to them.
    func testAdoptionRefusedWhenBoardsDisagree() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "不一致组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        let base: [String: Any] = [
            "ok": true, "scrollTimelineId": "T", "hasSourceText": true, "frameCount": 50, "frameIndex": 0,
            "scrollIntervalMs": 100, "firmwareScrollActive": true, "scrollLoop": true, "groupTimed": true,
        ]
        transportA.scrollMeta = base.merging(["sourceText": "甲"]) { _, new in new }
        transportB.scrollMeta = base.merging(["sourceText": "乙"]) { _, new in new }

        let adopted = await coordinator.adoptRunningScroll(group: store.groups[0])

        XCTAssertFalse(adopted)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertTrue(transportA.sentGroupStartAtUs.isEmpty)
    }

    /// `.task(id:)` cancels its child task on every id change, and
    /// `adoptRunningScroll` itself flips `isStarting` (a naive id would
    /// include it), so a naive caller cancels its own in-flight adoption and
    /// restarts forever without ever completing (BOARD_GROUP_SPEC.md §3).
    /// `adoptRunningScrollIfNeeded` must run the real attempt on an
    /// unstructured `Task` that does not inherit the caller's cancellation,
    /// so cancelling the awaiting task must not stop the adoption underneath.
    func testAdoptionCompletesWhenCallerIsCancelled() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let first = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "取消接管组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await first.play(group: store.groups[0], text: "取消", fps: 10, loop: true)
        let frameCount = try XCTUnwrap(first.playbackSnapshot?.frameCount)
        let timelineId = try XCTUnwrap(transportA.lastBlobBeginMeta?["timelineId"] as? String)
        for transport in [transportA, transportB] {
            transport.scrollMeta = [
                "ok": true, "scrollTimelineId": timelineId, "hasSourceText": true, "sourceText": "取消",
                "frameCount": frameCount, "frameIndex": 5, "scrollIntervalMs": 100,
                "firmwareScrollActive": true, "firmwareScrollPaused": false, "scrollLoop": true, "groupTimed": true,
            ]
        }
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        // Baseline includes `first.play()`'s own `group_start` on each
        // transport (they're the same boards) — the assertion below checks
        // adoption sent exactly one MORE, not the lifetime total.
        let sentBeforeA = transportA.sentGroupStartAtUs.count
        let sentBeforeB = transportB.sentGroupStartAtUs.count

        let t = Task { await coordinator.adoptRunningScrollIfNeeded(group: store.groups[0]) }
        t.cancel()
        let adopted = await t.value

        XCTAssertTrue(adopted)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertFalse(coordinator.isStarting)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count - sentBeforeA, 1)
        XCTAssertEqual(transportB.sentGroupStartAtUs.count - sentBeforeB, 1)
    }

    /// A failed adoption must not be retried immediately: a second call for
    /// the same group within the 5 s throttle window must produce no
    /// additional BLE traffic, so a caller stuck re-requesting adoption can't
    /// hammer disagreeing boards with `GET_SCROLL_META` on every restart.
    func testFailedAdoptionIsNotRetriedImmediately() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "重试节流组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        let base: [String: Any] = [
            "ok": true, "scrollTimelineId": "T", "hasSourceText": true, "frameCount": 50, "frameIndex": 0,
            "scrollIntervalMs": 100, "firmwareScrollActive": true, "scrollLoop": true, "groupTimed": true,
        ]
        transportA.scrollMeta = base.merging(["sourceText": "甲"]) { _, new in new }
        transportB.scrollMeta = base.merging(["sourceText": "乙"]) { _, new in new }

        let first = await coordinator.adoptRunningScrollIfNeeded(group: store.groups[0])
        let requestsAfterFirst = transportA.scrollMetaRequestCount
        let second = await coordinator.adoptRunningScrollIfNeeded(group: store.groups[0])

        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(transportA.scrollMetaRequestCount, requestsAfterFirst, "throttled retry must send no BLE traffic")
    }

    /// Reconnect/relaunch bug: Stop must reach boards still scrolling whose
    /// output lease the reconnect cleared (`source == nil`), not skip them.
    func testStopReachesStillScrollingBoardsAfterRelaunch() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportA.statusRenderer = ["firmwareScrollActive": true, "scrollFrameCount": 40]
        transportB.statusRenderer = ["firmwareScrollActive": true, "scrollFrameCount": 40]
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "孤儿组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        await waitUntil { sessionA.connection.status?.renderer?.firmwareScrollActive == true }
        XCTAssertTrue(coordinator.hasOrphanedScroll(group: store.groups[0]))

        await coordinator.stop(group: store.groups[0])

        XCTAssertTrue(transportA.receivedStopScroll)
        XCTAssertTrue(transportB.receivedStopScroll)
    }

    /// Paused group, one member drops and reconnects: resume must bring it
    /// back (re-upload + group_start) instead of silently skipping it.
    func testResumeAfterMemberReconnectedWhilePausedIncludesIt() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "暂停重连组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await coordinator.play(group: store.groups[0], text: "暂停重连", fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPaused)
        let pausedAt = coordinator.pausedFrame

        let newTransportB = GroupFakeTransport()
        newTransportB.wifiBoardId = "B"
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.resume(group: store.groups[0])

        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertNotNil(newTransportB.lastBlobBeginMeta, "the reconnected board gets the timeline again")
        XCTAssertEqual(newTransportB.sentGroupStartFrames.last, pausedAt)
        XCTAssertEqual(transportA.sentGroupStartFrames.last, pausedAt)
    }

    /// Same gap for step: the reconnected board is brought back and the
    /// group ends paused on the stepped frame.
    func testStepAfterMemberReconnectedWhilePausedIncludesIt() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "逐帧重连组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try await coordinator.play(group: store.groups[0], text: "逐帧重连", fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        let target = coordinator.pausedFrame + 1

        let newTransportB = GroupFakeTransport()
        newTransportB.wifiBoardId = "B"
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.step(group: store.groups[0], direction: 1)

        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(coordinator.pausedFrame, target)
        XCTAssertNotNil(newTransportB.lastBlobBeginMeta)
        XCTAssertEqual(newTransportB.sentScrollSeekFrames.last, target)
    }

    /// Drag-swap on an idle group only reorders.
    func testSwapMembersOnIdleGroupJustReorders() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let group = store.create(name: "换序组")
        for id in ["A", "B", "C"] {
            try store.addMember(groupID: group.id, member: .init(physicalBoardID: id, displayName: id))
        }
        try await coordinator.swapMembers(group: store.groups[0], "A", "C")
        XCTAssertEqual(store.groups[0].members.map(\.physicalBoardID), ["C", "B", "A"])
        XCTAssertFalse(coordinator.isPlaying)
    }

    /// Drag-swap while playing restarts with the new layout: each board's
    /// fresh upload carries its new slot's viewport.
    func testSwapMembersWhilePlayingReplaysWithNewViewports() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let group = store.create(name: "播放换序组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "AB", fps: 10, loop: true)
        XCTAssertEqual(transportA.lastBlobBeginMeta?["viewportX"] as? Int, 0)
        let startsBefore = transportA.sentGroupStartAtUs.count

        try await coordinator.swapMembers(group: store.groups[0], "A", "B")

        XCTAssertEqual(store.groups[0].members.map(\.physicalBoardID), ["B", "A"])
        XCTAssertEqual(transportA.lastBlobBeginMeta?["viewportX"] as? Int, MatrixGeometry.cols)
        XCTAssertEqual(transportB.lastBlobBeginMeta?["viewportX"] as? Int, 0)
        XCTAssertGreaterThan(transportA.sentGroupStartAtUs.count, startsBefore)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(coordinator.playbackSnapshot?.memberOrder.map(\.physicalBoardID), ["B", "A"])
    }

    /// Reviewer blocker: a swap that can't be replayed (a member offline)
    /// must fail loudly and leave the group — order and revision — exactly
    /// as it was, so the running playback keeps its controls.
    func testSwapMembersWithOfflineMemberFailsAndKeepsPlaybackControllable() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let transportC = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let sessionC = await connectedSession(sessions: sessions, identity: "C", transport: transportC)
        let group = store.create(name: "离线换序组")
        for id in ["A", "B", "C"] {
            try store.addMember(groupID: group.id, member: .init(physicalBoardID: id, displayName: id))
        }
        try await coordinator.play(group: store.groups[0], text: "ABC", fps: 10, loop: true)
        let revisionBefore = store.groups[0].layoutRevision

        sessionC.connection.disconnect()
        await waitUntil { sessionC.connection.connectionState != .connected }

        do {
            try await coordinator.swapMembers(group: store.groups[0], "A", "B")
            XCTFail("swap must fail while a member is offline")
        } catch let error as BoardGroupCoordinator.GroupPlayError {
            XCTAssertEqual(error, .offlineMembers(["C"]))
        }
        XCTAssertEqual(store.groups[0].members.map(\.physicalBoardID), ["A", "B", "C"])
        XCTAssertEqual(store.groups[0].layoutRevision, revisionBefore)

        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPaused, "pause must still work after the refused swap")
        XCTAssertEqual(transportA.sentScrollSeekFrames.count, 1)
    }

    /// use, and leaves the shared board to group two.
    func testPlayingAnotherGroupStopsThePreviousGroupsOtherBoards() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let transportC = GroupFakeTransport()
        let transportD = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let sessionC = await connectedSession(sessions: sessions, identity: "C", transport: transportC)
        let sessionD = await connectedSession(sessions: sessions, identity: "D", transport: transportD)

        let group1 = store.create(name: "组一")
        for id in ["A", "B", "C"] {
            try store.addMember(groupID: group1.id, member: .init(physicalBoardID: id, displayName: id))
        }
        let group2 = store.create(name: "组二")
        for id in ["A", "D"] {
            try store.addMember(groupID: group2.id, member: .init(physicalBoardID: id, displayName: id))
        }

        try await coordinator.play(group: store.groups.first { $0.id == group1.id }!, text: "组一", fps: 10, loop: true)
        try await coordinator.play(group: store.groups.first { $0.id == group2.id }!, text: "组二", fps: 10, loop: true)
        // The cleanup runs beside the new upload; give it a moment to land.
        for _ in 0..<50 where !(transportB.receivedStopScroll && transportC.receivedStopScroll) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(transportB.receivedStopScroll)
        XCTAssertTrue(transportC.receivedStopScroll)
        XCTAssertNotEqual(sessionB.connection.output.source, .group)
        XCTAssertNotEqual(sessionC.connection.output.source, .group)
        XCTAssertFalse(transportA.receivedStopScroll, "A moved to group two and must not be stopped")
        XCTAssertFalse(transportD.receivedStopScroll)
        XCTAssertEqual(sessionA.connection.output.source, .group)
        XCTAssertEqual(sessionD.connection.output.source, .group)
        XCTAssertEqual(coordinator.activeGroupID, group2.id)
        XCTAssertTrue(coordinator.isPlaying)
    }

    /// 4.1 hardening: if every participant's `group_start` reply comes back
    /// rejected, `updatePlayback` must leave the anchor (and so the interval
    /// the next re-anchor/rejoin pass computes against) exactly as it was.
    func testUpdatePlaybackRejectedByAllBoardsLeavesAnchorUnchanged() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "全拒绝组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "AB", fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)
        #if DEBUG
        XCTAssertEqual(coordinator.debugAnchorIntervalMs, ScrollRasterizer.intervalMs(forFps: 10))
        #endif

        transportA.rejectGroupStart = true
        transportB.rejectGroupStart = true

        await coordinator.updatePlayback(group: store.groups[0], fps: 20, loop: nil)

        XCTAssertTrue(coordinator.isPlaying, "a fully-rejected update must not disturb isPlaying")
        #if DEBUG
        XCTAssertEqual(coordinator.debugAnchorIntervalMs, ScrollRasterizer.intervalMs(forFps: 10),
                        "the anchor must still reflect the original play-time interval, not the rejected 20fps one")
        #endif
    }

    // MARK: - 4.2 no re-claim inside play()

    /// 4.2: `play()` must never re-claim `.group` on a board after its
    /// per-board token is captured up front -- a single-board action that
    /// claims a different output source on one of the group's boards between
    /// the upload phase and the clock-sync phase must abort the whole
    /// attempt, not have its claim silently paved over by `play()`'s own
    /// stale re-claim.
    func testManualClaimBetweenUploadAndClockSamplingAbortsPlay() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        // Slow the clock-sample exchange (not the upload) so there's a real
        // window between "both uploads landed" and "group_start about to
        // send" for the test to steal A's lease in.
        transportA.clockSampleReplyDelay = 0.05
        transportB.clockSampleReplyDelay = 0.05
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "抢占中断组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        let playTask = Task { try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true) }
        // Wait for both boards' uploads to reach BEGIN (and settle), then
        // steal A's output lease before the (slowed) clock-sample phase
        // finishes.
        await waitUntil { transportA.lastBlobBeginMeta != nil && transportB.lastBlobBeginMeta != nil }
        try await Task.sleep(nanoseconds: 50_000_000)
        sessionA.connection.output.claim(.manual)

        do {
            try await playTask.value
            XCTFail("Expected the manual claim to abort play()")
        } catch BoardGroupCoordinator.GroupPlayError.aborted {
        }

        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertTrue(transportA.sentGroupStartAtUs.isEmpty, "the takeover must be caught before any group_start is sent")
        XCTAssertTrue(transportB.sentGroupStartAtUs.isEmpty)
        XCTAssertEqual(sessionA.connection.output.source, .manual, "the manual claim must not be paved over by a play() re-claim")
    }

    // MARK: - 4.3 stop() vs a concurrent play()

    /// 4.3: an unwaited `stop()` still mid-flight (its `stop_scroll` reply
    /// pending) must not clobber a `play()` for the *same* group started
    /// while it's in flight -- `stop()`'s per-member epoch guard must catch
    /// this and leave the new play alone.
    func testUnwaitedStopFollowedByPlaySucceeds() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportA.cmdReplyDelay["stop_scroll"] = 0.3
        transportB.cmdReplyDelay["stop_scroll"] = 0.3
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "并发停止组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "第一次", fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)

        let stopTask = Task { await coordinator.stop(group: store.groups[0]) }
        // Give stop() time to claim its lease and send the (slow) stop_scroll.
        try await Task.sleep(nanoseconds: 20_000_000)

        try await coordinator.play(group: store.groups[0], text: "第二次", fps: 10, loop: true)
        await stopTask.value

        XCTAssertTrue(coordinator.isPlaying, "the second play must win over the stale, still-in-flight stop()")
        XCTAssertEqual(sessionA.connection.output.source, .group)
    }

    // MARK: - 4.4 preflight before state wipe

    /// 4.4: a failed second `play()` (text too wide for the wire limit) must
    /// leave the first, still-running play completely untouched -- the
    /// preflight (including `GroupScrollBitmap.build`) now runs before any of
    /// this coordinator's state is wiped.
    func testFailedSecondPlayWithTooWideTextLeavesFirstPlayRunning() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "过宽文字组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "第一次", fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)
        let startsBefore = transportA.sentGroupStartAtUs.count

        let tooWideText = String(repeating: "宽", count: 1000) // far past GroupScrollBitmap.maxWidth (3093px)
        do {
            try await coordinator.play(group: store.groups[0], text: tooWideText, fps: 10, loop: true)
            XCTFail("Expected buildFailed for text exceeding the wire width limit")
        } catch BoardGroupCoordinator.GroupPlayError.buildFailed {
        }

        XCTAssertTrue(coordinator.isPlaying, "the first play must still be running after the failed second attempt")
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, startsBefore, "no group_start from the failed second play")

        await coordinator.stop(group: store.groups[0])
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertTrue(transportA.receivedStopScroll)
    }

    // MARK: - 4.7 updatePlayback switch-time ordering

    /// 4.7: `updatePlayback` must pick its switch time `T` *after* this
    /// pass's own clock sampling, not before it -- picking `T` up front (the
    /// pre-fix order, 9c12a20) means the sampling that follows can eat well
    /// past `T`, so the boards see a schedule already in their past.
    ///
    /// The original version of this test pinned each board's clock reply
    /// (`rxUs`/`txUs`) to a *fixed* baseline constant and compared the
    /// resulting `atUs` (phone uptime, dominated by that same huge absolute
    /// uptime constant, on the order of 1e11us on a machine that's been up
    /// for days) against a small elapsed-time value -- so the assertion held
    /// unconditionally regardless of ordering and the test passed on 9c12a20
    /// too. Instead, `GroupFakeTransport.clockUsesRealTime` makes each
    /// board's clock reply track real `DispatchTime.now()` at the moment the
    /// (possibly delayed) reply is generated, so the estimated clock offset
    /// against the coordinator's own real `nowUs()` is ~0 and `atUs` is
    /// directly comparable to real elapsed wall time.
    func testUpdatePlaybackPicksSwitchTimeAfterItsOwnSampling() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportA.clockUsesRealTime = true
        transportB.clockUsesRealTime = true
        _ = await connectedSession(sessions: sessions, identity: "AAAA", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "BBBB", transport: transportB)

        let group = store.create(name: "延迟采样组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B"))

        let baselineUs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000)
        try await coordinator.play(group: store.groups[0], text: "AB", fps: 10, loop: true)
        XCTAssertEqual(transportA.sentGroupStartAtUs.count, 1)

        // Slow only this pass's own clock sampling (4 sequential samples per
        // board, boards run in parallel) by a known real amount -- not the
        // initial play() above, whose own group_start already went out.
        // 150ms * 4 samples = ~600ms of real wall time per board, well past
        // the 300ms switch-time margin.
        transportA.clockSampleReplyDelay = 0.15
        transportB.clockSampleReplyDelay = 0.15

        let beforeUpdateUs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000) - baselineUs

        await coordinator.updatePlayback(group: store.groups[0], fps: 20, loop: nil)

        let atUsA = try XCTUnwrap(transportA.sentGroupStartAtUs.last) - baselineUs
        // Reasoning about 9c12a20's ordering (pick T, *then* sample): T would
        // be `nowUs() + max(300_000, 3 * worstRtt)` using the *stale*
        // estimator from the initial (undelayed) play() -- worstRtt ~= 0 --
        // so `atUs` would land around `beforeUpdateUs + 300_000`us, well
        // under `beforeUpdateUs + 500_000`. This fix's order (sample, *then*
        // pick T) makes `nowUs()` itself only run after ~600ms of real
        // sampling delay has already elapsed, so `atUs` lands well past it.
        XCTAssertGreaterThan(atUsA, beforeUpdateUs + 500_000,
                              "switch time must be chosen after this pass's own clock sampling, not before it")
    }

    // MARK: - Cross-group stop / overlapping play / resume rejection (reviewer fixes)

    /// Reviewer fix: a `stop()` for G1={A,B,C} whose `stop_scroll` reply from
    /// A is still in flight when G2={A,D} starts (reusing A) must not
    /// abandon B and C -- `stop()`'s epoch guard used to `return` out of its
    /// *whole* loop the instant the epoch moved on (9c12a20 and this branch
    /// before the `claimedBoardIDs` fix), silently leaving B and C
    /// `.group`-owned forever with no `stop_scroll` ever sent and no control
    /// able to reach them. B and C are never claimed by G2, so they must
    /// still be stopped and released; only A -- which G2 legitimately
    /// claimed (and which reuses A's *same* lease token, since `claim(.group)`
    /// on a board whose source is already `.group` returns the current
    /// token) -- must be left alone by the stale `stop()`.
    func testCrossGroupStopLeavesUnclaimedSiblingsStopped() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let transportC = GroupFakeTransport()
        let transportD = GroupFakeTransport()
        transportA.cmdReplyDelay["stop_scroll"] = 0.3
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        let sessionC = await connectedSession(sessions: sessions, identity: "C", transport: transportC)
        _ = await connectedSession(sessions: sessions, identity: "D", transport: transportD)

        let group1 = store.create(name: "组一")
        try store.addMember(groupID: group1.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group1.id, member: .init(physicalBoardID: "B", displayName: "B"))
        try store.addMember(groupID: group1.id, member: .init(physicalBoardID: "C", displayName: "C"))
        let group2 = store.create(name: "组二")
        try store.addMember(groupID: group2.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group2.id, member: .init(physicalBoardID: "D", displayName: "D"))

        try await coordinator.play(group: store.groups.first { $0.id == group1.id }!, text: "组一", fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)

        let stopTask = Task { await coordinator.stop(group: store.groups.first { $0.id == group1.id }!) }
        // Give stop() time to reach A (the first member) and start its slow stop_scroll.
        try await Task.sleep(nanoseconds: 20_000_000)

        try await coordinator.play(group: store.groups.first { $0.id == group2.id }!, text: "组二", fps: 10, loop: true)
        await stopTask.value

        XCTAssertTrue(transportB.receivedStopScroll, "B must still be stopped despite the cross-group race")
        XCTAssertTrue(transportC.receivedStopScroll, "C must still be stopped despite the cross-group race")
        XCTAssertNotEqual(sessionB.connection.output.source, .group)
        XCTAssertNotEqual(sessionC.connection.output.source, .group)

        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(coordinator.activeGroupID, group2.id, "G2 must have taken over and be playing")
        XCTAssertEqual(sessionA.connection.output.source, .group, "A must remain G2's, never invalidated by the stale stop()")
    }

    /// Reviewer fix: a stale `play()`'s `catch` block must only clear
    /// `isStarting`/`startingGroupID` under its *own* epoch. Pre-fix, it
    /// cleared them unconditionally -- so a first play (aborted here by a
    /// manual claim stealing one of its boards) finishing its failure
    /// handling *after* a second, unrelated play (disjoint boards, a
    /// different group) has already begun its own `isStarting` phase would
    /// wipe out the second play's still-in-flight upload spinner state.
    func testStalePlayAbortDoesNotClearNewerPlaysIsStarting() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportA.clockSampleReplyDelay = 0.05
        transportB.clockSampleReplyDelay = 0.05
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let transportC = GroupFakeTransport()
        let transportD = GroupFakeTransport()
        transportC.clockSampleReplyDelay = 0.1
        transportD.clockSampleReplyDelay = 0.1
        _ = await connectedSession(sessions: sessions, identity: "C", transport: transportC)
        _ = await connectedSession(sessions: sessions, identity: "D", transport: transportD)

        let group1 = store.create(name: "第一组")
        try store.addMember(groupID: group1.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group1.id, member: .init(physicalBoardID: "B", displayName: "B"))
        let group2 = store.create(name: "第二组")
        try store.addMember(groupID: group2.id, member: .init(physicalBoardID: "C", displayName: "C"))
        try store.addMember(groupID: group2.id, member: .init(physicalBoardID: "D", displayName: "D"))

        let playTask1 = Task {
            try await coordinator.play(group: store.groups.first { $0.id == group1.id }!, text: "第一次", fps: 10, loop: true)
        }
        await waitUntil { transportA.lastBlobBeginMeta != nil && transportB.lastBlobBeginMeta != nil }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Forces play1 to abort at its next `stillValid()` check (after its
        // own clock-sampling phase finishes), the same technique
        // `testManualClaimBetweenUploadAndClockSamplingAbortsPlay` uses.
        sessionA.connection.output.claim(.manual)

        let playTask2 = Task {
            try await coordinator.play(group: store.groups.first { $0.id == group2.id }!, text: "第二次", fps: 10, loop: true)
        }
        // Wait until play2 has become the coordinator's active isStarting
        // attempt (and so has already bumped `playEpoch` past play1's own)
        // before letting play1's abort run.
        await waitUntil { coordinator.startingGroupID == group2.id }

        do {
            try await playTask1.value
            XCTFail("Expected the manual claim to abort play1")
        } catch BoardGroupCoordinator.GroupPlayError.aborted {
        }

        // play1's own stale abort must not have cleared play2's
        // still-in-flight isStarting/startingGroupID.
        XCTAssertTrue(coordinator.isStarting)
        XCTAssertEqual(coordinator.startingGroupID, group2.id)

        try await playTask2.value
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(coordinator.activeGroupID, group2.id)
        XCTAssertFalse(coordinator.isStarting)
    }

    /// Reviewer fix: `resumeCore` must treat a rejected `group_start` reply
    /// (every participant rejects) exactly like `updatePlayback` already
    /// does -- staying paused rather than flipping to playing when nothing
    /// on the wire actually accepted the new anchor. 9c12a20 never checked
    /// `reply.ok` here at all.
    func testResumeStaysPausedWhenEveryBoardRejectsGroupStart() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "拒绝恢复组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: Self.longScrollText, fps: 10, loop: true)
        await coordinator.pause(group: store.groups[0])
        XCTAssertTrue(coordinator.isPaused)
        let pausedFrame = coordinator.pausedFrame

        transportA.rejectGroupStart = true
        transportB.rejectGroupStart = true

        await coordinator.resume(group: store.groups[0])

        XCTAssertTrue(coordinator.isPaused, "every board rejecting group_start must leave the group paused")
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(coordinator.pausedFrame, pausedFrame, "pausedFrame must be untouched by the rejected resume")
    }

    // MARK: - Deletion / cleanup

    /// Covers the `BoardGroupListView` "delete-while-playing" fix: stopping a
    /// group before removing it from the store must actually release every
    /// member's output lease, not just clear the coordinator's own state --
    /// a board still claiming `.group` after the group it belonged to is
    /// gone would be stuck unable to accept any other single-board action.
    func testStopThenRemoveFromStoreReleasesEveryBoard() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "删除组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(sessionA.connection.output.source, .group)
        XCTAssertEqual(sessionB.connection.output.source, .group)

        let groupToDelete = store.groups[0]
        await coordinator.stop(group: groupToDelete)
        store.remove(id: groupToDelete.id)

        XCTAssertTrue(transportA.receivedStopScroll)
        XCTAssertTrue(transportB.receivedStopScroll)
        XCTAssertNotEqual(sessionA.connection.output.source, .group)
        XCTAssertNotEqual(sessionB.connection.output.source, .group)
        XCTAssertTrue(store.groups.isEmpty)
    }

    // MARK: - R6b/R6a/R6e/F4/F11 (group timeline rejoin)

    /// R6b: a member whose upload content the coordinator already recorded
    /// AND whose live `GET_SCROLL_META` still agrees is rejoined with no
    /// bitmap re-upload — only clock samples + one `group_start`.
    func testRejoinSkipsUploadWhenBoardStillHoldsTheContent() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        _ = sessionA

        let group = store.create(name: "跳过上传组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
        let timelineId = try XCTUnwrap(coordinator.debugTimelineId)
        let frameCount = try XCTUnwrap(coordinator.playbackSnapshot?.frameCount)
        XCTAssertEqual(transportB.blobBeginCount, 1, "original play uploaded once")

        // B reconnects with a new connection generation but the SAME boot
        // (default bootId), and its firmware still reports it holding the
        // exact content this coordinator uploaded.
        let newTransportB = GroupFakeTransport()
        newTransportB.wifiBoardId = "B"
        newTransportB.scrollMeta = [
            "ok": true, "groupTimed": true, "firmwareScrollActive": true, "uploadComplete": true,
            "scrollTimelineId": timelineId, "frameCount": frameCount,
        ]
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.debugRejoinReconnectedNow()

        XCTAssertEqual(newTransportB.scrollMetaRequestCount, 1, "the meta must be checked before deciding to skip")
        XCTAssertEqual(newTransportB.blobBeginCount, 0, "matching content must never be re-uploaded")
        XCTAssertEqual(newTransportB.sentGroupStartAtUs.count, 1, "the board is still rejoined with a group_start")
        XCTAssertEqual(sessionB.connection.output.source, .group)
    }

    /// F11: a board whose clock reads a small uptime (just rebooted) while
    /// the group's own anchor is from long before must still receive a
    /// non-negative `atUs` — `rolledForward` keeps the rejoin's sent anchor
    /// inside the board's own uptime without ever touching `currentAnchor`.
    func testRejoinOfRebootedBoardSendsNonNegativeAtUs() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let counter = Counter()
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions, nowUs: { counter.next() })

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        transportA.clockRxUs = 1_000
        transportA.clockTxUs = 1_200
        transportB.clockRxUs = 1_000
        transportB.clockTxUs = 1_200
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        _ = sessionA

        let group = store.create(name: "重启组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)

        // Fast-forward the phone's own clock far past the anchor's small
        // `phoneUs`, simulating real time elapsing while B was rebooted.
        for _ in 0..<1_000_000 { _ = counter.next() }

        // B reboots: new bootId (discards its old estimator), and its clock
        // now reads a tiny uptime -- nowhere near the phone's current time.
        let newTransportB = GroupFakeTransport()
        newTransportB.wifiBoardId = "B"
        newTransportB.bootId = "rebooted-boot"
        newTransportB.clockRxUs = 50
        newTransportB.clockTxUs = 60
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.debugReanchorNow()

        let atUs = try XCTUnwrap(newTransportB.sentGroupStartAtUs.last)
        XCTAssertGreaterThanOrEqual(atUs, 0, "a rolled-forward anchor must never map to a negative atUs")
    }

    /// R6a: a reconnected member is rejoined by `debugRejoinReconnectedNow`
    /// (the 1s cheap tick's own body) without waiting for the 30s full
    /// re-anchor pass.
    func testDebugRejoinReconnectedNowRejoinsWithoutFullReanchor() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        _ = sessionA

        let group = store.create(name: "快速重连组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)

        let newTransportB = GroupFakeTransport()
        newTransportB.wifiBoardId = "B"
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.debugRejoinReconnectedNow()

        XCTAssertEqual(newTransportB.sentGroupStartAtUs.count, 1,
                       "the reconnected board is rejoined immediately, without the 30s loop")
        XCTAssertEqual(sessionB.connection.output.source, .group)
    }

    /// R6e: the instant something else takes over a participant's output
    /// (before any re-anchor pass even runs), it's recorded as evicted --
    /// so a disconnect/reconnect right afterwards must never rejoin it back
    /// and steal it from whatever now owns it.
    func testTakeoverThenReconnectIsNeverRejoined() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        let sessionA = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        let sessionB = await connectedSession(sessions: sessions, identity: "B", transport: transportB)
        _ = sessionA

        let group = store.create(name: "接管组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
        XCTAssertEqual(sessionB.connection.output.source, .group)

        // Something else takes B over -- the R6e handler fires synchronously
        // right here, before any reanchor/rejoin pass ever runs.
        sessionB.connection.output.begin(.text)
        XCTAssertEqual(sessionB.connection.output.source, .text)

        // B then drops and reconnects, as if the takeover's own feature let
        // it disconnect.
        let newTransportB = GroupFakeTransport()
        newTransportB.wifiBoardId = "B"
        _ = await sessionB.connection.connect(using: newTransportB)

        await coordinator.debugReanchorNow()
        await coordinator.debugRejoinReconnectedNow()

        XCTAssertTrue(newTransportB.sentGroupStartAtUs.isEmpty, "an evicted board must never be rejoined")
        XCTAssertNotEqual(sessionB.connection.output.source, .group)
    }

    /// F4: a live speed change while a group is playing must never send a
    /// `group_start` whose `atUs` is in the future relative to when the
    /// board actually applies it -- firmware applies a `group_start` on
    /// receipt and holds `startFrame` until `atUs`, so a future `atUs`
    /// would freeze a playing board instead of switching smoothly.
    func testUpdatePlaybackNeverSendsAFutureAtUs() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "grp.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)

        let transportA = GroupFakeTransport()
        let transportB = GroupFakeTransport()
        // Board clock == phone clock (offset ~= 0), so `atUs` can be
        // compared directly against the phone's own real elapsed time.
        transportA.clockUsesRealTime = true
        transportB.clockUsesRealTime = true
        _ = await connectedSession(sessions: sessions, identity: "A", transport: transportA)
        _ = await connectedSession(sessions: sessions, identity: "B", transport: transportB)

        let group = store.create(name: "变速组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "B", displayName: "B"))

        try await coordinator.play(group: store.groups[0], text: "测试", fps: 10, loop: true)
        // `play()` anchors ~400 ms ahead; before that the boards are still
        // holding frame 0 and a speed change correctly keeps that start time.
        // This test is about a group that is already scrolling.
        try await Task.sleep(for: .milliseconds(600))

        await coordinator.updatePlayback(group: store.groups[0], fps: 30, loop: nil)

        let nowUsAfter = Int64(DispatchTime.now().uptimeNanoseconds / 1_000)
        let atUsA = try XCTUnwrap(transportA.sentGroupStartAtUs.last)
        let atUsB = try XCTUnwrap(transportB.sentGroupStartAtUs.last)
        // Generous tolerance for the real time elapsed while the test itself
        // ran -- the point is that `atUs` never lands meaningfully ahead of
        // "now", never a check for exact equality.
        XCTAssertLessThanOrEqual(atUsA, nowUsAfter + 5_000)
        XCTAssertLessThanOrEqual(atUsB, nowUsAfter + 5_000)
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
    /// When set, `clock_sample` ignores `clockRxUs`/`clockTxUs` and instead
    /// stamps both `rxUs`/`txUs` with real `DispatchTime.now()` at the
    /// moment the (possibly delayed) reply payload is actually generated --
    /// i.e. board clock == phone clock (offset ~=0), so a caller using the
    /// coordinator's own real `nowUs()` can compare `atUs` directly against
    /// real elapsed wall time instead of it being dominated by a pinned
    /// constant.
    var clockUsesRealTime = false
    /// Per-`cmd`-name reply delay, so a burst test can keep one slot of the
    /// command pump busy without delaying every reply.
    var cmdReplyDelay: [String: TimeInterval] = [:]
    var clockSampleReplyDelay: TimeInterval = 0
    /// B3: makes `BLOB_BEGIN` reply with undecodable JSON, so
    /// `uploadGroupScrollBitmap` throws for this board's upload without
    /// needing a timeout.
    var failBlobBegin = false
    /// 4.1: makes this board reply `{"ok": false}` to `group_start`, the
    /// same shape firmware sends when it rejects the requested `intervalMs`
    /// (still recorded in `sentGroupStartAtUs`/`sentGroupStartIntervalMs` --
    /// the point is that the reply itself, not the send, is rejected).
    var rejectGroupStart = false
    /// Extra `renderer` fields for `get_status` (e.g. a scroll still running).
    var statusRenderer: [String: Any] = [:]
    /// `GET_SCROLL_META` reply; `nil` replies with an empty meta.
    var scrollMeta: [String: Any]?
    /// One entry per `GET_SCROLL_META` request this board received.
    private(set) var scrollMetaRequestCount = 0
    private(set) var blobBeginCount = 0
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
            let renderer = statusRenderer.merging(["mode": "manual"]) { current, _ in current }
            let object: [String: Any] = ["ok": true, "renderer": renderer, "power": [:], "wifi": wifi]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        case .getPreviewSync:
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "mode": "manual"])) ?? Data()
        case .getFrame:
            return PackedFrame().data
        case .getScrollMeta:
            scrollMetaRequestCount += 1
            return (try? JSONSerialization.data(withJSONObject: scrollMeta ?? ["ok": true])) ?? Data()
        case .blobBegin:
            blobBeginCount += 1
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
                let rx: Int64
                let tx: Int64
                if clockUsesRealTime {
                    let now = Int64(DispatchTime.now().uptimeNanoseconds / 1_000)
                    rx = now
                    tx = now
                } else {
                    rx = clockRxUs
                    tx = clockTxUs
                }
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "rxUs": rx, "txUs": tx, "bootId": bootId])) ?? Data()
            case "group_start":
                if let atUs = object["atUs"] as? NSNumber { sentGroupStartAtUs.append(atUs.int64Value) }
                if let intervalMs = object["intervalMs"] as? NSNumber { sentGroupStartIntervalMs.append(intervalMs.intValue) }
                sentGroupStartFrames.append(object["startFrame"] as? Int ?? 0)
                if rejectGroupStart {
                    return (try? JSONSerialization.data(withJSONObject: ["ok": false])) ?? Data()
                }
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
