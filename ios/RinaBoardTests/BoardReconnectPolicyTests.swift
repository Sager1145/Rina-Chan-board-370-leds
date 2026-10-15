import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class BoardReconnectPolicyTests: XCTestCase {
    private let boardID = "80B54EF48E09"

    func testDroppedCarrierUsesSameBoardAlternativeBeforeOriginal() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.001 })
        let original = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let alternative = ReconnectPolicyTransport(kind: .wifi(host: "192.168.1.20", port: 5000), boardID: boardID)
        let initialConnected = await board.connect(using: original, expectedBoardIdentity: boardID)
        XCTAssertTrue(initialConnected)
        var providerSnapshot: WifiStatus?
        board.reconnectCandidatesProvider = { kind, wifi in
            XCTAssertEqual(kind, .bluetooth)
            providerSnapshot = wifi
            return [BoardReconnectCandidate(transport: alternative, expectedBoardIdentity: self.boardID)]
        }

        original.emit(.disconnected)
        await waitUntilTrue { board.connectionState == .connected && alternative.attempts == 1 }
        XCTAssertEqual(original.attempts, 1)
        XCTAssertEqual(board.transportKind, alternative.kind)
        XCTAssertEqual(board.boardIdentity, boardID)
        XCTAssertEqual(providerSnapshot?.boardId, boardID)
        board.disconnect()
    }

    func testWrongBoardAlternativeNeverPublishesConnectedAndTriesOriginal() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.001 })
        let original = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let wrong = ReconnectPolicyTransport(kind: .wifi(host: "192.168.1.20", port: 5000), boardID: "AAAAAAAAAAAA")
        let initialConnected = await board.connect(using: original, expectedBoardIdentity: boardID)
        XCTAssertTrue(initialConnected)
        board.reconnectCandidatesProvider = { _, _ in
            [BoardReconnectCandidate(transport: wrong, expectedBoardIdentity: self.boardID)]
        }

        original.emit(.disconnected)
        await waitUntilTrue { wrong.attempts == 1 && original.attempts == 2 && board.connectionState == .connected }
        XCTAssertGreaterThan(wrong.disconnects, 0)
        XCTAssertEqual(board.boardIdentity, boardID)
        XCTAssertEqual(board.transportKind, .bluetooth)
        board.disconnect()
    }

    func testStopCancelsPendingAttemptAndManualRetryDoesNotReenableAuto() async throws {
        let board = BoardConnection(reconnectDelay: { _ in 0.08 })
        let wire = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let initialConnected = await board.connect(using: wire, expectedBoardIdentity: boardID)
        XCTAssertTrue(initialConnected)
        wire.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }

        board.stopAutomaticReconnect()
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        XCTAssertTrue(board.wasUserDisconnected)
        XCTAssertTrue(board.canRetry)
        XCTAssertEqual(board.connectionState, .disconnected)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(wire.attempts, 1)

        wire.failuresRemaining = 1
        let firstRetry = await board.retryNow()
        XCTAssertFalse(firstRetry)
        XCTAssertEqual(wire.attempts, 2)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(wire.attempts, 2, "A failed manual attempt must not restart the stopped loop")
        XCTAssertTrue(board.wasUserDisconnected)
        let secondRetry = await board.retryNow()
        XCTAssertTrue(secondRetry)
        XCTAssertEqual(wire.attempts, 3)
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        board.disconnect()
    }

    func testStoppedManualRetryFallsBackFromFailedWiFiToSameBoardBLE() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.08 })
        let wifi = ReconnectPolicyTransport(kind: .wifi(host: "192.168.2.10", port: 5000), boardID: boardID)
        let ble = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let first = await board.connect(using: wifi, expectedBoardIdentity: boardID)
        XCTAssertTrue(first)
        board.reconnectCandidatesProvider = { _, _ in
            [BoardReconnectCandidate(transport: ble, expectedBoardIdentity: self.boardID)]
        }
        wifi.failuresRemaining = 100
        wifi.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }
        board.stopAutomaticReconnect()
        XCTAssertFalse(board.isAutomaticReconnectEnabled)

        let retried = await board.retryNow()
        XCTAssertTrue(retried)
        XCTAssertEqual(wifi.attempts, 2)
        XCTAssertEqual(ble.attempts, 1)
        XCTAssertEqual(board.transportKind, .bluetooth)
        XCTAssertEqual(board.boardIdentity, boardID)
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        XCTAssertTrue(board.wasUserDisconnected)
        board.disconnect()
    }

    func testStoppedManualRetryRetainsAlternateLearnedBeforeSnapshotClears() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.08 })
        let ble = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let wifi = ReconnectPolicyTransport(kind: .wifi(host: "192.168.2.10", port: 5000), boardID: boardID)
        let connected = await board.connect(using: ble, expectedBoardIdentity: boardID)
        XCTAssertTrue(connected)
        board.reconnectCandidatesProvider = { _, snapshot in
            guard snapshot?.boardId == self.boardID else { return [] }
            return [BoardReconnectCandidate(transport: wifi, expectedBoardIdentity: self.boardID)]
        }
        ble.failuresRemaining = 100
        ble.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }
        board.stopAutomaticReconnect()
        XCTAssertNil(board.wifi)

        let retried = await board.retryNow()
        XCTAssertTrue(retried)
        XCTAssertEqual(wifi.attempts, 1)
        XCTAssertEqual(board.transportKind, wifi.kind)
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        board.disconnect()
    }

    func testManualRetrySkipsDuplicateWiFiEndpointsBeforeUsingAnotherAddress() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.08 })
        let ble = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let duplicateKind = TransportKind.wifi(host: "192.168.2.10", port: 5000)
        let duplicates = (0..<5).map { _ in ReconnectPolicyTransport(kind: duplicateKind, boardID: boardID) }
        let usable = ReconnectPolicyTransport(kind: .wifi(host: "192.168.2.11", port: 5000), boardID: boardID)
        let connected = await board.connect(using: ble, expectedBoardIdentity: boardID)
        XCTAssertTrue(connected)
        ble.failuresRemaining = 100
        ble.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }
        board.stopAutomaticReconnect()
        duplicates.forEach { $0.failuresRemaining = 100 }
        board.reconnectCandidatesProvider = { _, _ in
            (duplicates + [usable]).map { BoardReconnectCandidate(transport: $0, expectedBoardIdentity: self.boardID) }
        }

        let retried = await board.retryNow()
        XCTAssertTrue(retried)
        XCTAssertEqual(duplicates[0].attempts, 1)
        XCTAssertTrue(duplicates.dropFirst().allSatisfy { $0.attempts == 0 })
        XCTAssertEqual(usable.attempts, 1)
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        board.disconnect()
    }

    func testStoppedManualRetryRejectsWrongBoardAlternateWithoutBackgroundRetry() async throws {
        let board = BoardConnection(reconnectDelay: { _ in 0.01 })
        let wifi = ReconnectPolicyTransport(kind: .wifi(host: "192.168.2.10", port: 5000), boardID: boardID)
        let wrongBLE = ReconnectPolicyTransport(kind: .bluetooth, boardID: "AAAAAAAAAAAA")
        let first = await board.connect(using: wifi, expectedBoardIdentity: boardID)
        XCTAssertTrue(first)
        board.reconnectCandidatesProvider = { _, _ in
            [BoardReconnectCandidate(transport: wrongBLE, expectedBoardIdentity: self.boardID)]
        }
        wifi.failuresRemaining = 100
        wifi.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }
        board.stopAutomaticReconnect()

        let retried = await board.retryNow()
        XCTAssertFalse(retried)
        XCTAssertNotEqual(board.connectionState, .connected)
        XCTAssertEqual(wifi.attempts, 2)
        XCTAssertEqual(wrongBLE.attempts, 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(wifi.attempts, 2)
        XCTAssertEqual(wrongBLE.attempts, 1)
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        XCTAssertTrue(board.wasUserDisconnected)
        board.disconnect()
    }

    func testStopDuringManualAlternateSetupCannotPublishLateReady() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.08 })
        let wifi = ReconnectPolicyTransport(kind: .wifi(host: "192.168.2.10", port: 5000), boardID: boardID)
        let ble = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let first = await board.connect(using: wifi, expectedBoardIdentity: boardID)
        XCTAssertTrue(first)
        board.reconnectCandidatesProvider = { _, _ in
            [BoardReconnectCandidate(transport: ble, expectedBoardIdentity: self.boardID)]
        }
        wifi.failuresRemaining = 100
        wifi.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }
        board.stopAutomaticReconnect()
        ble.holdConnect = true
        let manual = Task { await board.retryNow() }
        await waitUntilTrue { ble.hasPendingConnect }

        board.stopAutomaticReconnect()
        ble.releaseConnect()
        let retried = await manual.value
        XCTAssertFalse(retried)
        XCTAssertEqual(board.connectionState, .disconnected)
        XCTAssertEqual(ble.attempts, 1)
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        board.disconnect()
    }

    func testSecondManualRetrySupersedesFirstWithoutLateReadiness() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.08 })
        let wifi = ReconnectPolicyTransport(kind: .wifi(host: "192.168.2.10", port: 5000), boardID: boardID)
        let ble = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let firstConnect = await board.connect(using: wifi, expectedBoardIdentity: boardID)
        XCTAssertTrue(firstConnect)
        board.reconnectCandidatesProvider = { _, _ in
            [BoardReconnectCandidate(transport: ble, expectedBoardIdentity: self.boardID)]
        }
        wifi.failuresRemaining = 100
        wifi.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }
        board.stopAutomaticReconnect()
        ble.holdConnect = true

        let first = Task { await board.retryNow() }
        await waitUntilTrue { ble.hasPendingConnect && ble.attempts == 1 }
        let second = Task { await board.retryNow() }
        await waitUntilTrue { ble.hasPendingConnect && ble.attempts == 2 }
        ble.releaseConnect()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(board.connectionState, .connected)
        XCTAssertEqual(board.boardIdentity, boardID)
        XCTAssertFalse(board.isAutomaticReconnectEnabled)
        board.disconnect()
    }

    func testAllFailedCarriersRespectSharedRetryBudget() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.001 })
        let original = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let alternative = ReconnectPolicyTransport(kind: .wifi(host: "192.168.1.20", port: 5000), boardID: boardID)
        let initialConnected = await board.connect(using: original, expectedBoardIdentity: boardID)
        XCTAssertTrue(initialConnected)
        original.failuresRemaining = 100
        alternative.failuresRemaining = 100
        board.reconnectCandidatesProvider = { _, _ in
            [BoardReconnectCandidate(transport: alternative, expectedBoardIdentity: self.boardID)]
        }

        original.emit(.disconnected)
        await waitUntilTrue {
            if case .failed(let message) = board.connectionState {
                return message == String(format: NSLocalizedString("重连失败，已达到最大尝试次数：%@", comment: ""), board.lastError ?? "")
            }
            return false
        }
        XCTAssertEqual(alternative.attempts, 1)
        XCTAssertEqual(original.attempts, 5, "Initial connect plus four original-carrier retries")
        XCTAssertTrue(board.canRetry)
        board.disconnect()
    }

    func testStopDuringCarrierSetupCannotPublishLateConnectedState() async {
        let board = BoardConnection(reconnectDelay: { _ in 0.001 })
        let wire = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        wire.holdConnect = true
        let connecting = Task { await board.connect(using: wire, expectedBoardIdentity: boardID) }
        await waitUntilTrue { wire.hasPendingConnect }

        board.stopAutomaticReconnect()
        wire.releaseConnect()
        let result = await connecting.value
        XCTAssertFalse(result)
        XCTAssertEqual(board.connectionState, .disconnected)
        XCTAssertEqual(wire.attempts, 1)
        XCTAssertTrue(board.wasUserDisconnected)
        board.disconnect()
    }

    func testExplicitConnectionSupersedesScheduledRetryAndReenablesAuto() async throws {
        let board = BoardConnection(reconnectDelay: { _ in 0.08 })
        let original = ReconnectPolicyTransport(kind: .bluetooth, boardID: boardID)
        let replacement = ReconnectPolicyTransport(kind: .wifi(host: "192.168.1.21", port: 5000), boardID: boardID)
        let initialConnected = await board.connect(using: original, expectedBoardIdentity: boardID)
        XCTAssertTrue(initialConnected)
        original.emit(.disconnected)
        await waitUntilTrue { if case .reconnecting = board.connectionState { return true }; return false }
        board.stopAutomaticReconnect()
        let replacementConnected = await board.connect(using: replacement, expectedBoardIdentity: boardID)
        XCTAssertTrue(replacementConnected)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(original.attempts, 1)
        XCTAssertEqual(board.transportKind, replacement.kind)
        XCTAssertTrue(board.isAutomaticReconnectEnabled)
        XCTAssertFalse(board.wasUserDisconnected)
        board.disconnect()
    }
}

