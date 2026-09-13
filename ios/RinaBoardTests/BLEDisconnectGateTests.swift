import XCTest
@testable import RinaBoard

@MainActor
final class BLEDisconnectGateTests: XCTestCase {
    func testSamePeripheralWaitsForTerminalCancellationCallback() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        XCTAssertTrue(gate.begin(peripheral))
        XCTAssertFalse(gate.begin(peripheral))
        var resumed = false
        let next = Task { try await gate.wait(for: peripheral); resumed = true }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(resumed)
        XCTAssertTrue(gate.complete(peripheral))
        try await next.value
        XCTAssertTrue(resumed)
        XCTAssertFalse(gate.complete(peripheral))
    }

    func testTimeoutDoesNotLetNewAttemptReuseUnfinishedPeripheral() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        _ = gate.begin(peripheral)
        do {
            try await gate.wait(for: peripheral, timeout: 0.01)
            XCTFail("Expected cancellation drain timeout")
        } catch {}
        XCTAssertTrue(gate.contains(peripheral))
        gate.complete(peripheral)
        try await gate.wait(for: peripheral)
    }

    func testCancelledWaitDoesNotCancelAnotherPeripheralOrForgetOldLink() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        _ = gate.begin(peripheral)
        let next = Task { try await gate.wait(for: peripheral) }
        next.cancel()
        do {
            try await next.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(gate.contains(peripheral))
        try await gate.wait(for: UUID())
        gate.complete(peripheral)
    }
}
