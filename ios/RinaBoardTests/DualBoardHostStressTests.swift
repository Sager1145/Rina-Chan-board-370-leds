import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Host-level (simulator, fake transports) stress tests for the multi-board
/// plan (docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md §3.1 INV-1/INV-2/INV-6,
/// §4.2 DB-SW, §4.4 DB-INF, §4.6 DB-ST). These run alongside a real-hardware
/// soak and cover what hardware timing/manual-QA cannot: seeded random-walk
/// invariant checks and deterministic race windows.
@MainActor
final class DualBoardHostStressTests: XCTestCase {

    // MARK: 1. Seeded random walk (INV-1, INV-2)

    func testSeededRandomWalkNeverRoutesToInactiveBoard() async throws {
        var rng = SplitMix64(seed: 20260913)
        let suiteName = "DualBoardHostStressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boardStore = BoardStore(defaults: defaults)
        let store = BoardSessionStore()
        let model = ConnectionViewModel()

        struct Rig {
            let id = UUID().uuidString
            let name: String
        }
        let rigs = [Rig(name: "A"), Rig(name: "B"), Rig(name: "C")]
        for rig in rigs {
            boardStore.upsert(KnownBoard(id: rig.id, name: rig.name, preferredTransport: "bluetooth"))
        }
        // Current live transport for each board id, replaced on every connect.
        var transports: [String: StressTransport] = [:]
        // First-observed boardID for each BoardSession.id, to catch mutation.
        var observedBoardID: [UUID: String] = [:]

        var actionCounts: [String: Int] = [:]
        var sendsChecked = 0

        func checkInvariants(file: StaticString = #filePath, line: UInt = #line) {
            // INV-2: at most one session per board id.
            var seenBoardIDs: Set<String> = []
            for session in store.sessions {
                if let boardID = session.boardID {
                    XCTAssertFalse(seenBoardIDs.contains(boardID),
                                    "Two sessions claim board \(boardID)", file: file, line: line)
                    seenBoardIDs.insert(boardID)
                    if let previous = observedBoardID[session.id] {
                        XCTAssertEqual(previous, boardID,
                                        "Session boardID must never change identity", file: file, line: line)
                    } else {
                        observedBoardID[session.id] = boardID
                    }
                }
            }
            for rig in rigs {
                let a = store.existingSession(for: rig.id)
                for other in rigs where other.id != rig.id {
                    let b = store.existingSession(for: other.id)
                    if let a, let b { XCTAssertFalse(a === b, file: file, line: line) }
                }
            }
            // `active` is always one of `sessions`, or the empty placeholder.
            if !store.sessions.isEmpty {
                XCTAssertTrue(store.sessions.contains { $0 === store.active },
                               "active must be a member of sessions", file: file, line: line)
            }
        }

        for _ in 0..<1000 {
            let action = rng.next() % 5
            switch action {
            case 0: // select a random known session
                actionCounts["select", default: 0] += 1
                if let target = store.sessions.randomElement(using: &rng) {
                    store.select(target)
                }
            case 1: // connectSavedBoard to a random board
                actionCounts["connect", default: 0] += 1
                let rig = rigs[Int(rng.next() % UInt64(rigs.count))]
                guard let board = boardStore.boards.first(where: { $0.id == rig.id }) else { break }
                await model.connectSavedBoard(
                    board, sessions: store, boardStore: boardStore,
                    joinBoardHotspot: { _ in "" },
                    connectTransport: { session, _ in
                        let transport = StressTransport(kind: .bluetooth)
                        transport.defaultName = "RinaBoard-\(rig.id.prefix(12))"
                        transports[rig.id] = transport
                        return await session.connection.connect(using: transport)
                    }
                )
            case 2: // send through the currently active session
                actionCounts["send", default: 0] += 1
                let active = store.active
                guard let activeBoardID = active.boardID,
                      active.connection.connectionState == .connected,
                      let activeTransport = transports[activeBoardID] else { break }
                let othersBefore = rigs.filter { $0.id != activeBoardID }
                    .compactMap { transports[$0.id] }
                    .map { ($0, $0.commandCount) }
                let before = activeTransport.commandCount
                _ = try? await active.connection.command(.button(button: "B1"))
                sendsChecked += 1
                XCTAssertEqual(activeTransport.commandCount, before + 1,
                                "active board's transport must receive its own command")
                for (other, countBefore) in othersBefore {
                    XCTAssertEqual(other.commandCount, countBefore,
                                    "an inactive board's transport must never receive a routed command")
                }
            case 3: // disconnect a random session
                actionCounts["disconnect", default: 0] += 1
                if let target = store.sessions.randomElement(using: &rng) {
                    target.connection.disconnect()
                }
            default: // remove then re-add a random board
                actionCounts["removeReadd", default: 0] += 1
                let rig = rigs[Int(rng.next() % UInt64(rigs.count))]
                store.remove(id: rig.id)
                guard let board = boardStore.boards.first(where: { $0.id == rig.id }) else { break }
                await model.connectSavedBoard(
                    board, sessions: store, boardStore: boardStore,
                    joinBoardHotspot: { _ in "" },
                    connectTransport: { session, _ in
                        let transport = StressTransport(kind: .bluetooth)
                        transports[rig.id] = transport
                        return await session.connection.connect(using: transport)
                    }
                )
            }
            checkInvariants()
        }

        for session in store.sessions { session.connection.disconnect() }
        print("[DualBoardHostStressTests] random walk: \(actionCounts), sendsChecked=\(sendsChecked)")
    }

