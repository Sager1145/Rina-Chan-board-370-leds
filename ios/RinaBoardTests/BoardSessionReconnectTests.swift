import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class BoardSessionReconnectTests: XCTestCase {
    private let identityA = "AAAAAAAAAAAA"
    private let identityB = "BBBBBBBBBBBB"

    private func makeStore() -> BoardSessionStore {
        BoardSessionStore(scanner: ReconnectBLECarrier(), makeBLETransport: { ReconnectBLECarrier() })
    }

    private func connect(_ session: BoardSession, using transport: any RinaTransport) async {
        let connected = await session.connection.connect(using: transport)
        XCTAssertTrue(connected)
    }

    private func candidates(_ session: BoardSession, after kind: TransportKind?, wifi: WifiStatus? = nil) throws -> [BoardReconnectCandidate] {
        let provider = try XCTUnwrap(session.connection.reconnectCandidatesProvider)
        return provider(kind, wifi)
    }

    private func coldStartStore(ble: ReconnectBLECarrier) -> BoardSessionStore {
        BoardSessionStore(scanner: ReconnectBLECarrier(), makeBLETransport: { ble },
                          makeConnection: { BoardConnection(reconnectDelay: { _ in 0.001 }) })
    }

    func testInitialSavedTCPFailureFallsBackToSavedBLEAliasForExpectedBoard() async {
        let ble = ReconnectBLECarrier(identity: identityA)
        let store = coldStartStore(ble: ble)
        let peripheralID = UUID()
        let session = store.session(for: peripheralID.uuidString, name: "A")
        let tcp = ReconnectWire(kind: .wifi(host: "192.168.2.10", port: 3333), identity: identityA)
        tcp.failuresRemaining = 100
        defer { session.connection.disconnect() }

        let first = await session.connection.connect(using: tcp, expectedBoardIdentity: identityA)
        XCTAssertFalse(first)
        XCTAssertNil(session.connection.boardIdentity)
        XCTAssertNil(session.connection.lastKnownBoardIdentity)
        await waitUntilTrue { session.connection.connectionState == .connected }
        XCTAssertEqual(session.connection.transportKind, .bluetooth)
        XCTAssertEqual(session.connection.boardIdentity, identityA)
        XCTAssertEqual(ble.peripheralIdentifier, peripheralID)
        XCTAssertEqual(ble.connectAttempts, 1)
        XCTAssertEqual(tcp.connectAttempts, 1)
    }

    func testInitialTCPFallbackRejectsBLEAdvertisingAnotherPhysicalBoard() async {
        let ble = ReconnectBLECarrier(identity: identityB)
        let store = coldStartStore(ble: ble)
        let session = store.session(for: UUID().uuidString, name: "A")
        let tcp = ReconnectWire(kind: .wifi(host: "192.168.2.10", port: 3333), identity: identityA)
        tcp.failuresRemaining = 100
        defer { session.connection.disconnect() }

        let first = await session.connection.connect(using: tcp, expectedBoardIdentity: identityA)
        XCTAssertFalse(first)
        await waitUntilTrue {
            if case .failed(let message) = session.connection.connectionState {
                return message.contains("最大尝试次数")
            }
            return false
        }
        XCTAssertEqual(ble.connectAttempts, 1)
        XCTAssertNotEqual(session.connection.connectionState, .connected)
        XCTAssertNil(session.connection.boardIdentity)
        XCTAssertNil(session.connection.lastKnownBoardIdentity)
    }

    func testInitialFailureWithoutPinnedIdentityNeverOffersSavedAlias() async {
        let ble = ReconnectBLECarrier(identity: identityA)
        let store = coldStartStore(ble: ble)
        let session = store.session(for: UUID().uuidString, name: "Unknown")
        let tcp = ReconnectWire(kind: .wifi(host: "192.168.2.10", port: 3333), identity: identityA)
        tcp.failuresRemaining = 100
        defer { session.connection.disconnect() }

        let first = await session.connection.connect(using: tcp)
        XCTAssertFalse(first)
        await waitUntilTrue {
            if case .failed(let message) = session.connection.connectionState {
                return message.contains("最大尝试次数")
            }
            return false
        }
        XCTAssertEqual(ble.connectAttempts, 0)
        XCTAssertEqual(tcp.connectAttempts, 6)
    }

    func testNewUnidentifiedTargetDoesNotBorrowPreviousBoardsIdentity() async {
        let ble = ReconnectBLECarrier(identity: identityA)
        let store = coldStartStore(ble: ble)
        let session = store.session(for: UUID().uuidString, name: "A then unknown")
        let connectedA = await session.connection.connect(using:
            ReconnectWire(kind: .wifi(host: "192.168.2.10", port: 3333), identity: identityA))
        XCTAssertTrue(connectedA)
        XCTAssertEqual(session.connection.lastKnownBoardIdentity, identityA)
        let tcpB = ReconnectWire(kind: .wifi(host: "192.168.2.11", port: 3333), identity: identityB)
        tcpB.failuresRemaining = 100
        defer { session.connection.disconnect() }

        let firstB = await session.connection.connect(using: tcpB)
        XCTAssertFalse(firstB)
        XCTAssertNil(session.connection.reconnectCandidateIdentity)
        await waitUntilTrue {
            if case .failed(let message) = session.connection.connectionState {
                return message.contains("最大尝试次数")
            }
            return false
        }
        XCTAssertEqual(ble.connectAttempts, 0)
        XCTAssertEqual(tcpB.connectAttempts, 6)
        tcpB.failuresRemaining = 0
        let retriedB = await session.connection.retryNow()
        XCTAssertTrue(retriedB, "manual retry must not pin the previous board's identity")
        XCTAssertEqual(session.connection.boardIdentity, identityB)
    }

    func testWiFiFailureOffersEachSessionsOwnBLEWithoutSelectingOrTouchingSibling() async throws {
        let store = makeStore()
        let aID = UUID()
        let bID = UUID()
        let a = store.session(for: aID.uuidString, name: "A")
        let b = store.session(for: bID.uuidString, name: "B")
        a.bleTransport.peripheralIdentifier = aID
        b.bleTransport.peripheralIdentifier = bID
        let wireA = ReconnectWire(kind: .wifi(host: "192.168.2.10", port: 3333), identity: identityA)
        let wireB = ReconnectWire(kind: .wifi(host: "192.168.2.11", port: 4444), identity: identityB)
        await connect(a, using: wireA)
        await connect(b, using: wireB)
        store.select(b)
        defer { store.sessions.forEach { $0.connection.disconnect() } }
        let aCandidates = try candidates(a, after: wireA.kind)
        let bCandidates = try candidates(b, after: wireB.kind)
        XCTAssertEqual(aCandidates.count, 1)
        XCTAssertEqual(bCandidates.count, 1)
        XCTAssertTrue(aCandidates[0].transport === a.bleTransport)
        XCTAssertTrue(bCandidates[0].transport === b.bleTransport)
        XCTAssertEqual(aCandidates[0].expectedBoardIdentity, identityA)
        XCTAssertEqual(bCandidates[0].expectedBoardIdentity, identityB)
        XCTAssertEqual(a.bleTransport.peripheralIdentifier, aID)
        XCTAssertEqual(b.bleTransport.peripheralIdentifier, bID)
        XCTAssertTrue(store.active === b)
        XCTAssertEqual(a.boardID, aID.uuidString)
        XCTAssertEqual(b.boardID, bID.uuidString)
        XCTAssertEqual(wireA.disconnectCount, 0)
        XCTAssertEqual(wireB.disconnectCount, 0)
        XCTAssertEqual(b.connection.connectionState, .connected)
    }

    func testBLEFailureOffersOnlyBoardReportedStationEndpointWithExpectedIdentity() async throws {
        let store = makeStore()
        let a = store.session(for: UUID().uuidString, name: "A")
        let b = store.session(for: UUID().uuidString, name: "B")
        let wifiA = WifiStatus(staConnected: true, ip: "192.168.2.10", boardId: identityA, tcpPort: 3333)
        let wifiB = WifiStatus(staConnected: true, ip: "192.168.2.11", boardId: identityB, tcpPort: 4444)
        let wireA = ReconnectWire(kind: .bluetooth, identity: identityA, wifi: wifiA)
        let wireB = ReconnectWire(kind: .bluetooth, identity: identityB, wifi: wifiB)
        await connect(a, using: wireA)
        await connect(b, using: wireB)
        defer { store.sessions.forEach { $0.connection.disconnect() } }
        let active = store.active
        let candidateA = try XCTUnwrap(candidates(a, after: .bluetooth, wifi: a.connection.wifi).first)
        let candidateB = try XCTUnwrap(candidates(b, after: .bluetooth, wifi: b.connection.wifi).first)
        XCTAssertEqual(candidateA.transport.kind, .wifi(host: "192.168.2.10", port: 3333))
        XCTAssertEqual(candidateB.transport.kind, .wifi(host: "192.168.2.11", port: 4444))
        XCTAssertEqual(candidateA.expectedBoardIdentity, identityA)
        XCTAssertEqual(candidateB.expectedBoardIdentity, identityB)
        XCTAssertTrue(store.active === active)
        XCTAssertEqual(wireA.disconnectCount, 0)
        XCTAssertEqual(wireB.disconnectCount, 0)
    }

    func testUnconfiguredZeroOrOtherBoardsStationMetadataNeverCreatesTCPFallback() async throws {
        let store = makeStore()
        let session = store.session(for: UUID().uuidString, name: "A")
        await connect(session, using: ReconnectWire(kind: .bluetooth, identity: identityA))
        defer { session.connection.disconnect() }
        let invalid: [WifiStatus?] = [
            nil,
            WifiStatus(staConnected: false, ip: "192.168.2.10", boardId: identityA),
            WifiStatus(staConnected: true, ip: "0.0.0.0", boardId: identityA),
            WifiStatus(staConnected: true, ip: "192.168.2.999", boardId: identityA),
            WifiStatus(staConnected: true, ip: "192.168.2.10", boardId: identityB),
            WifiStatus(staConnected: true, ip: "192.168.2.10", boardId: identityA, tcpPort: 0),
            WifiStatus(staConnected: true, ip: "192.168.2.10", boardId: identityA, tcpPort: 65536),
            WifiStatus(mode: "ap", staConnected: false, apActive: true, apIp: "10.1.1.1", boardId: identityA)
        ]
        for wifi in invalid {
            XCTAssertTrue(try candidates(session, after: .bluetooth, wifi: wifi).isEmpty,
                          "Unusable station metadata must not trigger a network/SSID association: \(String(describing: wifi))")
        }
        let unknown = store.session(for: UUID().uuidString, name: "Unknown")
        XCTAssertTrue(try candidates(unknown, after: .bluetooth,
            wifi: WifiStatus(staConnected: true, ip: "192.168.2.10", boardId: identityA)).isEmpty,
            "An unverified identity cannot authorize same-board TCP recovery")
    }

    func testPreviouslyVerifiedLocalEndpointSurvivesBLESwitchWithoutSavingPreference() async throws {
        let store = makeStore()
        let session = store.session(for: UUID().uuidString, name: "A")
        let local = ReconnectWire(kind: .wifi(host: "board-a.local", port: 4567), identity: identityA)
        await connect(session, using: local)
        store.consolidateVerifiedSession(session)
        let slot = session.boardID
        await connect(session, using: ReconnectWire(kind: .bluetooth, identity: identityA))
        defer { session.connection.disconnect() }
        let candidate = try XCTUnwrap(candidates(session, after: .bluetooth).first)
        XCTAssertEqual(candidate.transport.kind, .wifi(host: "board-a.local", port: 4567))
        XCTAssertEqual(candidate.expectedBoardIdentity, identityA)
        XCTAssertEqual(session.connection.transportKind, .bluetooth)
        XCTAssertEqual(session.boardID, slot)
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testConsolidatedBLEAliasesAndVerifiedEndpointStayWithSamePhysicalSession() async throws {
        let store = makeStore()
        let bleID = UUID()
        let oldBLE = store.session(for: "ble:\(bleID.uuidString)", name: "A BLE")
        await connect(oldBLE, using: ReconnectWire(kind: .bluetooth, identity: identityA))
        let local = store.session(for: "board-a.local", name: "A LAN")
        await connect(local, using: ReconnectWire(kind: .wifi(host: "board-a.local", port: 4567), identity: identityA))
        let siblingID = UUID()
        let sibling = store.session(for: siblingID.uuidString, name: "B")
        let siblingWire = ReconnectWire(kind: .bluetooth, identity: identityB)
        await connect(sibling, using: siblingWire)
        store.select(sibling)
        store.consolidateVerifiedSession(local)
        defer { store.sessions.forEach { $0.connection.disconnect() } }
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.existingSession(for: "ble:\(bleID.uuidString)") === local)
        let fallback = try XCTUnwrap(candidates(local, after: .wifi(host: "board-a.local", port: 4567)).first)
        XCTAssertTrue(fallback.transport === local.bleTransport)
        XCTAssertEqual(local.bleTransport.peripheralIdentifier, bleID)
        XCTAssertEqual(fallback.expectedBoardIdentity, identityA)
        XCTAssertTrue(store.active === sibling)
        XCTAssertEqual(siblingWire.disconnectCount, 0)
        XCTAssertEqual(sibling.connection.connectionState, .connected)
    }
    func testRetainingBLESessionTransfersOnlyItsVerifiedLocalAliasEndpoint() async throws {
        let store = makeStore()
        let local = store.session(for: "board-a.local", name: "A LAN")
        await connect(local, using: ReconnectWire(kind: .wifi(host: "board-a.local", port: 4567), identity: identityA))
        let ble = store.session(for: UUID().uuidString, name: "A BLE")
        await connect(ble, using: ReconnectWire(kind: .bluetooth, identity: identityA))
        store.consolidateVerifiedSession(ble)
        defer { store.sessions.forEach { $0.connection.disconnect() } }
        XCTAssertEqual(store.sessions.count, 1)
        let fallback = try XCTUnwrap(candidates(ble, after: .bluetooth).first)
        XCTAssertEqual(fallback.transport.kind, .wifi(host: "board-a.local", port: 4567))
        XCTAssertEqual(fallback.expectedBoardIdentity, identityA)
        XCTAssertTrue(store.existingSession(for: "board-a.local") === ble)

        // A subsequent explicit handshake for another physical board must
        // never reuse A's remembered endpoint as an alternate for B.
        await connect(ble, using: ReconnectWire(kind: .bluetooth, identity: identityB))
        XCTAssertTrue(try candidates(ble, after: .bluetooth).isEmpty)
    }

}

