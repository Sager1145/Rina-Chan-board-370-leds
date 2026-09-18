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

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
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

        connector.setTarget(.group(group.id), isExplicit: true)

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

        connector.setTarget(.group(group.id), isExplicit: true)
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

        connector.setTarget(.single, isExplicit: true)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(connectAttempts, 0)
        _ = group // silence unused warning if the compiler ever complains
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

        connector.setTarget(.group(group.id), isExplicit: true)
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

        connector.setTarget(.group(group.id), isExplicit: true)
        await waitUntil { !connectedKnownIDs.isEmpty }

        XCTAssertEqual(connectedKnownIDs.first, "ble-xyz")
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

        connector.setTarget(.group(group.id), isExplicit: true)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(attempts, 0, "a hotspot-only member must never be auto-dialed")
        XCTAssertTrue(sessions.sessions.isEmpty, "reconcile must create no session for a skipped member")
        XCTAssertNil(sessions.active.boardID)
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

        connector.setTarget(.group(group.id), isExplicit: true)
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

        connector.setTarget(.group(group.id), isExplicit: true)
        await waitUntil {
            sessions.sessions.filter { $0.connection.connectionState == .connected }.count == 2
        }
        let attemptsWhileGrouped = attempts

        connector.setTarget(.single, isExplicit: true)
        // Existing links stay up — `setTarget` must never disconnect them.
        XCTAssertEqual(sessions.sessions.filter { $0.connection.connectionState == .connected }.count, 2)

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(attempts, attemptsWhileGrouped, "must not keep dialing once the target leaves the group")
        XCTAssertEqual(sessions.sessions.filter { $0.connection.connectionState == .connected }.count, 2)
    }

    // MARK: - Real BoardConnection path
    //
    // These drive `BoardConnection.connect(using:)` with scripted transports,
    // so the connector sees the real `.connecting`/`.reconnecting`/`.failed`
    // transitions (including BoardConnection's own 5-attempt retry loop),
    // with a scaled clock (1 s → 10 ms) for backoff and the attempt timeout.

    private func realSessions() -> BoardSessionStore {
        BoardSessionStore(makeConnection: {
            BoardConnection(reconnectDelay: { _ in 0.001 }, handshakeTimeout: 0.5)
        })
    }

    private func makeConnector(
        _ sessions: BoardSessionStore, _ groupStore: BoardGroupStore, _ boardStore: BoardStore,
        clock: ScaledClock,
        connect: @escaping @MainActor (KnownBoard, BoardSession) async -> Void
    ) -> GroupAutoConnector {
        GroupAutoConnector(
            sessions: sessions, groupStore: groupStore, boardStore: boardStore,
            sleep: { try await clock.sleep($0) }, connect: connect
        )
    }

    /// Group with one BLE-known member per id ("known-<id>").
    private func makeGroup(_ ids: [String], boardStore: BoardStore, groupStore: BoardGroupStore) throws -> (BoardGroup, [BoardGroup.Member]) {
        let group = groupStore.create(name: "测试组")
        var members: [BoardGroup.Member] = []
        for id in ids {
            boardStore.upsert(KnownBoard(id: "known-\(id)", name: "璃奈板 \(id)", preferredTransport: "bluetooth"))
            let member = BoardGroup.Member(physicalBoardID: id, displayName: id, knownBoardIDs: ["known-\(id)"])
            try groupStore.addMember(groupID: group.id, member: member)
            members.append(member)
        }
        return (group, members)
    }

    // MARK: R1. Backoff 5/15/30/30 and a cap of 5 dials, idle during the retry loop

    func testRealPathBacksOffAndCapsWithoutCountingTheRetryLoop() async throws {
        let sessions = realSessions()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        let (group, members) = try makeGroup(["AAAA"], boardStore: boardStore, groupStore: groupStore)
        let clock = ScaledClock()
        let carrierConnects = Counter()
        var dials = 0
        var statesAtDial: [BoardConnectionState] = []
        let connector = makeConnector(sessions, groupStore, boardStore, clock: clock) { _, session in
            dials += 1
            statesAtDial.append(session.connection.connectionState)
            _ = await session.connection.connect(using: ScriptedTransport(.fail, counter: carrierConnects))
        }

        connector.setTarget(.group(group.id), isExplicit: true)
        await waitUntil(timeout: 8) { connector.hasGivenUp(members[0]) && dials == 5 }

        XCTAssertEqual(dials, GroupAutoConnector.maxConsecutiveFailures)
        XCTAssertTrue(connector.hasGivenUp(members[0]))
        XCTAssertEqual(clock.requested.filter { $0 != 20 }, [5, 15, 30, 30])
        for state in statesAtDial {
            XCTAssertFalse(state == .connecting, "never dials over an in-flight connect")
            if case .reconnecting = state { XCTFail("never dials while BoardConnection's own loop runs") }
        }
        // Each dial = 1 connect(using:) + BoardConnection's 5 internal retries.
        let carrierCount = await carrierConnects.counts["x"]
        XCTAssertEqual(carrierCount, 30)

        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(dials, 5, "must stop dialing once the cap is reached")

        connector.connectNow(members[0])
        await waitUntil { dials == 6 }
        XCTAssertEqual(dials, 6)
        XCTAssertFalse(connector.hasGivenUp(members[0]))
    }

    // MARK: R2. User disconnect survives a foreground; explicit re-target/connectNow clear it

    func testRealPathUserDisconnectSurvivesForegroundResume() async throws {
        let sessions = realSessions()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        let (group, members) = try makeGroup(["AAAA"], boardStore: boardStore, groupStore: groupStore)
        let clock = ScaledClock()
        var dials = 0
        let connector = makeConnector(sessions, groupStore, boardStore, clock: clock) { _, session in
            dials += 1
            _ = await session.connection.connect(using: ScriptedTransport(.succeed("AAAA")))
        }
        func memberState() -> BoardConnectionState? { sessions.session(matchingGroupMember: "AAAA")?.connection.connectionState }

        connector.setTarget(.group(group.id), isExplicit: false) // launch restore
        await waitUntil { memberState() == .connected }
        XCTAssertEqual(dials, 1)

        sessions.session(matchingGroupMember: "AAAA")?.connection.disconnect(userInitiated: true)
        connector.setTarget(.group(group.id), isExplicit: false) // foreground resume
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(dials, 1, "a foreground must not clear the user-disconnect block")
        XCTAssertEqual(memberState(), .disconnected)

        connector.setTarget(.group(group.id), isExplicit: true) // explicit re-target
        await waitUntil { memberState() == .connected }
        XCTAssertEqual(dials, 2)

        sessions.session(matchingGroupMember: "AAAA")?.connection.disconnect(userInitiated: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(dials, 2)
        connector.connectNow(members[0])
        await waitUntil { memberState() == .connected }
        XCTAssertEqual(dials, 3)
        XCTAssertEqual(sessions.sessions.count, 1, "every dial reused the member's one session")
    }

    // MARK: R3. Target → single drops queued attempts; the in-flight one finishes

    func testRealPathSingleTargetDropsQueuedButFinishesInFlight() async throws {
        let sessions = realSessions()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        let (group, _) = try makeGroup(["AAAA", "BBBB"], boardStore: boardStore, groupStore: groupStore)
        let clock = ScaledClock()
        let gate = ScriptedTransport(.gated("AAAA"))
        var dialed: [String] = []
        var postConnectRan = false
        let connector = makeConnector(sessions, groupStore, boardStore, clock: clock) { known, session in
            dialed.append(known.id)
            let transport = known.id == "known-AAAA" ? gate : ScriptedTransport(.succeed("BBBB"))
            let ok = await session.connection.connect(using: transport)
            // Stands in for connectSavedBoard's post-connect naming.
            if ok, !Task.isCancelled { postConnectRan = true }
        }

        connector.setTarget(.group(group.id), isExplicit: true)
        await waitUntil { gate.isWaiting }
        XCTAssertEqual(dialed, ["known-AAAA"], "B waits in the serial queue")

        connector.setTarget(.single, isExplicit: true)
        gate.release()
        await waitUntil { postConnectRan }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(postConnectRan, "the in-flight attempt and its naming must finish")
        XCTAssertEqual(sessions.session(matchingGroupMember: "AAAA")?.connection.connectionState, .connected)
        XCTAssertEqual(dialed, ["known-AAAA"], "the queued attempt for B must be dropped")
        XCTAssertEqual(sessions.sessions.count, 1, "no session was created for the dropped member")
    }

    // MARK: R4. No duplicate dial or session for a member reached by another identity

    func testRealPathNoDuplicateDialOrSession() async throws {
        let sessions = realSessions()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        let (group, _) = try makeGroup(["AAAA"], boardStore: boardStore, groupStore: groupStore)
        // The same board is also known over Wi-Fi, and that session is live.
        boardStore.upsert(KnownBoard(id: "10.0.0.7", name: "璃奈板 AAAA", preferredTransport: "wifi"))
        let wifiSession = sessions.session(for: "10.0.0.7", name: "璃奈板 AAAA")
        _ = await wifiSession.connection.connect(using: ScriptedTransport(.succeed("AAAA")))
        XCTAssertEqual(wifiSession.connection.connectionState, .connected)

        let clock = ScaledClock()
        var dialedSessions: [BoardSession] = []
        let connector = makeConnector(sessions, groupStore, boardStore, clock: clock) { _, session in
            dialedSessions.append(session)
            _ = await session.connection.connect(using: ScriptedTransport(.succeed("AAAA")))
        }

        connector.setTarget(.group(group.id), isExplicit: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(dialedSessions.isEmpty, "connected under its live identity: no dial")
        XCTAssertEqual(sessions.sessions.count, 1, "reconcile created no session")

        // The link drops (not user-initiated) and BoardConnection's loop is
        // stopped: the connector redials that same session, not a new one.
        wifiSession.connection.disconnect()
        await waitUntil { !dialedSessions.isEmpty && wifiSession.connection.connectionState == .connected }
        XCTAssertEqual(dialedSessions.count, 1)
        XCTAssertTrue(dialedSessions.first === wifiSession, "must dial the matching session, not create one")
        XCTAssertEqual(sessions.sessions.count, 1)

        // A session already .connecting for the member (e.g. a manual connect) blocks dialing.
        let hang = ScriptedTransport(.gated("AAAA"))
        wifiSession.connection.disconnect()
        Task { _ = await wifiSession.connection.connect(using: hang) }
        await waitUntil { hang.isWaiting }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(dialedSessions.count, 1, "never a second dial while one is connecting")
        hang.release()
    }

    // MARK: R5. A hung dial times out and frees the queue

    func testRealPathTimeoutFreesTheQueue() async throws {
        let sessions = realSessions()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        let (group, _) = try makeGroup(["AAAA", "BBBB"], boardStore: boardStore, groupStore: groupStore)
        let clock = ScaledClock()
        let hung = ScriptedTransport(.gated("AAAA")) // never released
        var dialed: [String] = []
        let connector = makeConnector(sessions, groupStore, boardStore, clock: clock) { known, session in
            dialed.append(known.id)
            let transport = known.id == "known-AAAA" ? hung : ScriptedTransport(.succeed("BBBB"))
            _ = await session.connection.connect(using: transport)
        }

        connector.setTarget(.group(group.id), isExplicit: true)
        await waitUntil { sessions.session(matchingGroupMember: "BBBB")?.connection.connectionState == .connected }

        XCTAssertEqual(Array(dialed.prefix(2)), ["known-AAAA", "known-BBBB"])
        XCTAssertTrue(clock.requested.contains(20), "the per-attempt timeout ran")
        let aSession = sessions.existingSession(for: "known-AAAA")
        XCTAssertNotEqual(aSession?.connection.connectionState, .connecting, "the hung carrier was torn down")
    }

    // MARK: R6. connectNow supersedes a waiting attempt and runs exactly one connect

    func testRealPathConnectNowRunsExactlyOneConnect() async throws {
        let sessions = realSessions()
        let boardStore = freshBoardStore()
        let groupStore = freshGroupStore()
        let (group, members) = try makeGroup(["AAAA"], boardStore: boardStore, groupStore: groupStore)
        let clock = ScaledClock()
        var dials = 0
        let connector = makeConnector(sessions, groupStore, boardStore, clock: clock) { _, session in
            dials += 1
            let transport = dials == 1 ? ScriptedTransport(.fail) : ScriptedTransport(.succeed("AAAA"))
            _ = await session.connection.connect(using: transport)
        }

        connector.setTarget(.group(group.id), isExplicit: true)
        // First dial fails; after BoardConnection's loop the connector waits out 5 s (50 ms).
        await waitUntil { clock.requested.contains(5) }
        connector.connectNow(members[0])
        connector.connectNow(members[0])
        await waitUntil { sessions.existingSession(for: "known-AAAA")?.connection.connectionState == .connected }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(dials, 2, "double tap + superseded backoff must yield exactly one extra connect")
        XCTAssertEqual(sessions.sessions.count, 1)
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

/// Records every requested sleep and sleeps 1/100 of it (1 s → 10 ms).
@MainActor
private final class ScaledClock {
    private(set) var requested: [Double] = []
    func sleep(_ seconds: Double) async throws {
        requested.append(seconds)
        try await Task.sleep(nanoseconds: UInt64(seconds * 10_000_000))
    }
}

/// Scripted carrier for `BoardConnection.connect(using:)`:
/// - `.succeed(id)`: connects and answers every request, `get_status`
///   carrying `wifi.boardId = id`.
/// - `.fail`: `connect()` throws, so BoardConnection runs its own retry loop.
/// - `.gated(id)`: `connect()` blocks until `release()` (then behaves like
///   `.succeed`) or `disconnect()` (then throws) — a hung carrier.
@MainActor
private final class ScriptedTransport: @MainActor RinaTransport {
    enum Mode { case succeed(String), fail, gated(String) }
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    private let mode: Mode
    private let counter: Counter?
    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?
    private var gate: CheckedContinuation<Void, Error>?
    private var released = false
    private(set) var isWaiting = false

    init(_ mode: Mode, counter: Counter? = nil) {
        self.mode = mode
        self.counter = counter
    }

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }

    func connect() async throws {
        await counter?.increment("x")
        switch mode {
        case .fail:
            throw RinaTransportError.underlying("scripted failure")
        case .succeed:
            break
        case .gated:
            if !released {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    gate = continuation
                    isWaiting = true
                }
                isWaiting = false
            }
        }
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        if let gate {
            self.gate = nil
            isWaiting = false
            gate.resume(throwing: RinaTransportError.notConnected)
        }
        stateContinuation?.yield(.disconnected)
    }

    func send(_ data: Data) async throws {
        let boardId: String?
        switch mode {
        case .succeed(let id), .gated(let id): boardId = id
        case .fail: boardId = nil
        }
        for request in decoder.feed(data) {
            var reply: [String: Any] = ["ok": true, "proto": 1, "bootId": "aaaaaaaa", "caps": [String]()]
            if request.type == RinaLinkMessageType.getStatus.rawValue, let boardId {
                reply["wifi"] = ["ip": "192.168.4.1", "boardId": boardId]
                reply["renderer"] = ["mode": "manual"]
            }
            let payload = try! JSONSerialization.data(withJSONObject: reply)
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
            ))
        }
    }
}