    // MARK: 2. Queued commands/frames do not follow selection (DB-SW)

    func testQueuedCommandsAndFramesDoNotFollowSelectionToAnotherBoard() async throws {
        try await runQueueDoesNotFollowSelection(useConnectSavedBoard: false)
    }

    func testQueuedCommandsAndFramesDoNotFollowSelectionToAnotherBoardViaConnectSavedBoard() async throws {
        try await runQueueDoesNotFollowSelection(useConnectSavedBoard: true)
    }

    private func runQueueDoesNotFollowSelection(useConnectSavedBoard: Bool) async throws {
        let store = BoardSessionStore()
        let sessionA = store.session(for: "A-" + UUID().uuidString, name: "A")
        let sessionB = store.session(for: "B-" + UUID().uuidString, name: "B")
        let transportA = StressTransport(kind: .bluetooth)
        let transportB = StressTransport(kind: .bluetooth)
        defer {
            sessionA.connection.disconnect()
            sessionB.connection.disconnect()
        }
        _ = await sessionA.connection.connect(using: transportA)
        _ = await sessionB.connection.connect(using: transportB)
        store.select(sessionA)
        // Both transports' setup handshakes (subscribe + get_info) already sent
        // a couple of `.cmd` frames; only count frames sent from this point on.
        transportA.commandCount = 0
        transportA.frameCount = 0
        transportB.commandCount = 0
        transportB.frameCount = 0
        transportA.replyDelay = 0.15 // slow ACK, well past the 120ms command pump interval

        var commandTasks: [Task<Result<Void, Error>, Never>] = []
        for i in 0..<6 {
            commandTasks.append(Task {
                do {
                    _ = try await sessionA.connection.command(.button(button: "B\(i % 2)"))
                    return .success(())
                } catch { return .failure(error) }
            })
        }
        let outputToken = sessionA.connection.output.begin(.manual)
        var frameTasks: [Task<Result<Void, Error>, Never>] = []
        for _ in 0..<8 {
            frameTasks.append(Task {
                do {
                    _ = try await sessionA.connection.setFrame(PackedFrame(), playback: .idle,
                                                                reason: "stress", outputSession: outputToken)
                    return .success(())
                } catch { return .failure(error) }
            })
        }

        if useConnectSavedBoard {
            let suiteName = "DualBoardHostStressTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let boardStore = BoardStore(defaults: defaults)
            let board = KnownBoard(id: sessionB.boardID ?? "B", name: "B", preferredTransport: "bluetooth")
            boardStore.upsert(board)
            await ConnectionViewModel().connectSavedBoard(
                board, sessions: store, boardStore: boardStore,
                joinBoardHotspot: { _ in XCTFail("connected board must not rejoin"); return "" },
                connectTransport: { _, _ in XCTFail("connected board must not redial"); return false }
            )
        } else {
            store.select(sessionB)
        }

        var commandSuccesses = 0
        for task in commandTasks {
            switch await task.value {
            case .success: commandSuccesses += 1
            case .failure(let error):
                let isDropped: Bool
                if case RatePumpError.dropped = error { isDropped = true } else { isDropped = false }
                XCTAssertTrue(error is CancellationError || isDropped,
                               "unexpected command failure: \(error)")
            }
        }
        var frameSuccesses = 0
        for task in frameTasks {
            switch await task.value {
            case .success: frameSuccesses += 1
            case .failure(let error):
                let isDropped: Bool
                if case RatePumpError.dropped = error { isDropped = true } else { isDropped = false }
                XCTAssertTrue(error is CancellationError || isDropped,
                               "unexpected frame failure: \(error)")
            }
        }

        XCTAssertEqual(transportB.commandCount, 0, "B must never see A's queued commands")
        XCTAssertEqual(transportB.frameCount, 0, "B must never see A's queued frames")
        XCTAssertEqual(transportA.commandCount, commandSuccesses)
        XCTAssertEqual(transportA.frameCount, frameSuccesses)
        XCTAssertTrue(store.active === sessionB)
    }