@MainActor
private final class ReconnectPolicyTransport: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    let boardID: String
    var attempts = 0
    var disconnects = 0
    var failuresRemaining = 0
    var holdConnect = false
    var hasPendingConnect: Bool { pendingConnect != nil }
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private let decoder = RinaLinkDecoder()
    private var states: AsyncStream<TransportState>.Continuation?
    private var incoming: AsyncStream<Data>.Continuation?

    init(kind: TransportKind, boardID: String) {
        self.kind = kind
        self.boardID = boardID
    }

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { states = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incoming = $0 } }
    func emit(_ state: TransportState) { states?.yield(state) }

    func connect() async throws {
        attempts += 1
        if holdConnect {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingConnect = continuation
            }
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RinaTransportError.underlying("carrier unavailable")
        }
        emit(.connected)
    }

    func releaseConnect() {
        holdConnect = false
        pendingConnect?.resume()
        pendingConnect = nil
    }

    func disconnect() {
        disconnects += 1
        pendingConnect?.resume(throwing: RinaTransportError.notConnected)
        pendingConnect = nil
        emit(.disconnected)
    }

    func send(_ data: Data) async throws {
        for frame in decoder.feed(data) {
            let payload: Data
            switch RinaLinkMessageType(rawValue: frame.type) {
            case .getStatus:
                payload = Data("{\"ok\":true,\"wifi\":{\"boardId\":\"\(boardID)\"},\"power\":{}}".utf8)
            case .getFrame:
                payload = PackedFrame().data
            case .getPreviewSync:
                payload = Data(#"{"ok":true,"mode":"manual"}"#.utf8)
            default:
                payload = Data(#"{"ok":true}"#.utf8)
            }
            incoming?.yield(try RinaLinkEncoder.encode(RinaLinkFrame(
                type: frame.type | 0x80, seq: frame.seq, flags: 0, payload: payload
            )))
        }
    }
}
