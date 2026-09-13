import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    func testThrowWithoutStateEventRetriesAndEventuallyConnects() async throws {
        let wire = LifecycleTransport(failures: 2)
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        let first = await board.connect(using: wire)
        XCTAssertFalse(first)
        XCTAssertEqual(board.lastError, "GATT discovery failed")
        try await waitUntil { board.connectionState == .connected }
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
        try await waitUntil { wire.pings == 1 }
        XCTAssertEqual(board.connectionState, .connecting)
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertGreaterThan(wire.disconnects, 0)
        XCTAssertNotNil(board.lastError)
        board.disconnect()
    }

    func testRetryLimitAlsoAppliesToThrownErrors() async throws {
        let wire = LifecycleTransport(failures: 100)
        let board = BoardConnection(reconnectDelay: { _ in 0.001 })
        _ = await board.connect(using: wire)
        try await waitUntil {
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
        let task = Task { await board.connect(using: wire) }
        try await waitUntil { wire.pings == 1 }
        task.cancel()
        let connected = await task.value
        XCTAssertFalse(connected)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(wire.attempts, 1)
        XCTAssertEqual(board.connectionState, .disconnected)
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
        try await waitUntil { wire.attempts == 2 && board.connectionState == .connected }
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
        try await waitUntil { old.heldStatus != nil }
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
        try await waitUntil { wire.attempts == 2 && board.connectionState == .connected }
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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class LifecycleTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
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
    private let decoder = RinaLinkDecoder()
    private var states: AsyncStream<TransportState>.Continuation?
    private var incoming: AsyncStream<Data>.Continuation?

    init(failures: Int = 0) { self.failures = failures }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { states = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incoming = $0 } }
    func emit(_ state: TransportState) { states?.yield(state) }
    func receive(_ data: Data) { incoming?.yield(data) }
    func savedStateEmitter() -> (TransportState) -> Void {
        let saved = states
        return { saved?.yield($0) }
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
                payload = try JSONSerialization.data(withJSONObject: [
                    "ok": true, "renderer": ["mode": mode],
                    "power": [:], "wifi": ["ip": "192.168.1.20"]
                ])
            case .getPreviewSync:
                payload = try JSONSerialization.data(withJSONObject: ["ok": true, "mode": mode])
            case .getFrame:
                payload = displayFrame.data
            default:
                payload = Data(#"{"ok":true}"#.utf8)
            }
            let response = RinaLinkFrame(type: frame.type | 0x80, seq: frame.seq,
                                         flags: 0, payload: payload)
            let encoded = RinaLinkEncoder.encode(response)
            if holdStatus, frame.type == RinaLinkMessageType.getStatus.rawValue {
                heldStatus = encoded
            } else {
                incoming?.yield(encoded)
            }
        }
    }
}
