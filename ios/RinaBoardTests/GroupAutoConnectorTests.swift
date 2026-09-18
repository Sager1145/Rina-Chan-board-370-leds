import Foundation
import XCTest
@testable import RinaBoard
@testable import RinaCore

@MainActor
final class GroupAutoConnectorTests: XCTestCase {
    private func freshBoardStore() -> BoardStore {
        BoardStore(defaults: UserDefaults(suiteName: "gac.boards.\(UUID())")!)
    }

    private func freshGroupStore() -> BoardGroupStore {
        BoardGroupStore(defaults: UserDefaults(suiteName: "gac.groups.\(UUID())")!)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 1. Connects every offline member when the target becomes a group

    func testConnectsEveryOfflineMemberWhenTargetBecomesGroup() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        boardStore.upsert(KnownBoard(id: "known-B", name: "璃奈板 B", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B", knownBoardIDs: ["known-B"]))

        var connectedKnownIDs: [String] = []
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { known, session in
            connectedKnownIDs.append(known.id)
            let transport = GroupAutoConnectorFakeTransport()
            transport.wifiBoardId = known.id == "known-A" ? "AAAA" : "BBBB"
            _ = await session.connection.connect(using: transport)
        }

        connector.setTarget(.group(group.id))

        await waitUntil { connectedKnownIDs.count == 2 }
        XCTAssertEqual(Set(connectedKnownIDs), ["known-A", "known-B"])
        await waitUntil {
            sessions.sessions.filter { $0.connection.connectionState == .connected }.count == 2
        }
    }

    // MARK: 2. Never touches `sessions.active`

    func testNeverChangesActiveSession() async throws {
        let sessions = BoardSessionStore()
        let activeBefore = sessions.active
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))

        var connected = false
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { known, session in
            connected = true
            let transport = GroupAutoConnectorFakeTransport()
            transport.wifiBoardId = "AAAA"
            _ = await session.connection.connect(using: transport)
        }

        connector.setTarget(.group(group.id))
        await waitUntil { connected }

        XCTAssertTrue(sessions.active === activeBefore, "background member connects must never reselect the active board")
    }

    // MARK: 3. Does nothing for `.single`

