import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class ConnectionTransportSelectionTests: XCTestCase {
    func testWiFiThenBluetoothSwitchKeepsOtherBoardAndSessionAliases() async throws {
        let sessions = BoardSessionStore(scanner: SelectionBLE(), makeBLETransport: { SelectionBLE() })
        let boardID = UUID().uuidString
        let selected = sessions.session(for: boardID, name: "A")
        selected.bleTransport.peripheralIdentifier = UUID(uuidString: boardID)
        let other = sessions.session(for: UUID().uuidString, name: "B")
        sessions.select(selected)
        let initial = FakeRinaTransport()
        initial.commandReply = ["ok": true, "defaultName": "RinaBoard-AAAAAAAAAAAA"]
        let otherWire = FakeRinaTransport()
        _ = await selected.connection.connect(using: initial)
        _ = await other.connection.connect(using: otherWire)
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        initial.emitEvent(type: .evWifi, json: ["staConnected": true, "ip": "192.168.1.42", "ssid": "Home"])
        try await waitUntil { selected.connection.wifi?.ip == "192.168.1.42" }
        let suite = "ConnectionTransportSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let boards = BoardStore(defaults: defaults)
        boards.upsert(KnownBoard(id: boardID, name: "A"))
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let wifiWire = FakeRinaTransport(kind: .wifi(host: "192.168.1.42", port: RinaLinkConstants.tcpPort))
        wifiWire.commandReply = initial.commandReply
        let untouched = otherWire.disconnectCount

        await model.selectTransport(.wifi, sessions: sessions, boardStore: boards,
                                    connectTransport: { target, _, expected in
            await target.connection.connect(using: wifiWire, expectedBoardIdentity: expected)
        })

        XCTAssertTrue(sessions.active === selected)
        XCTAssertTrue(sessions.existingSession(for: "192.168.1.42") === selected)
        XCTAssertEqual(boards.boards.first { $0.id == boardID }?.preferredTransport, "wifi")
        XCTAssertEqual(boards.boards.first { $0.id == boardID }?.lastHost, "192.168.1.42")
        XCTAssertEqual(otherWire.disconnectCount, untouched)
        XCTAssertEqual(other.connection.connectionState, .connected)
        XCTAssertEqual(selected.connection.boardIdentity, "AAAAAAAAAAAA")

        let bleWire = FakeRinaTransport()
        bleWire.commandReply = initial.commandReply
        await model.selectTransport(.bluetooth, sessions: sessions, boardStore: boards,
                                    connectTransport: { target, transport, expected in
            XCTAssertTrue(transport === selected.bleTransport)
            return await target.connection.connect(using: bleWire, expectedBoardIdentity: expected)
        })

        XCTAssertTrue(sessions.active === selected)
        XCTAssertTrue(sessions.existingSession(for: "192.168.1.42") === selected)
        XCTAssertTrue(sessions.existingSession(for: boardID) === selected)
        XCTAssertEqual(boards.boards.first { $0.id == boardID }?.preferredTransport, "bluetooth")
        XCTAssertEqual(otherWire.disconnectCount, untouched)
        XCTAssertEqual(other.connection.connectionState, .connected)
        XCTAssertEqual(selected.connection.boardIdentity, "AAAAAAAAAAAA")
    }

    func testSelectionChangeDuringTransportSwitchIsNotOverridden() async throws {
        let sessions = BoardSessionStore(scanner: SelectionBLE(), makeBLETransport: { SelectionBLE() })
        let selected = sessions.session(for: UUID().uuidString, name: "A")
        let other = sessions.session(for: UUID().uuidString, name: "B")
        sessions.select(selected)
        let oldWire = FakeRinaTransport(kind: .wifi(host: "board.local", port: 80))
        _ = await selected.connection.connect(using: oldWire)
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let suite = "ConnectionTransportSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let boards = BoardStore(defaults: defaults)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let newWire = FakeRinaTransport(connectImmediately: false)
        let task = Task { @MainActor in
            await model.selectTransport(.bluetooth, sessions: sessions, boardStore: boards,
                                        connectTransport: { target, _, expected in
                await target.connection.connect(using: newWire, expectedBoardIdentity: expected)
            })
        }
        try await newWire.waitForConnectStarted()
        sessions.select(other)
        newWire.completeDeferredConnect()
        await task.value
        XCTAssertTrue(sessions.active === other)
        XCTAssertEqual(selected.connection.connectionState, .connected)
        XCTAssertFalse(model.isSwitchingTransport)
    }

    func testBoardWifiModesRefreshReportedModeWithoutChangingCarrier() async {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        _ = await connection.connect(using: transport)
        defer { connection.disconnect() }
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let disconnects = transport.disconnectCount
        for mode in ["off", "ap", "sta", "sta_or_ap"] {
            transport.commandReply = ["ok": true, "mode": mode]
            await model.setMode(mode, connection: connection)
            XCTAssertEqual(connection.wifi?.mode, mode)
            XCTAssertEqual(connection.transportKind, .bluetooth)
            XCTAssertEqual(transport.disconnectCount, disconnects)
            XCTAssertFalse(model.isApplyingWifiMode)
        }
    }

    func testWrongBoardAtCachedWifiHostCannotReplaceSelectedBoardIdentityOrAliases() async throws {
        let sessions = BoardSessionStore(scanner: SelectionBLE(), makeBLETransport: { SelectionBLE() })
        let boardID = UUID().uuidString
        let selected = sessions.session(for: boardID, name: "A")
        let other = sessions.session(for: UUID().uuidString, name: "B")
        sessions.select(selected)
        let originalWire = FakeRinaTransport()
        originalWire.commandReply = ["ok": true, "name": "A", "defaultName": "RinaBoard-AAAAAAAAAAAA"]
        let otherWire = FakeRinaTransport()
        otherWire.commandReply = ["ok": true, "name": "B", "defaultName": "RinaBoard-BBBBBBBBBBBB"]
        _ = await selected.connection.connect(using: originalWire)
        _ = await other.connection.connect(using: otherWire)
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let suite = "ConnectionTransportSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let boards = BoardStore(defaults: defaults)
        let saved = KnownBoard(id: boardID, name: "A", preferredTransport: "bluetooth", lastHost: "reused.local")
        boards.upsert(saved)
        let wrongWire = FakeRinaTransport(kind: .wifi(host: "reused.local", port: RinaLinkConstants.tcpPort),
                                          connectImmediately: false)
        wrongWire.commandReply = otherWire.commandReply
        let siblingDisconnects = otherWire.disconnectCount
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let switchTask = Task { @MainActor in
            await model.selectTransport(.wifi, sessions: sessions, boardStore: boards,
                                        connectTransport: { target, _, expected in
                await target.connection.connect(using: wrongWire, expectedBoardIdentity: expected)
            })
        }
        try await wrongWire.waitForConnectStarted()
        // UI lookups occur during the handshake; they must not record an
        // unverified candidate address as an alias of the selected board.
        XCTAssertFalse(selected.knownIdentifiers.contains("reused.local"))
        XCTAssertNil(sessions.existingSession(for: "reused.local"))
        wrongWire.completeDeferredConnect()
        await switchTask.value

        XCTAssertTrue(sessions.active === selected)
        XCTAssertEqual(selected.connection.lastKnownBoardIdentity, "AAAAAAAAAAAA")
        XCTAssertNil(selected.connection.boardIdentity)
        XCTAssertFalse(selected.knownIdentifiers.contains("reused.local"))
        XCTAssertNil(sessions.existingSession(for: "reused.local"))
        XCTAssertEqual(boards.boards, [saved])
        XCTAssertNotNil(model.lastErrorMessage)
        if case .failed = selected.connection.connectionState {} else { XCTFail("wrong identity must stop this dial") }
        XCTAssertGreaterThan(wrongWire.disconnectCount, 0)
        XCTAssertEqual(other.connection.boardIdentity, "BBBBBBBBBBBB")
        XCTAssertEqual(other.connection.connectionState, .connected)
        XCTAssertEqual(otherWire.disconnectCount, siblingDisconnects)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private final class SelectionBLE: BLEConnecting {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 180
    var peripheralIdentifier: UUID?
    var connectingPeripheralID: UUID? { nil }
    var connectedPeripheralID: UUID? { nil }
    var connectedPeripheralName: String? { nil }
    var connectedRSSI: Int? { nil }
    var discoveredPeripherals: [DiscoveredPeripheral] { [] }
    var isScanning = false
    var scanDidTimeOut = false
    var lastError: String?
    func updateConnectedPeripheralName(_ name: String) {}
    func startScan() { isScanning = true }
    func stopScan() { isScanning = false }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { _ in } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { _ in } }
    func connect() async throws {}
    func disconnect() {}
    func send(_ data: Data) async throws {}
}
