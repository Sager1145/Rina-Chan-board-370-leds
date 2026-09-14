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

    func testTimeoutReturnsTimedOutAndKeepsEntryPending() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        _ = gate.begin(peripheral)
        let result = try await gate.wait(for: peripheral, timeout: 0.01)
        XCTAssertEqual(result, .timedOut)
        XCTAssertTrue(gate.contains(peripheral))
    }

    func testForceCompleteClearsEntryAndRejectsLateComplete() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        _ = gate.begin(peripheral)
        gate.forceComplete(peripheral)
        XCTAssertFalse(gate.contains(peripheral))
        XCTAssertFalse(gate.complete(peripheral))
    }

    func testNewAttemptSucceedsImmediatelyAfterForceComplete() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        _ = gate.begin(peripheral)
        gate.forceComplete(peripheral)
        // The stale entry is gone, so a fresh cancel/complete cycle for the
        // same UUID behaves as if nothing had been pending before.
        XCTAssertTrue(gate.begin(peripheral))
        gate.complete(peripheral)
        let result = try await gate.wait(for: peripheral)
        XCTAssertEqual(result, .drained)
    }

    func testForceCompleteResumesParkedWaiters() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        _ = gate.begin(peripheral)
        let next = Task { try await gate.wait(for: peripheral) }
        try await Task.sleep(for: .milliseconds(10))
        gate.forceComplete(peripheral)
        let result = try await next.value
        XCTAssertEqual(result, .drained)
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
