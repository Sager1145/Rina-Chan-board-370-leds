import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class BoardSessionStoreTests: XCTestCase {
    func testSavedBoardSwitchReusesOnlineSessionWithoutConnectingAgain() async throws {
        let store = BoardSessionStore()
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let first = store.session(for: firstID, name: "A")
        let second = store.session(for: secondID, name: "B")
        let firstTransport = SessionTransport(kind: .bluetooth)
        let secondTransport = SessionTransport(kind: .bluetooth)
        defer {
            first.connection.disconnect()
            second.connection.disconnect()
        }
        _ = await first.connection.connect(using: firstTransport)
        _ = await second.connection.connect(using: secondTransport)
        store.select(second)
        let firstCommands = firstTransport.commandCount
        let secondCommands = secondTransport.commandCount
        let suiteName = "BoardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boards = BoardStore(defaults: defaults)
        let board = KnownBoard(id: firstID, name: "A")
        boards.upsert(board)
        let model = ConnectionViewModel()

        await model.connectSavedBoard(
            board, sessions: store, boardStore: boards,
            joinBoardHotspot: { _ in XCTFail("Online BLE must not join Wi-Fi"); return "" },
            connectTransport: { _, _ in XCTFail("Online board must not reconnect"); return false }
        )

        XCTAssertTrue(store.active === first)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions.filter { $0.connection.connectionState == .connected }.count, 2)
        XCTAssertEqual(first.boardID, firstID)
        XCTAssertEqual(second.boardID, secondID)
        XCTAssertEqual(firstTransport.disconnectCount, 0)
        XCTAssertEqual(secondTransport.disconnectCount, 0)
        XCTAssertEqual(firstTransport.commandCount, firstCommands)
        XCTAssertEqual(secondTransport.commandCount, secondCommands)
        _ = try await store.active.connection.command(.button(button: "B1"))
        XCTAssertEqual(firstTransport.commandCount, firstCommands + 1)
        XCTAssertEqual(secondTransport.commandCount, secondCommands)
    }

    func testSavedBoardSwitchKeepsIdentitiesForReselectAndForget() async throws {
        let store = BoardSessionStore()
        let oldID = UUID().uuidString
        let newID = UUID().uuidString
        let old = store.session(for: oldID, name: "Old")
        let oldTransport = SessionTransport(kind: .bluetooth)
        let newTransport = SessionTransport(kind: .bluetooth)
        defer { store.sessions.forEach { $0.connection.disconnect() } }
        _ = await old.connection.connect(using: oldTransport)
        let suiteName = "BoardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boards = BoardStore(defaults: defaults)
        let oldBoard = KnownBoard(id: oldID, name: "Old")
        let newBoard = KnownBoard(id: newID, name: "New")
        boards.upsert(oldBoard)
        boards.upsert(newBoard)
        let model = ConnectionViewModel()
        var connectionAttempts = 0

        await model.connectSavedBoard(
            newBoard, sessions: store, boardStore: boards,
            joinBoardHotspot: { _ in XCTFail("BLE must not join Wi-Fi"); return "" },
            connectTransport: { target, transport in
                connectionAttempts += 1
                XCTAssertFalse(target === old)
                XCTAssertTrue(transport === target.bleTransport)
                XCTAssertEqual(target.bleTransport.peripheralIdentifier?.uuidString, newID)
                return await target.connection.connect(using: newTransport)
            }
        )

        let new = try XCTUnwrap(store.existingSession(for: newID))
        XCTAssertTrue(store.active === new)
        XCTAssertEqual(connectionAttempts, 1)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.existingSession(for: oldID) === old)
        XCTAssertEqual(old.boardID, oldID)
        XCTAssertEqual(new.boardID, newID)
        XCTAssertEqual(oldTransport.disconnectCount, 0)
        await model.connectSavedBoard(oldBoard, sessions: store, boardStore: boards)
        XCTAssertTrue(store.active === old)
        await model.connectSavedBoard(newBoard, sessions: store, boardStore: boards)
        XCTAssertTrue(store.active === new)

        store.remove(id: oldID)
        boards.remove(id: oldID)
        XCTAssertEqual(old.connection.connectionState, .disconnected)
        XCTAssertEqual(new.connection.connectionState, .connected)
        XCTAssertEqual(newTransport.disconnectCount, 0)
        XCTAssertTrue(store.active === new)
        XCTAssertNil(store.existingSession(for: oldID))
    }

    func testSavedHotspotSwitchReusesDirectJoinSessionBySSID() async throws {
        let store = BoardSessionStore()
        let direct = store.session(for: RinaLinkConstants.apIP, name: "Direct hotspot")
        let transport = SessionTransport(kind: .hotspot)
        transport.hotspotBoardID = "AABBCCDDEEFF"
        defer { direct.connection.disconnect() }
        let ssid = "RinaChanBoard-AABBCCDDEEFF"
        direct.connection.expectedHotspotSSID = ssid
        let connected = await direct.connection.connect(using: transport)
        XCTAssertTrue(connected)
        let other = store.session(for: UUID().uuidString, name: "BLE")
        store.select(other)
        let suiteName = "BoardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boards = BoardStore(defaults: defaults)
        let board = KnownBoard(id: KnownBoard.hotspotStorageID(ssid: ssid), name: "Hotspot",
                               preferredTransport: "hotspot", lastHost: RinaLinkConstants.apIP,
                               hotspotSSID: ssid)
        boards.upsert(board)

        await ConnectionViewModel().connectSavedBoard(
            board, sessions: store, boardStore: boards,
            joinBoardHotspot: { _ in XCTFail("Connected hotspot must not rejoin"); return ssid },
            connectTransport: { _, _ in XCTFail("Connected hotspot must not reconnect"); return false }
        )

        XCTAssertTrue(store.active === direct)
        XCTAssertTrue(store.existingSession(for: board.id) === direct)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(transport.disconnectCount, 0)
        XCTAssertNil(store.existingSession(for: KnownBoard.hotspotStorageID(ssid: "RinaChanBoard-112233445566")))
    }

    func testDirectHotspotJoinOnOtherBoardDoesNotRepointOfflineSession() async throws {
        let store = BoardSessionStore()
        let ssidA = "RinaChanBoard-AAAAAAAAAAAA"
        let ssidB = "RinaChanBoard-BBBBBBBBBBBB"
        let idA = KnownBoard.hotspotStorageID(ssid: ssidA)
        let idB = KnownBoard.hotspotStorageID(ssid: ssidB)
        let sessionA = store.session(for: idA, name: "A")
        let transportA = SessionTransport(kind: .hotspot)
        transportA.hotspotBoardID = "AAAAAAAAAAAA"
        sessionA.connection.expectedHotspotSSID = ssidA
        let connectedA = await sessionA.connection.connect(using: transportA)
        XCTAssertTrue(connectedA)
        sessionA.connection.disconnect()
        XCTAssertEqual(sessionA.connection.transportKind, .hotspot)
        defer { store.sessions.forEach { $0.connection.disconnect() } }
        let suiteName = "BoardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boards = BoardStore(defaults: defaults)
        boards.upsert(KnownBoard(id: idA, name: "A", preferredTransport: "hotspot",
                                 lastHost: RinaLinkConstants.apIP, hotspotSSID: ssidA))
        let transportB = SessionTransport(kind: .hotspot)
        transportB.hotspotBoardID = "BBBBBBBBBBBB"
        let model = ConnectionViewModel()

        await model.connectHotspot(
            sessions: store, boardStore: boards,
            joinBoardHotspot: { ssidB },
            connectTransport: { target, _ in
                XCTAssertFalse(target === sessionA)
                return await target.connection.connect(using: transportB)
            }
        )

        let sessionB = try XCTUnwrap(store.existingSession(for: idB))
        XCTAssertFalse(sessionB === sessionA)
        XCTAssertTrue(store.active === sessionB)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(sessionB.connection.connectionState, .connected)
        XCTAssertEqual(sessionB.boardID, idB)
        XCTAssertEqual(sessionA.boardID, idA)
        XCTAssertEqual(sessionA.name, "A")
        XCTAssertEqual(sessionA.connection.connectionState, .disconnected)
        XCTAssertEqual(sessionA.connection.expectedHotspotSSID, ssidA)
        // Lookup is first-match and A comes first, so these also prove A did
        // not pick up B's SSID alias (and B has no alias of A, checked below).
        XCTAssertTrue(store.existingSession(for: idA) === sessionA)
        XCTAssertTrue(boards.boards.contains { $0.id == idB })

        store.remove(id: idA)
        boards.remove(id: idA)
        XCTAssertNil(store.existingSession(for: idA))
        XCTAssertTrue(store.existingSession(for: idB) === sessionB)
        XCTAssertTrue(store.active === sessionB)
        XCTAssertEqual(sessionB.connection.connectionState, .connected)
        XCTAssertEqual(transportB.disconnectCount, 0)
    }

    func testDirectHotspotJoinDoesNotConsumeActiveBLEBoardSession() async throws {
        let store = BoardSessionStore()
        let bleID = UUID().uuidString
        let bleSession = store.session(for: bleID, name: "BLE board A")
        let bleTransport = SessionTransport(kind: .bluetooth)
        let bleConnected = await bleSession.connection.connect(using: bleTransport)
        XCTAssertTrue(bleConnected)
        store.select(bleSession)
        defer { store.sessions.forEach { $0.connection.disconnect() } }

        let suiteName = "BoardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boards = BoardStore(defaults: defaults)
        let hotspotSSID = "RinaChanBoard-BBBBBBBBBBBB"
        let hotspotID = KnownBoard.hotspotStorageID(ssid: hotspotSSID)
        let hotspotTransport = SessionTransport(kind: .hotspot)
        hotspotTransport.hotspotBoardID = "BBBBBBBBBBBB"

        await ConnectionViewModel().connectHotspot(
            sessions: store,
            boardStore: boards,
            joinBoardHotspot: { hotspotSSID },
            connectTransport: { target, transport in
                XCTAssertFalse(target === bleSession)
                XCTAssertEqual(transport.kind, .hotspot)
                return await target.connection.connect(using: hotspotTransport)
            }
        )

        let hotspotSession = try XCTUnwrap(store.existingSession(for: hotspotID))
        XCTAssertFalse(hotspotSession === bleSession)
        XCTAssertTrue(store.active === hotspotSession)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(bleSession.boardID, bleID)
        XCTAssertEqual(hotspotSession.boardID, hotspotID)
        XCTAssertEqual(bleSession.connection.connectionState, .connected)
        XCTAssertEqual(hotspotSession.connection.connectionState, .connected)
        XCTAssertEqual(bleTransport.disconnectCount, 0)

        let bleCommands = bleTransport.commandCount
        let hotspotCommands = hotspotTransport.commandCount
        _ = try await bleSession.connection.command(.button(button: "B1"))
        _ = try await hotspotSession.connection.command(.button(button: "B2"))
        XCTAssertEqual(bleTransport.commandCount, bleCommands + 1)
        XCTAssertEqual(hotspotTransport.commandCount, hotspotCommands + 1)
    }

    func testDirectHotspotJoinDoesNotReuseLegacySharedIPSessionForUniqueBoard() async throws {
        let store = BoardSessionStore()
        let legacy = store.session(for: RinaLinkConstants.apIP, name: "Legacy hotspot")
        let legacyTransport = SessionTransport(kind: .hotspot)
        legacy.connection.expectedHotspotSSID = RinaLinkConstants.apSSID
        let legacyConnected = await legacy.connection.connect(using: legacyTransport)
        XCTAssertTrue(legacyConnected)
        legacy.connection.disconnect()
        XCTAssertEqual(legacy.connection.transportKind, .hotspot)
        defer { store.sessions.forEach { $0.connection.disconnect() } }

        let suiteName = "BoardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boards = BoardStore(defaults: defaults)
        let joinedSSID = "RinaChanBoard-CCCCCCCCCCCC"
        let joinedID = KnownBoard.hotspotStorageID(ssid: joinedSSID)
        let joinedTransport = SessionTransport(kind: .hotspot)
        joinedTransport.hotspotBoardID = "CCCCCCCCCCCC"

        await ConnectionViewModel().connectHotspot(
            sessions: store,
            boardStore: boards,
            joinBoardHotspot: { joinedSSID },
            connectTransport: { target, _ in
                XCTAssertFalse(target === legacy)
                return await target.connection.connect(using: joinedTransport)
            }
        )

        let joined = try XCTUnwrap(store.existingSession(for: joinedID))
        XCTAssertFalse(joined === legacy)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(legacy.boardID, RinaLinkConstants.apIP)
        XCTAssertEqual(legacy.connection.expectedHotspotSSID, RinaLinkConstants.apSSID)
        XCTAssertEqual(legacy.connection.connectionState, .disconnected)
        XCTAssertTrue(store.existingSession(for: RinaLinkConstants.apIP) === legacy)
        XCTAssertTrue(store.active === joined)
        XCTAssertEqual(joined.boardID, joinedID)
        XCTAssertEqual(joined.connection.expectedHotspotSSID, joinedSSID)
        XCTAssertEqual(joined.connection.connectionState, .connected)
    }

    func testDirectHotspotJoinOnSameBoardReusesOfflineSession() async throws {
        let store = BoardSessionStore()
        let ssid = "RinaChanBoard-AAAAAAAAAAAA"
        let id = KnownBoard.hotspotStorageID(ssid: ssid)
        let session = store.session(for: id, name: "A")
        let first = SessionTransport(kind: .hotspot)
        first.hotspotBoardID = "AAAAAAAAAAAA"
        session.connection.expectedHotspotSSID = ssid
        _ = await session.connection.connect(using: first)
        session.connection.disconnect()
        defer { session.connection.disconnect() }
        let suiteName = "BoardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let boards = BoardStore(defaults: defaults)
        let second = SessionTransport(kind: .hotspot)
        second.hotspotBoardID = "AAAAAAAAAAAA"

        await ConnectionViewModel().connectHotspot(
            sessions: store, boardStore: boards,
            joinBoardHotspot: { ssid },
            connectTransport: { target, _ in await target.connection.connect(using: second) }
        )

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(store.active === session)
        XCTAssertEqual(session.name, "A")
        XCTAssertEqual(session.connection.connectionState, .connected)
    }

    func testAutomaticReconnectDoesNotReplaceManualSelectionDuringLaunchRestore() {
        let store = BoardSessionStore()
        let launchSession = store.active
        let manualSelection = store.session(for: "manual.local", name: "Manual")
        store.select(manualSelection)

        let automatic = store.sessionForAutomaticReconnect(
            id: "latest.local",
            name: "Latest",
            ifCurrent: launchSession,
            withBoardID: nil
        )

        XCTAssertNil(automatic)
        XCTAssertTrue(store.active === manualSelection)
        XCTAssertNil(store.existingSession(for: "latest.local"))
    }

    func testAutomaticReconnectReusesInitialSessionWhenSelectionIsUnchanged() {
        let store = BoardSessionStore()
        let launchSession = store.active

        let automatic = store.sessionForAutomaticReconnect(
            id: "latest.local",
            name: "Latest",
            ifCurrent: launchSession,
            withBoardID: nil
        )

        XCTAssertTrue(automatic === launchSession)
        XCTAssertTrue(store.active === launchSession)
        XCTAssertEqual(store.active.boardID, "latest.local")
    }

    func testSessionsConnectAndRouteCommandsIndependently() async throws {
        let store = BoardSessionStore()
        let first = store.session(for: "first.local", name: "First")
        let second = store.session(for: "second.local", name: "Second")
        let firstTransport = SessionTransport(host: "first.local")
        let secondTransport = SessionTransport(host: "second.local")
        defer { second.connection.disconnect() }

        async let firstConnection = first.connection.connect(using: firstTransport)
        async let secondConnection = second.connection.connect(using: secondTransport)
        let (firstConnected, secondConnected) = await (firstConnection, secondConnection)
        XCTAssertTrue(firstConnected)
        XCTAssertTrue(secondConnected)
        let firstCommands = firstTransport.commandCount
        let secondCommands = secondTransport.commandCount

        _ = try await first.connection.command(.pauseScroll)
        _ = try await second.connection.command(.resumeScroll)

        XCTAssertEqual(firstTransport.commandCount, firstCommands + 1)
        XCTAssertEqual(secondTransport.commandCount, secondCommands + 1)

        store.remove(id: "first.local")
        XCTAssertEqual(first.connection.connectionState, .disconnected)
        XCTAssertEqual(second.connection.connectionState, .connected)
        XCTAssertEqual(firstTransport.disconnectCount, 1)
        XCTAssertEqual(secondTransport.disconnectCount, 0)
        XCTAssertTrue(store.active === second)

        let commandsAfterRemoval = secondTransport.commandCount
        _ = try await second.connection.command(.pauseScroll)
        XCTAssertEqual(secondTransport.commandCount, commandsAfterRemoval + 1)
    }

    func testSessionLookupRetainsTransportAliasesAndSelectDoesNotDisconnect() async {
        let store = BoardSessionStore()
        let session = store.session(for: "saved-name", name: "Board")
        let transport = SessionTransport(host: "192.168.4.1")
        defer { session.connection.disconnect() }
        let connected = await session.connection.connect(using: transport)
        XCTAssertTrue(connected)

        let reused = store.session(for: "192.168.4.1", name: "Renamed")
        XCTAssertTrue(reused === session)
        XCTAssertTrue(store.existingSession(for: "saved-name") === session)
        XCTAssertTrue(store.existingSession(for: "192.168.4.1") === session)
        XCTAssertEqual(session.name, "Renamed")

        let other = store.session(for: "other.local", name: "Other")
        let lease = session.connection.output.begin(.manual)
        store.select(session)
        XCTAssertTrue(session.connection.output.isCurrent(lease))
        store.select(other)
        XCTAssertNil(session.connection.output.session)
        XCTAssertEqual(transport.disconnectCount, 0)
    }

    func testTransportFailureDoesNotDisconnectAnotherSession() async {
        let store = BoardSessionStore()
        let first = store.session(for: "first.local", name: "First")
        let second = store.session(for: "second.local", name: "Second")
        let firstTransport = SessionTransport(host: "first.local")
        let secondTransport = SessionTransport(host: "second.local")
        defer {
            first.connection.disconnect()
            second.connection.disconnect()
        }

        async let firstConnection = first.connection.connect(using: firstTransport)
        async let secondConnection = second.connection.connect(using: secondTransport)
        _ = await (firstConnection, secondConnection)
        firstTransport.fail("link lost")

        for _ in 0..<20 where first.connection.connectionState == .connected {
            await Task.yield()
        }
        XCTAssertNotEqual(first.connection.connectionState, .connected)
        XCTAssertEqual(second.connection.connectionState, .connected)
        XCTAssertEqual(secondTransport.disconnectCount, 0)
    }
}

@MainActor
private final class SessionTransport: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?
    var hotspotBoardID: String?
    private(set) var commandCount = 0
    private(set) var disconnectCount = 0

    init(host: String) {
        self.kind = .wifi(host: host, port: RinaLinkConstants.tcpPort)
    }

    init(kind: TransportKind) {
        self.kind = kind
    }

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
        disconnectCount += 1
        stateContinuation?.yield(.disconnected)
    }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            if request.type == RinaLinkMessageType.cmd.rawValue { commandCount += 1 }
            var reply: [String: Any] = ["ok": true]
            if request.type == RinaLinkMessageType.getStatus.rawValue, let hotspotBoardID {
                reply["wifi"] = ["boardId": hotspotBoardID]
            }
            let payload = try! JSONSerialization.data(withJSONObject: reply)
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
            ))
        }
    }

    func fail(_ message: String) {
        stateContinuation?.yield(.failed(message))
    }
}