    // MARK: 4. connectSavedBoard reentrancy / failed dial isolation

    func testSwitchToConnectingBoardReturnsWithoutSecondDialAndFailedDialLeavesOtherSessionUntouched() async throws {
        let suiteName = "DualBoardHostStressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boardStore = BoardStore(defaults: defaults)
        let store = BoardSessionStore()

        // --- Part 1: target already `.connecting` must not be dialed twice.
        let boardA = KnownBoard(id: UUID().uuidString, name: "A", preferredTransport: "bluetooth")
        boardStore.upsert(boardA)
        let holdingTransport = StressTransport(kind: .bluetooth)
        holdingTransport.holdConnect = true
        let dialer = ConnectionViewModel()
        let dialTask = Task {
            await dialer.connectSavedBoard(
                boardA, sessions: store, boardStore: boardStore,
                joinBoardHotspot: { _ in "" },
                connectTransport: { session, _ in await session.connection.connect(using: holdingTransport) }
            )
        }
        await waitUntilTrue { store.existingSession(for: boardA.id)?.connection.connectionState == .connecting }

        var interloperDialed = false
        let interloper = ConnectionViewModel()
        await interloper.connectSavedBoard(
            boardA, sessions: store, boardStore: boardStore,
            joinBoardHotspot: { _ in XCTFail("must not join hotspot while already connecting"); return "" },
            connectTransport: { _, _ in interloperDialed = true; return false }
        )
        XCTAssertFalse(interloperDialed, "a session already .connecting must not be dialed again")
        XCTAssertTrue(store.active === store.existingSession(for: boardA.id),
                       "connectSavedBoard must still select the target session")

        holdingTransport.releaseConnect()
        await dialTask.value
        await waitUntilTrue { store.existingSession(for: boardA.id)?.connection.connectionState == .connected }

        // --- Part 2: a failed dial to C must not touch the connected session B.
        let boardB = KnownBoard(id: UUID().uuidString, name: "B", preferredTransport: "bluetooth")
        let boardC = KnownBoard(id: UUID().uuidString, name: "C", preferredTransport: "bluetooth")
        boardStore.upsert(boardB)
        boardStore.upsert(boardC)
        let transportB = StressTransport(kind: .bluetooth)
        let modelB = ConnectionViewModel()
        await modelB.connectSavedBoard(
            boardB, sessions: store, boardStore: boardStore,
            joinBoardHotspot: { _ in "" },
            connectTransport: { session, _ in await session.connection.connect(using: transportB) }
        )
        let sessionB = try XCTUnwrap(store.existingSession(for: boardB.id))
        XCTAssertEqual(sessionB.connection.connectionState, .connected)

        let failingTransport = StressTransport(kind: .bluetooth)
        failingTransport.shouldFailConnect = true
        let modelC = ConnectionViewModel()
        await modelC.connectSavedBoard(
            boardC, sessions: store, boardStore: boardStore,
            joinBoardHotspot: { _ in "" },
            connectTransport: { session, _ in await session.connection.connect(using: failingTransport) }
        )
        let sessionC = try XCTUnwrap(store.existingSession(for: boardC.id))
        XCTAssertNotEqual(sessionC.connection.connectionState, .connected)

        XCTAssertEqual(transportB.disconnectCount, 0, "B's transport must not be disconnected by C's failed dial")
        XCTAssertEqual(sessionB.connection.connectionState, .connected)
        let before = transportB.commandCount
        _ = try await sessionB.connection.command(.button(button: "B1"))
        XCTAssertEqual(transportB.commandCount, before + 1, "B must keep routing commands after C's failed dial")

        store.sessions.forEach { $0.connection.disconnect() }
    }

    // MARK: 5. Board identity from handshake drives draft discard