    func testDoesNothingForSingleTarget() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))

        var connectAttempts = 0
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { _, _ in connectAttempts += 1 }

        connector.setTarget(.single)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(connectAttempts, 0)
        _ = group // silence unused warning if the compiler ever complains
    }

    // MARK: 4. Backs off on repeated failure instead of hot-looping

    func testBacksOffOnFailure() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))

        var attemptTimes: [Date] = []
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.1, 0.2]
        ) { _, _ in
            // Never connects: `session.connection.connectionState` stays
            // `.disconnected`, so every attempt after the first is a retry.
            attemptTimes.append(Date())
        }

        connector.setTarget(.group(group.id))
        await waitUntil(timeout: 1.5) { attemptTimes.count >= 3 }

        XCTAssertGreaterThanOrEqual(attemptTimes.count, 3)
        guard attemptTimes.count >= 3 else { return }
        let gap1 = attemptTimes[1].timeIntervalSince(attemptTimes[0])
        let gap2 = attemptTimes[2].timeIntervalSince(attemptTimes[1])
        // Never hot-loops (the first retry waits out the schedule's first
        // delay), and each gap is at least roughly its scheduled delay.
        XCTAssertGreaterThan(gap1, 0.03)
        XCTAssertGreaterThan(gap2, 0.06)
    }

    // MARK: 5. Resolves a member to a `KnownBoard` via `knownBoardIDs`

    func testResolvesKnownBoardViaKnownBoardIDs() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        // Deliberately not named after the BLE default, so only the
        // `knownBoardIDs` mapping (not the name fallback) can resolve it.
        boardStore.upsert(KnownBoard(id: "known-A", name: "客厅那块", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))

        var connectedKnownIDs: [String] = []
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { known, _ in connectedKnownIDs.append(known.id) }

        connector.setTarget(.group(group.id))
        await waitUntil { !connectedKnownIDs.isEmpty }

        XCTAssertEqual(connectedKnownIDs.first, "known-A")
    }

    // MARK: 6. Falls back to the "RinaBoard-<id>" BLE default name

    func testResolvesKnownBoardViaDefaultNameFallback() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "ble-xyz", name: "RinaBoard-CCCC", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        // No `knownBoardIDs` at all — only the name fallback can resolve it.
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "CCCC", displayName: "C"))

        var connectedKnownIDs: [String] = []
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { known, _ in connectedKnownIDs.append(known.id) }

        connector.setTarget(.group(group.id))
        await waitUntil { !connectedKnownIDs.isEmpty }

        XCTAssertEqual(connectedKnownIDs.first, "ble-xyz")
    }

    // MARK: 7. A user-initiated disconnect is not redialed until reconnect/re-target

    func testUserDisconnectIsNotRedialedUntilReconnectOrRetarget() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        let member = BoardGroup.Member(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"])
        try groupStore.addMember(groupID: group.id, member: member)

        var attempts = 0
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { known, session in
            attempts += 1
            let transport = GroupAutoConnectorFakeTransport()
            transport.wifiBoardId = "AAAA"
            _ = await session.connection.connect(using: transport)
        }

        connector.setTarget(.group(group.id))
        await waitUntil { sessions.session(matchingGroupMember: "AAAA")?.connection.connectionState == .connected }
        XCTAssertEqual(attempts, 1)

        sessions.session(matchingGroupMember: "AAAA")?.connection.disconnect(userInitiated: true)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(attempts, 1, "a user disconnect must not be auto-redialed")

        // The per-member "连接" button clears the block and reconnects.
        connector.connectNow(member)
        await waitUntil { attempts == 2 }
        XCTAssertEqual(attempts, 2)
    }

    // MARK: 8. Hotspot-only members are never auto-dialed

    func testHotspotOnlyMemberNeverAutoDialed() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "hotspot:AAAA", name: "热点板", preferredTransport: "hotspot", hotspotSSID: "AAAA"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["hotspot:AAAA"]))

        var attempts = 0
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { _, _ in attempts += 1 }

        connector.setTarget(.group(group.id))
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(attempts, 0, "a hotspot-only member must never be auto-dialed")
    }

    // MARK: 9. Never starts a second dial while a session for the board is already connecting

    func testNeverDialsWhileASessionForTheBoardIsAlreadyConnecting() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))

        // Simulate RootTabView's own launch-time reconnect already in flight
        // on this exact session, hung mid-handshake (never replies to PING).
        let existingSession = sessions.session(for: "known-A", name: "璃奈板 A")
        let hangingTransport = GroupAutoConnectorHangingTransport()
        Task { _ = await existingSession.connection.connect(using: hangingTransport) }
        await waitUntil { existingSession.connection.connectionState == .connecting }

        var attempts = 0
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { _, _ in attempts += 1 }

        connector.setTarget(.group(group.id))
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(attempts, 0, "must not start a second dial while a session for the board is connecting")
    }

    // MARK: 10. Caps retries after N consecutive failures

    func testCapsRetriesAfterConsecutiveFailures() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        let member = BoardGroup.Member(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"])
        try groupStore.addMember(groupID: group.id, member: member)

        var attempts = 0
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.02, 0.02, 0.02]
        ) { _, _ in attempts += 1 } // never connects: every attempt is a failure

        connector.setTarget(.group(group.id))
        await waitUntil(timeout: 3) { connector.hasGivenUp(member) }

        XCTAssertTrue(connector.hasGivenUp(member))
        let attemptsAtCap = attempts
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(attempts, attemptsAtCap, "must stop dialing once retries are exhausted")

        // The per-member "连接" button resets the cap.
        connector.connectNow(member)
        await waitUntil { attempts > attemptsAtCap }
        XCTAssertFalse(connector.hasGivenUp(member))
    }

    // MARK: 11. Serializes member connects instead of failing concurrent ones into backoff

    func testSerializesConcurrentMemberConnectsWithoutBackoff() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        boardStore.upsert(KnownBoard(id: "known-B", name: "璃奈板 B", preferredTransport: "bluetooth"))
        boardStore.upsert(KnownBoard(id: "known-C", name: "璃奈板 C", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B", knownBoardIDs: ["known-B"]))
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "CCCC", displayName: "C", knownBoardIDs: ["known-C"]))

        let attempts = Counter()
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [5, 15, 30] // a real 3-board group must never hit these.
        ) { known, session in
            await attempts.increment(known.id)
            let transport = GroupAutoConnectorFakeTransport()
            transport.wifiBoardId = known.id == "known-A" ? "AAAA" : known.id == "known-B" ? "BBBB" : "CCCC"
            _ = await session.connection.connect(using: transport)
        }

        connector.setTarget(.group(group.id))
        await waitUntil(timeout: 3) {
            sessions.sessions.filter { $0.connection.connectionState == .connected }.count == 3
        }

        XCTAssertEqual(sessions.sessions.filter { $0.connection.connectionState == .connected }.count, 3)
        // Each member connected on its very first attempt — no member was
        // ever forced into the (multi-second) backoff schedule by a sibling
        // connect racing the shared `ConnectionViewModel`.
        let counts = await attempts.counts
        XCTAssertEqual(counts["known-A"], 1)
        XCTAssertEqual(counts["known-B"], 1)
        XCTAssertEqual(counts["known-C"], 1)
    }

    // MARK: 12. Switching to `.single` stops dialing but keeps existing links

    func testSingleTargetStopsDialingButKeepsLinks() async throws {
        let sessions = BoardSessionStore()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        boardStore.upsert(KnownBoard(id: "known-A", name: "璃奈板 A", preferredTransport: "bluetooth"))
        boardStore.upsert(KnownBoard(id: "known-B", name: "璃奈板 B", preferredTransport: "bluetooth"))
        let group = groupStore.create(name: "测试组")
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "A", knownBoardIDs: ["known-A"]))
        try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "B", knownBoardIDs: ["known-B"]))

        var attempts = 0
        let connector = GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            backoffSchedule: [0.05, 0.05, 0.05]
        ) { known, session in
            attempts += 1
            let transport = GroupAutoConnectorFakeTransport()
            transport.wifiBoardId = known.id == "known-A" ? "AAAA" : "BBBB"
            _ = await session.connection.connect(using: transport)
        }

        connector.setTarget(.group(group.id))
        await waitUntil {
            sessions.sessions.filter { $0.connection.connectionState == .connected }.count == 2
        }
        let attemptsWhileGrouped = attempts

        connector.setTarget(.single)
        // Existing links stay up — `setTarget` must never disconnect them.
        XCTAssertEqual(sessions.sessions.filter { $0.connection.connectionState == .connected }.count, 2)

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(attempts, attemptsWhileGrouped, "must not keep dialing once the target leaves the group")
        XCTAssertEqual(sessions.sessions.filter { $0.connection.connectionState == .connected }.count, 2)
    }
}

