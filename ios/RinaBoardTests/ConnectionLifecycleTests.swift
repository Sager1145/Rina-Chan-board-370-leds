import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    func testThrowWithoutStateEventRetriesAndEventuallyConnects() async throws {
        let wire = LifecycleTransport(failures: 2)
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        var readyCount = 0
        let first = await board.connect(using: wire) { readyCount += 1 }
        XCTAssertFalse(first)
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(board.lastError, "GATT discovery failed")
        await waitUntilTrue { board.connectionState == .connected }
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(wire.attempts, 3)
        XCTAssertNil(board.lastError)
        XCTAssertEqual(wire.pings, 1)
        board.disconnect()
    }

    func testFailedHandshakeClosesCarrierAndNeverPublishesConnected() async throws {
        let wire = LifecycleTransport()
        wire.replyToPing = false
        let board = BoardConnection(reconnectDelay: { _ in 10 }, handshakeTimeout: 0.02)
        let task = Task { await board.connect(using: wire) }
        await waitUntilTrue { wire.pings == 1 }
        XCTAssertEqual(board.connectionState, .connecting)
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertGreaterThan(wire.disconnects, 0)
        XCTAssertNotNil(board.lastError)
        board.disconnect()
    }

    func testDeviceNameReadFinishesBeforeConnectedIsPublished() async throws {
        let wire = LifecycleTransport()
        wire.holdGetInfo = true
        let board = BoardConnection()
        var readyCount = 0

        let task = Task { await board.connect(using: wire) { readyCount += 1 } }
        await waitUntilTrue { wire.heldGetInfo != nil }

        XCTAssertEqual(board.connectionState, .connecting)
        XCTAssertEqual(readyCount, 0)
        wire.releaseGetInfo()
        let connected = await task.value
        XCTAssertTrue(connected)
        XCTAssertEqual(board.connectionState, .connected)
        XCTAssertEqual(readyCount, 1)
        board.disconnect()
    }

    func testRetryLimitAlsoAppliesToThrownErrors() async throws {
        let wire = LifecycleTransport(failures: 100)
        let board = BoardConnection(reconnectDelay: { _ in 0.001 })
        _ = await board.connect(using: wire)
        await waitUntilTrue {
            if case .failed = board.connectionState { return true }
            return false
        }
        XCTAssertEqual(wire.attempts, 6, "Initial attempt plus five retries")
        XCTAssertEqual(board.lastError, "GATT discovery failed")
        board.disconnect()
    }

    func testDisconnectCancelsScheduledRetry() async throws {
        let wire = LifecycleTransport(failures: 100)
        let board = BoardConnection(reconnectDelay: { _ in 0.02 })
        _ = await board.connect(using: wire)
        board.disconnect()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(wire.attempts, 1)
        XCTAssertEqual(board.connectionState, .disconnected)
    }

    func testOldCallbacksCannotDisconnectReplacement() async throws {
        let old = LifecycleTransport()
        let replacement = LifecycleTransport()
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        _ = await board.connect(using: old)
        _ = await board.connect(using: replacement)
        old.emit(.failed("stale callback"))
        old.emit(.connected)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(board.connectionState, .connected)
        XCTAssertEqual(replacement.attempts, 1)
        XCTAssertNil(board.lastError)
        board.disconnect()
    }

    func testCancelledHandshakeStopsWithoutSchedulingRetry() async throws {
        let wire = LifecycleTransport()
        wire.replyToPing = false
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        var readyCount = 0
        let task = Task { await board.connect(using: wire) { readyCount += 1 } }
        await waitUntilTrue { wire.pings == 1 }
        task.cancel()
        let connected = await task.value
        XCTAssertFalse(connected)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(wire.attempts, 1)
        XCTAssertEqual(board.connectionState, .disconnected)
        XCTAssertEqual(readyCount, 0)
    }

    func testReconnectResetsPartialFrameAndIgnoresSameTransportOldStream() async throws {
        let wire = LifecycleTransport()
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        _ = await board.connect(using: wire)
        let oldStates = wire.savedStateEmitter()
        // A plausible maximum-size header from the severed link must not
        // consume the next link's handshake as its missing payload.
        wire.receive(Data([0xA5, 0x81, 1, 0, 0, 0x10]))
        wire.emit(.disconnected)
        await waitUntilTrue { wire.attempts == 2 && board.connectionState == .connected }
        oldStates(.failed("old attempt"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(wire.attempts, 2)
        XCTAssertEqual(board.connectionState, .connected)
        board.disconnect()
    }

    func testConnectAndSwitchReadSnapshotWithoutUnsolicitedEvents() async throws {
        let board = BoardConnection()
        let first = LifecycleTransport()
        first.mode = "auto"
        first.displayFrame.set(12)
        let connected = await board.connect(using: first)
        XCTAssertTrue(connected)
        XCTAssertEqual(board.status?.renderer?.mode, "auto")
        XCTAssertEqual(board.preview?.mode, "auto")
        XCTAssertEqual(board.currentFrame, first.displayFrame)
        XCTAssertNotNil(board.power)
        XCTAssertEqual(board.wifi?.ip, "192.168.1.20")

        let second = LifecycleTransport()
        second.mode = "manual"
        second.displayFrame.set(25)
        let switched = await board.connect(using: second)
        XCTAssertTrue(switched)
        XCTAssertEqual(board.status?.renderer?.mode, "manual")
        XCTAssertEqual(board.preview?.mode, "manual")
        XCTAssertEqual(board.currentFrame, second.displayFrame)
        board.disconnect()
        XCTAssertNil(board.status)
        XCTAssertNil(board.preview)
        XCTAssertNil(board.power)
        XCTAssertNil(board.wifi)
        XCTAssertEqual(board.currentFrame, PackedFrame())
    }

    func testSwitchDuringSnapshotKeepsReplacementState() async throws {
        let board = BoardConnection()
        let old = LifecycleTransport()
        old.mode = "auto"
        old.holdStatus = true
        let connecting = Task { await board.connect(using: old) }
        await waitUntilTrue { old.heldStatus != nil }
        XCTAssertEqual(board.connectionState, .connecting)

        let replacement = LifecycleTransport()
        replacement.displayFrame.set(42)
        let connected = await board.connect(using: replacement)
        XCTAssertTrue(connected)
        let oldConnected = await connecting.value
        XCTAssertFalse(oldConnected)
        if let reply = old.heldStatus { old.receive(reply) }
        await Task.yield()
        XCTAssertEqual(board.status?.renderer?.mode, "manual")
        XCTAssertEqual(board.preview?.mode, "manual")
        XCTAssertEqual(board.currentFrame, replacement.displayFrame)
        board.disconnect()
    }

    func testReconnectRefreshesSnapshotAndPreviewQueriesPublish() async throws {
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        let wire = LifecycleTransport()
        _ = await board.connect(using: wire)
        wire.mode = "auto"
        wire.displayFrame.set(30)
        wire.emit(.disconnected)
        await waitUntilTrue { wire.attempts == 2 && board.connectionState == .connected }
        XCTAssertEqual(board.status?.renderer?.mode, "auto")
        XCTAssertEqual(board.preview?.mode, "auto")
        XCTAssertEqual(board.currentFrame, wire.displayFrame)
        wire.mode = "manual"
        let preview = try await board.getPreviewSync()
        XCTAssertEqual(board.preview, preview)
        XCTAssertEqual(board.preview?.mode, "manual")
        board.disconnect()
    }

    func testDisconnectDuringSetupSnapshotCannotPublishConnected() async {
        let wire = LifecycleTransport()
        wire.disconnectOnStatus = true
        let board = BoardConnection(reconnectDelay: { _ in 10 }, handshakeTimeout: 0.02)
        let connected = await board.connect(using: wire)
        XCTAssertFalse(connected)
        XCTAssertNotNil(board.lastError)
        XCTAssertNotEqual(board.connectionState, .connected)
        board.disconnect()
    }

    // MARK: Hotspot identity (BoardIdentity)

    func testHotspotIdentityMismatchDisconnectsAndStopsReconnecting() async throws {
        let wire = LifecycleTransport(kind: .hotspot)
        wire.wifiApSsid = "RinaChanBoard-000000000000"
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        board.expectedHotspotSSID = "RinaChanBoard-80B54EF48E09"
        let connected = await board.connect(using: wire)
        XCTAssertFalse(connected)
        XCTAssertTrue(wire.disconnects > 0)
        let expectedMessage = String(
            format: NSLocalizedString("已连接到另一块璃奈板（%@），而不是 %@", comment: ""),
            "RinaChanBoard-000000000000", "RinaChanBoard-80B54EF48E09"
        )
        XCTAssertEqual(board.lastError, expectedMessage)
        XCTAssertEqual(board.connectionState, .failed(expectedMessage))
        // No further reconnect attempt: this transport is retired, not retried.
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(wire.attempts, 1)
        XCTAssertEqual(board.connectionState, .failed(expectedMessage))
        board.disconnect()
    }

    /// A saved board that was connected as A drops its link and reconnects
    /// onto a hotspot now reporting B (the phone's Wi-Fi silently roamed):
    /// the reconnect attempt itself must fail closed with the mismatch
    /// message, not keep retrying against a board we know isn't the one we
    /// expect, and `onReady` must not fire again for the failed attempt.
    func testReconnectHotspotIdentityMismatchFailsWithoutFurtherRetries() async throws {
        let wire = LifecycleTransport(kind: .hotspot)
        wire.wifiApSsid = "RinaChanBoard-80B54EF48E09"
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        board.expectedHotspotSSID = "RinaChanBoard-80B54EF48E09"
        var readyCount = 0
        let connected = await board.connect(using: wire) { readyCount += 1 }
        XCTAssertTrue(connected)
        XCTAssertEqual(readyCount, 1)

        wire.wifiApSsid = "RinaChanBoard-000000000000"
        wire.emit(.disconnected)
        await waitUntilTrue {
            if case .failed = board.connectionState { return true }
            return false
        }
        let expectedMessage = String(
            format: NSLocalizedString("已连接到另一块璃奈板（%@），而不是 %@", comment: ""),
            "RinaChanBoard-000000000000", "RinaChanBoard-80B54EF48E09"
        )
        XCTAssertEqual(board.connectionState, .failed(expectedMessage))
        XCTAssertEqual(readyCount, 1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(board.connectionState, .failed(expectedMessage))
        board.disconnect()
    }

    /// A `.hotspot` link whose expected SSID embeds a unique board id but
    /// whose GET_STATUS read comes back with no `wifi` snapshot at all (as
    /// opposed to one with no identity fields, which is old-firmware and
    /// must be allowed) is a failed setup read, not a confirmed mismatch —
    /// it should retry via the normal reconnect loop instead of "allowing".
    func testHotspotUniqueExpectedButStatusReadFailsRetriesInsteadOfAllowing() async throws {
        let wire = LifecycleTransport(kind: .hotspot)
        wire.omitWifiFromStatus = true
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        board.expectedHotspotSSID = "RinaChanBoard-80B54EF48E09"
        let connected = await board.connect(using: wire)
        XCTAssertFalse(connected)
        XCTAssertNotEqual(board.connectionState, .connected)
        await waitUntilTrue { wire.attempts >= 2 }
        board.disconnect()
    }

    /// A saved board's reconnect path must not carry over a stale hotspot
    /// identity expectation onto a non-hotspot transport.
    func testNonHotspotConnectClearsExpectedHotspotSSID() async throws {
        let hotspotWire = LifecycleTransport(kind: .hotspot)
        hotspotWire.wifiApSsid = "RinaChanBoard-80B54EF48E09"
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        board.expectedHotspotSSID = "RinaChanBoard-80B54EF48E09"
        _ = await board.connect(using: hotspotWire)
        XCTAssertEqual(board.expectedHotspotSSID, "RinaChanBoard-80B54EF48E09")

        let wifiWire = LifecycleTransport(kind: .wifi(host: "192.168.1.14", port: 5000))
        _ = await board.connect(using: wifiWire)
        XCTAssertNil(board.expectedHotspotSSID)
        board.disconnect()
    }

    func testHotspotIdentityMatchStaysConnected() async throws {
        let wire = LifecycleTransport(kind: .hotspot)
        wire.wifiApSsid = "RinaChanBoard-80B54EF48E09"
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        board.expectedHotspotSSID = "RinaChanBoard-80B54EF48E09"
        let connected = await board.connect(using: wire)
        XCTAssertTrue(connected)
        XCTAssertEqual(board.connectionState, .connected)
        board.disconnect()
    }

    func testHotspotIdentityUnknownStaysConnected() async throws {
        let wire = LifecycleTransport(kind: .hotspot)
        // wifiApSsid unset: the board's reply carries no identity, e.g. older
        // firmware — unknown must be treated as "allow".
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        board.expectedHotspotSSID = "RinaChanBoard-80B54EF48E09"
        let connected = await board.connect(using: wire)
        XCTAssertTrue(connected)
        XCTAssertEqual(board.connectionState, .connected)
        board.disconnect()
    }
}

@MainActor
private final class LifecycleTransport: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    var failures: Int
    var attempts = 0
    var disconnects = 0
    var pings = 0
    var replyToPing = true
    var disconnectOnStatus = false
    var mode = "manual"
    var displayFrame = PackedFrame()
    var holdStatus = false
    var heldStatus: Data?
    var holdGetInfo = false
    var heldGetInfo: Data?
    /// Reported in `getStatus`'s `wifi.apSsid`, for hotspot-identity tests.
    var wifiApSsid: String?
    /// Reported in `getStatus`'s `wifi.boardId`, for hotspot-identity tests.
    var wifiBoardId: String?
    /// Drops the `wifi` object from `getStatus` entirely (as opposed to it
    /// carrying no identity fields), simulating a GET_STATUS read that failed
    /// to produce a Wi-Fi snapshot at all.
    var omitWifiFromStatus = false
    private let decoder = RinaLinkDecoder()
    private var states: AsyncStream<TransportState>.Continuation?
    private var incoming: AsyncStream<Data>.Continuation?

    init(failures: Int = 0, kind: TransportKind = .bluetooth) {
        self.failures = failures
        self.kind = kind
    }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { states = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incoming = $0 } }
    func emit(_ state: TransportState) { states?.yield(state) }
    func receive(_ data: Data) { incoming?.yield(data) }
    func savedStateEmitter() -> (TransportState) -> Void {
        let saved = states
        return { saved?.yield($0) }
    }
    func releaseGetInfo() {
        guard let reply = heldGetInfo else { return }
        heldGetInfo = nil
        receive(reply)
    }
    func connect() async throws {
        attempts += 1
        if attempts <= failures { throw RinaTransportError.underlying("GATT discovery failed") }
        emit(.connected)
    }
    func disconnect() { disconnects += 1; emit(.disconnected) }
    func send(_ data: Data) async throws {
        for frame in decoder.feed(data) {
            if disconnectOnStatus, frame.type == RinaLinkMessageType.getStatus.rawValue {
                emit(.disconnected)
                continue
            }
            if frame.type == RinaLinkMessageType.ping.rawValue {
                pings += 1
                if !replyToPing { continue }
            }
            let payload: Data
            switch RinaLinkMessageType(rawValue: frame.type) {
            case .getStatus:
                var object: [String: Any] = ["ok": true, "renderer": ["mode": mode], "power": [:]]
                if !omitWifiFromStatus {
                    var wifi: [String: Any] = ["ip": "192.168.1.20"]
                    if let wifiApSsid { wifi["apSsid"] = wifiApSsid }
                    if let wifiBoardId { wifi["boardId"] = wifiBoardId }
                    object["wifi"] = wifi
                }
                payload = try JSONSerialization.data(withJSONObject: object)
            case .getPreviewSync:
                payload = try JSONSerialization.data(withJSONObject: ["ok": true, "mode": mode])
            case .getFrame:
                payload = displayFrame.data
            default:
                payload = Data(#"{"ok":true}"#.utf8)
            }
            let response = RinaLinkFrame(type: frame.type | 0x80, seq: frame.seq,
                                         flags: 0, payload: payload)
            let encoded = try! RinaLinkEncoder.encode(response)
            if holdStatus, frame.type == RinaLinkMessageType.getStatus.rawValue {
                heldStatus = encoded
            } else if holdGetInfo,
                      frame.type == RinaLinkMessageType.cmd.rawValue,
                      let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                      object["cmd"] as? String == RinaCommand.getInfo.name {
                heldGetInfo = encoded
            } else {
                incoming?.yield(encoded)
            }
        }
    }
}
