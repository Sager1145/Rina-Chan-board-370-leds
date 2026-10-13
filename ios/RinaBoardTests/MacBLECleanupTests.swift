import CoreBluetooth
import XCTest
@testable import RinaBoard

@MainActor
final class MacBLECleanupTests: XCTestCase {
    func testForceCompletedGateDoesNotProveConnectedPeripheralDisconnected() async throws {
        let gate = BLEDisconnectGate()
        let id = UUID()
        _ = gate.begin(id)
        gate.forceComplete(id)
        let result = try await BLETransport.waitForTerminalDisconnection(
            gate: gate, identifier: id, timeout: 0.01, state: { .connected })
        XCTAssertFalse(result)
    }

    func testTimeoutDoesNotDeclareCleanupOrClearPendingCancellation() async throws {
        let gate = BLEDisconnectGate()
        let id = UUID()
        _ = gate.begin(id)
        let result = try await BLETransport.waitForTerminalDisconnection(
            gate: gate, identifier: id, timeout: 0.01, state: { .disconnecting })
        XCTAssertFalse(result)
        XCTAssertTrue(gate.contains(id))
    }

    func testTerminalCallbackAndDisconnectedPeripheralProveCleanup() async throws {
        let gate = BLEDisconnectGate()
        let id = UUID()
        _ = gate.begin(id)
        var state = CBPeripheralState.disconnecting
        let waiter = Task {
            try await BLETransport.waitForTerminalDisconnection(
                gate: gate, identifier: id, timeout: 1, state: { state })
        }
        await waitUntilTrue { gate.registeredWaiterCount(for: id) == 1 }
        state = .disconnected
        gate.complete(id)
        let result = try await waiter.value
        XCTAssertTrue(result)
    }

    func testSupersededWaitDoesNotDeclareCleanup() async throws {
        let gate = BLEDisconnectGate()
        let id = UUID()
        _ = gate.begin(id)
        let waiter = Task {
            try await BLETransport.waitForTerminalDisconnection(
                gate: gate, identifier: id, timeout: 1, state: { .disconnected })
        }
        await waitUntilTrue { gate.registeredWaiterCount(for: id) == 1 }
        gate.wakeAllWaiters()
        let result = try await waiter.value
        XCTAssertFalse(result)
        XCTAssertTrue(gate.contains(id))
        gate.complete(id)
    }

    func testCancellationDoesNotForgetPendingLink() async throws {
        let gate = BLEDisconnectGate()
        let id = UUID()
        _ = gate.begin(id)
        let waiter = Task {
            try await BLETransport.waitForTerminalDisconnection(
                gate: gate, identifier: id, timeout: 1, state: { .disconnecting })
        }
        await waitUntilTrue { gate.registeredWaiterCount(for: id) == 1 }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Cancelled cleanup must not report success")
        } catch is CancellationError { }
        XCTAssertTrue(gate.contains(id))
        gate.complete(id)
    }
}