@MainActor
private class ReconnectWire: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    let identity: String
    let wifi: WifiStatus?
    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?
    private(set) var disconnectCount = 0
    private(set) var connectAttempts = 0
    var failuresRemaining = 0

    init(kind: TransportKind, identity: String, wifi: WifiStatus? = nil) {
        self.kind = kind
        self.identity = identity
        self.wifi = wifi
    }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws {
        connectAttempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RinaTransportError.underlying("local carrier unavailable")
        }
        stateContinuation?.yield(.connected)
    }
    func disconnect() { disconnectCount += 1; stateContinuation?.yield(.disconnected) }
    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            var payload = Data(#"{"ok":true}"#.utf8)
            if request.type == RinaLinkMessageType.getFrame.rawValue {
                payload = PackedFrame().data
            } else if request.type == RinaLinkMessageType.getStatus.rawValue {
                var reported = wifi ?? WifiStatus()
                reported.boardId = identity
                let object: [String: Any] = ["ok": true,
                    "wifi": try JSONSerialization.jsonObject(with: JSONEncoder().encode(reported))]
                payload = try JSONSerialization.data(withJSONObject: object)
            }
            incomingContinuation?.yield(try RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)))
        }
    }
}

@MainActor
private final class ReconnectBLECarrier: ReconnectWire, BLEConnecting {
    var peripheralIdentifier: UUID?
    var connectingPeripheralID: UUID? { nil }
    var connectedPeripheralID: UUID? { nil }
    var connectedPeripheralName: String? { nil }
    var connectedRSSI: Int? { nil }
    var discoveredPeripherals: [DiscoveredPeripheral] { [] }
    var isScanning = false
    var scanDidTimeOut = false
    var lastError: String?
    init(identity: String = "FFFFFFFFFFFF") { super.init(kind: .bluetooth, identity: identity) }
    func updateConnectedPeripheralName(_ name: String) {}
    func startScan() { isScanning = true }
    func stopScan() { isScanning = false }
}