/// Thread-hopping-safe counter for the concurrency test above (all callers
/// are already MainActor-isolated, but `actor` keeps this future-proof).
private actor Counter {
    private(set) var counts: [String: Int] = [:]
    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }
}

// MARK: - Fake transport

/// Minimal `RinaTransport` fake: replies `{"ok":true}` to everything, and
/// `get_status` additionally carries `wifi.boardId` when set, so
/// `BoardConnection.connect(using:)` completes its handshake with a live
/// `boardIdentity` — the same shape `GroupControlFanOutTests`' fake uses.
private final class GroupAutoConnectorFakeTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var wifiBoardId: String?

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            var reply: [String: Any] = ["ok": true, "proto": 1, "bootId": "aaaaaaaa", "caps": [String]()]
            if request.type == RinaLinkMessageType.getStatus.rawValue, let wifiBoardId {
                reply["wifi"] = ["ip": "192.168.4.1", "boardId": wifiBoardId]
                reply["renderer"] = ["mode": "manual"]
            }
            let payload = try! JSONSerialization.data(withJSONObject: reply)
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
            ))
        }
    }
}

/// A transport whose carrier connects but never replies to anything —
/// `BoardConnection.connect(using:)` stays `.connecting` forever (until its
/// own handshake timeout), simulating a launch-time reconnect still in
/// flight when `GroupAutoConnector` reconciles.
private final class GroupAutoConnectorHangingTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512

    private var stateContinuation: AsyncStream<TransportState>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { _ in } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }
    func send(_ data: Data) async throws {}
}
