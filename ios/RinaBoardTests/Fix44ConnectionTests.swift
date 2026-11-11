import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class Fix44ConnectionTests: XCTestCase {
    private let identity = "AAAAAAAAAAAA"

    // MARK: Keep-alive and output leases

    func testKeepAliveStartedUnderStaleOutputLeaseKeepsHealthyCarrier() async throws {
        let transport = FakeRinaTransport(kind: .wifi(host: "board.local", port: 80))
        let connection = BoardConnection(reconnectDelay: { _ in 0.001 }, pingInterval: 0.02)
        // A lease that is not (or no longer) current, as left behind by a
        // producer whose carrier failed.
        let stale = UUID()
        let connected = await BoardOutputContext.$session.withValue(stale) {
            await connection.connect(using: transport)
        }
        XCTAssertTrue(connected)
        defer { connection.disconnect() }

        let handshakePings = transport.sentCount(type: .ping)
        await waitUntilTrue("keep-alive pings never reached the wire") {
            transport.sentCount(type: .ping) >= handshakePings + 3
        }
        XCTAssertEqual(connection.connectionState, .connected)
        XCTAssertEqual(transport.disconnectCount, 0)
    }

    func testReconnectAfterLeasedWriteFailureDoesNotFlap() async throws {
        let transport = FakeRinaTransport(kind: .wifi(host: "board.local", port: 80))
        let connection = BoardConnection(reconnectDelay: { _ in 0.001 }, pingInterval: 0.05)
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        defer { connection.disconnect() }

        let token = connection.output.begin(.text)
        transport.failNextSend = true
        let leased = Task { @MainActor in
            try await BoardOutputContext.$session.withValue(token) {
                try await connection.send(type: .ping, payload: Data("leased".utf8))
            }
        }
        _ = try? await leased.value

        await waitUntilTrue("the failed write never reset and re-established the carrier") {
            transport.disconnectCount >= 1 && connection.connectionState == .connected
        }
        let drops = transport.disconnectCount
        let pings = transport.sentCount(type: .ping)
        await waitUntilTrue("keep-alive pings never reached the wire") {
            transport.sentCount(type: .ping) >= pings + 3
        }
        XCTAssertEqual(connection.connectionState, .connected)
        XCTAssertEqual(transport.disconnectCount, drops)
    }

    // MARK: Wi-Fi scan

    func testDisconnectEndsScanEventWaitWithoutWaitingForTimeout() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let scan = Task { try await connection.wifiScan(eventTimeout: .seconds(30)) }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "scanning": true])
        // Let the scan reach its event wait before the carrier goes away.
        try await Task.sleep(for: .milliseconds(20))

        let clock = ContinuousClock()
        let start = clock.now
        connection.disconnect(userInitiated: true)
        do {
            _ = try await scan.value
            XCTFail("a disconnected scan must not complete")
        } catch {
            XCTAssertTrue(error is RinaTransportError || error is CancellationError)
        }
        XCTAssertLessThan(clock.now - start, .seconds(5))
        XCTAssertEqual(transport.sentCount(type: .cmd), 1)
    }

    // MARK: Verified local endpoint

    func testOnlyDialableHostsCountAsLocalEndpoints() {
        XCTAssertTrue(BoardSession.isDialableHost("192.168.2.10"))
        XCTAssertTrue(BoardSession.isDialableHost("board-a.local"))
        XCTAssertFalse(BoardSession.isDialableHost(""))
        XCTAssertFalse(BoardSession.isDialableHost("0.0.0.0"))
        XCTAssertFalse(BoardSession.isDialableHost("bonjour:RinaBoard-AAAA._rinalink._tcp.local."))
        XCTAssertFalse(BoardSession.isDialableHost(UUID().uuidString))
        XCTAssertFalse(BoardSession.isDialableHost("ble:\(UUID().uuidString)"))
        XCTAssertFalse(BoardSession.isDialableHost(KnownBoard.hotspotStorageID(ssid: "RinaBoard-AAAA")))
        XCTAssertFalse(BoardSession.isDialableHost("Rina Board"))
    }

    func testBonjourStorageLabelIsNeverOfferedAsTCPReconnectHost() async throws {
        let store = BoardSessionStore(scanner: Fix44BLECarrier(), makeBLETransport: { Fix44BLECarrier() })
        let label = "bonjour:RinaBoard-AAAA._rinalink._tcp.local."
        let session = store.session(for: label, name: "A")
        let overBonjour = await session.connection.connect(
            using: Fix44Wire(kind: .wifi(host: label, port: 3333), identity: identity))
        XCTAssertTrue(overBonjour)
        // A transport switch reads this while the Bonjour link is still up.
        XCTAssertTrue(session.knownIdentifiers.contains(label))
        let overBLE = await session.connection.connect(using: Fix44Wire(kind: .bluetooth, identity: identity))
        XCTAssertTrue(overBLE)
        defer { session.connection.disconnect() }

        let provider = try XCTUnwrap(session.connection.reconnectCandidatesProvider)
        XCTAssertTrue(provider(.bluetooth, nil).isEmpty)
    }

    // MARK: Error frames

    func testErrorBodyWithoutOkDecodesAsFailure() throws {
        let decoded = try JSONDecoder().decode(
            RinaLinkError.self, from: Data(#"{"error":"busy","code":409,"expectedOffset":12}"#.utf8))
        XCTAssertEqual(decoded, RinaLinkError(ok: false, error: "busy", code: 409, expectedOffset: 12))

        let explicit = try JSONDecoder().decode(
            RinaLinkError.self, from: Data(#"{"ok":false,"error":"bad"}"#.utf8))
        XCTAssertEqual(explicit, RinaLinkError(error: "bad"))

        let encoded = try JSONEncoder().encode(RinaLinkError(error: "busy", code: 409))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "busy")
        XCTAssertEqual(object["code"] as? Int, 409)
        XCTAssertEqual(try JSONDecoder().decode(RinaLinkError.self, from: encoded),
                       RinaLinkError(error: "busy", code: 409))
    }

    func testErrorFrameWithoutOkSurfacesBoardMessage() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        defer { connection.disconnect() }
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false

        let request = Task { @MainActor in
            try await connection.send(type: .ping, payload: Data())
        }
        try await transport.waitForSent(type: .ping, count: 1)
        let seq = try XCTUnwrap(transport.lastSent(type: .ping)?.seq)
        transport.emitInOneRead([
            RinaLinkFrame(type: .error, seq: seq, payload: Data(#"{"error":"busy","code":409}"#.utf8))
        ])
        do {
            _ = try await request.value
            XCTFail("an error frame must fail the request")
        } catch let error as RinaLinkError {
            XCTAssertEqual(error.error, "busy")
            XCTAssertEqual(error.code, 409)
            XCTAssertFalse(error.ok)
        }
    }
}

@MainActor
private class Fix44Wire: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    let identity: String
    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    init(kind: TransportKind, identity: String) {
        self.kind = kind
        self.identity = identity
    }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }
    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            var payload = Data(#"{"ok":true}"#.utf8)
            if request.type == RinaLinkMessageType.getFrame.rawValue {
                payload = PackedFrame().data
            } else if request.type == RinaLinkMessageType.getStatus.rawValue {
                var reported = WifiStatus()
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
private final class Fix44BLECarrier: Fix44Wire, BLEConnecting {
    var peripheralIdentifier: UUID?
    var connectingPeripheralID: UUID? { nil }
    var connectedPeripheralID: UUID? { nil }
    var connectedPeripheralName: String? { nil }
    var connectedRSSI: Int? { nil }
    var discoveredPeripherals: [DiscoveredPeripheral] { [] }
    var isScanning = false
    var scanDidTimeOut = false
    var lastError: String?
    init() { super.init(kind: .bluetooth, identity: "FFFFFFFFFFFF") }
    func updateConnectedPeripheralName(_ name: String) {}
    func startScan() { isScanning = true }
    func stopScan() { isScanning = false }
}