    func testBoardIdentityFromHandshakeDrivesDraftDiscard() async throws {
        // Two different "transport kinds" reporting the same physical board.
        let bleTransport = StressTransport(kind: .bluetooth)
        bleTransport.defaultName = "RinaBoard-AABBCCDDEEFF" // BLE-like: identity via get_info
        let connA = BoardConnection()
        var identityAtReadyTime: String?
        let connectedA = await connA.connect(using: bleTransport) { identityAtReadyTime = connA.boardIdentity }
        XCTAssertTrue(connectedA)
        XCTAssertNotNil(identityAtReadyTime, "boardIdentity must be set before onReady/.connected")
        XCTAssertEqual(connA.boardIdentity, "AABBCCDDEEFF")
        let keyA = try XCTUnwrap(connA.boardKey)

        let wifiTransport = StressTransport(kind: .wifi(host: "10.0.0.5", port: RinaLinkConstants.tcpPort))
        wifiTransport.wifiBoardId = "aabbccddeeff" // Wi-Fi-like: identity via wifi.boardId
        let connA2 = BoardConnection()
        let connectedA2 = await connA2.connect(using: wifiTransport)
        XCTAssertTrue(connectedA2)
        XCTAssertEqual(connA2.boardIdentity, "AABBCCDDEEFF")
        XCTAssertEqual(connA2.boardKey, keyA, "the same board must resolve to the same key over any transport")

        connA.disconnect()
        XCTAssertNil(connA.boardIdentity, "boardIdentity must be cleared on disconnect")

        // A different board.
        let otherTransport = StressTransport(kind: .bluetooth)
        otherTransport.defaultName = "RinaBoard-112233445566"
        let connB = BoardConnection()
        let connectedB = await connB.connect(using: otherTransport)
        XCTAssertTrue(connectedB)
        let keyB = try XCTUnwrap(connB.boardKey)
        XCTAssertNotEqual(keyA, keyB)

        // ControlViewModel draft: kept across a same-board reconnect, discarded on switch.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualBoardHostStressTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ControlViewModel(draftStorage: DraftStorage(directory: directory))
        await model.restoreDraft()

        model.toggle(led: 0, connection: connA2)
        model.invert(connection: connA2)
        model.saveName = "unsaved-a"
        let drawn = model.draftFrame
        model.boardDidChange(to: keyA)
        XCTAssertEqual(model.draftBoardID, keyA)
        XCTAssertEqual(model.draftFrame, drawn)

        // Same board reconnecting (still keyA) keeps the draft.
        model.boardDidChange(to: keyA)
        XCTAssertEqual(model.draftFrame, drawn)
        XCTAssertTrue(model.canUndo)

        // Switching to B discards it.
        model.boardDidChange(to: keyB)
        XCTAssertEqual(model.draftBoardID, keyB)
        XCTAssertFalse(model.canUndo)
        XCTAssertNotEqual(model.draftFrame, drawn)

        // A live push after the switch must never reach B with the stale draft.
        model.toggle(led: 0, connection: connA2) // draft now belongs to keyA again via draftBelongs()
        await model.send(connection: connB)
        XCTAssertEqual(otherTransport.frameCount, 0, "the old draft must never be sent to the new board")

        connA2.disconnect()
        connB.disconnect()
    }
}

// MARK: - Minimal shared fake transport

/// A `RinaTransport` fake supporting the identity fields (`wifi.boardId`,
/// `get_info.defaultName`) and configurable reply delay/connect stalls this
/// suite needs, which the existing per-file fakes (`FakeRinaTransport`,
/// `SessionTransport`, `LifecycleTransport`) don't expose together.
@MainActor
private final class StressTransport: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    /// Delay before a reply is emitted, simulating a slow board ACK.
    var replyDelay: TimeInterval = 0
    var wifiBoardId: String?
    var defaultName: String?
    var holdConnect = false
    var shouldFailConnect = false
    var commandCount = 0
    var frameCount = 0
    private(set) var disconnectCount = 0

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Never>?

    init(kind: TransportKind) {
        self.kind = kind
    }

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }

    func connect() async throws {
        if shouldFailConnect { throw RinaTransportError.underlying("dial failed") }
        if holdConnect {
            await withCheckedContinuation { connectContinuation = $0 }
        }
        stateContinuation?.yield(.connected)
    }

    func releaseConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func disconnect() {
        disconnectCount += 1
        stateContinuation?.yield(.disconnected)
    }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            if request.type == RinaLinkMessageType.cmd.rawValue { commandCount += 1 }
            if request.type == RinaLinkMessageType.setFrame.rawValue { frameCount += 1 }
            let payload = replyPayload(for: request)
            let delay = replyDelay
            Task { @MainActor [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                self?.emitReply(request, payload: payload)
            }
        }
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
        case .cmd:
            if let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
               object["cmd"] as? String == RinaCommand.getInfo.name {
                var reply: [String: Any] = ["ok": true, "proto": 1]
                if let defaultName { reply["defaultName"] = defaultName }
                return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
            }
            return Data(#"{"ok":true}"#.utf8)
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}

/// A small, fast, seedable PRNG so the walk is reproducible byte-for-byte.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
