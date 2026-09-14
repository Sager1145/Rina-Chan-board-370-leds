import CoreBluetooth
import XCTest
@testable import RinaBoard

/// Pure decision helpers extracted from `BLETransport`'s disconnect-gate
/// timeout/recovery handling, so the branching can be exercised without a
/// real `CBCentralManager`/`CBPeripheral`. See
/// `connectSelectedPeripheral`/`didFailToConnect`/`didDisconnect`/
/// `disconnect()` for how these are wired in.
@MainActor
final class BLETransportGateRecoveryTests: XCTestCase {
    // MARK: gateTimeoutAction

    func testGateTimeoutActionForceCompletesWhenAlreadyDisconnected() {
        XCTAssertEqual(BLETransport.gateTimeoutAction(state: .disconnected), .forceCompleteNow)
    }

    func testGateTimeoutActionRecancelsWhenStillConnectingOrConnected() {
        XCTAssertEqual(BLETransport.gateTimeoutAction(state: .connecting), .recancelThenForce)
        XCTAssertEqual(BLETransport.gateTimeoutAction(state: .connected), .recancelThenForce)
        XCTAssertEqual(BLETransport.gateTimeoutAction(state: .disconnecting), .recancelThenForce)
    }

    // MARK: GateRecoveryBookkeeping lifecycle

    func testDrainedGraceWaitDoesNotArmIgnoreMarker() {
        var bookkeeping = GateRecoveryBookkeeping()
        let id = UUID()
        let armed = bookkeeping.onGraceWaitResult(.drained, id: id)
        XCTAssertFalse(armed)
        XCTAssertFalse(bookkeeping.onTerminal(id: id))
    }

    func testTimedOutGraceWaitArmsIgnoreMarker() {
        var bookkeeping = GateRecoveryBookkeeping()
        let id = UUID()
        let armed = bookkeeping.onGraceWaitResult(.timedOut, id: id)
        XCTAssertTrue(armed)
        XCTAssertTrue(bookkeeping.armed.contains(id))
    }

    func testTerminalCallbackIsConsumedOnlyOnce() {
        var bookkeeping = GateRecoveryBookkeeping()
        let id = UUID()
        _ = bookkeeping.onGraceWaitResult(.timedOut, id: id)
        XCTAssertTrue(bookkeeping.onTerminal(id: id))
        // A second late callback for the same identifier is no longer armed:
        // only one late callback is ever swallowed.
        XCTAssertFalse(bookkeeping.onTerminal(id: id))
    }

    func testUnrelatedIdentifierIsNeverIgnored() {
        var bookkeeping = GateRecoveryBookkeeping()
        let armedID = UUID()
        let otherID = UUID()
        _ = bookkeeping.onGraceWaitResult(.timedOut, id: armedID)
        XCTAssertFalse(bookkeeping.onTerminal(id: otherID))
        XCTAssertTrue(bookkeeping.onTerminal(id: armedID))
    }

    func testDidConnectClearsMarkerForNewLiveLink() {
        var bookkeeping = GateRecoveryBookkeeping()
        let id = UUID()
        _ = bookkeeping.onGraceWaitResult(.timedOut, id: id)
        bookkeeping.onDidConnect(id: id)
        XCTAssertFalse(bookkeeping.onTerminal(id: id))
    }

    func testCancelBeginClearsStaleMarkerForSameIdentifier() {
        var bookkeeping = GateRecoveryBookkeeping()
        let id = UUID()
        _ = bookkeeping.onGraceWaitResult(.timedOut, id: id)
        bookkeeping.onCancelBegin(id: id)
        XCTAssertFalse(bookkeeping.onTerminal(id: id))
    }

    func testAbandonClearsMarkerWithoutTouchingOtherIdentifiers() {
        var bookkeeping = GateRecoveryBookkeeping()
        let abandonedID = UUID()
        let otherID = UUID()
        _ = bookkeeping.onGraceWaitResult(.timedOut, id: abandonedID)
        _ = bookkeeping.onGraceWaitResult(.timedOut, id: otherID)
        bookkeeping.onAbandon(id: abandonedID)
        XCTAssertFalse(bookkeeping.onTerminal(id: abandonedID))
        XCTAssertTrue(bookkeeping.onTerminal(id: otherID))
    }

    func testResetAfterGraceWaitArmsClearsTheJustArmedMarker() {
        // `onGraceWaitResult` and `onReset` are independent calls (the caller
        // in `connectSelectedPeripheral` decides which to invoke); this only
        // checks that `onReset` unconditionally wins if it runs after arming,
        // regardless of what armed it. It does not model any particular
        // ordering guarantee between a real timeout and a real Bluetooth
        // reset — that guarantee lives in `BLETransport`'s own
        // `centralManager.state == .poweredOn` re-check after every gate
        // wait, not in this value type.
        var bookkeeping = GateRecoveryBookkeeping()
        let id = UUID()
        let armed = bookkeeping.onGraceWaitResult(.timedOut, id: id)
        XCTAssertTrue(armed)
        bookkeeping.onReset()
        XCTAssertFalse(bookkeeping.onTerminal(id: id))
    }

    // MARK: BLEDisconnectGate.wakeAllWaiters (finding 4: superseded attempts)

    func testWakeAllWaitersResumesParkedWaiterAsSupersededWithoutClearingEntry() async throws {
        let gate = BLEDisconnectGate()
        let peripheral = UUID()
        _ = gate.begin(peripheral)
        let next = Task { try await gate.wait(for: peripheral) }
        try await Task.sleep(for: .milliseconds(10))
        gate.wakeAllWaiters()
        let result = try await next.value
        XCTAssertEqual(result, .superseded)
        // Unlike forceComplete, the entry is still pending: the underlying
        // cancel may still be genuinely in flight.
        XCTAssertTrue(gate.contains(peripheral))
        gate.complete(peripheral)
    }

    /// Regression test for the review finding: waking must not depend on
    /// which peripheral is "currently selected" (e.g. `peripheralIdentifier`
    /// in `BLETransport`, which a board switch may already have updated to
    /// the *new* board before `disconnect()` runs). `wakeAllWaiters` takes no
    /// identifier at all, so it always wakes whatever is actually parked —
    /// simulated here as a wait for a peripheral that is deliberately
    /// different from some other "currently selected" identifier.
    func testWakeAllWaitersWakesTheActuallyParkedPeripheralRegardlessOfCurrentSelection() async throws {
        let gate = BLEDisconnectGate()
        let oldBoard = UUID()
        let newlySelectedBoard = UUID() // never begun/waited on in this gate
        _ = gate.begin(oldBoard)
        let parkedOnOldBoard = Task { try await gate.wait(for: oldBoard) }
        try await Task.sleep(for: .milliseconds(10))
        // Nothing was ever begun for `newlySelectedBoard`; waking must still
        // resolve the waiter genuinely parked on `oldBoard`.
        gate.wakeAllWaiters()
        let result = try await parkedOnOldBoard.value
        XCTAssertEqual(result, .superseded)
        XCTAssertTrue(gate.contains(oldBoard))
        XCTAssertFalse(gate.contains(newlySelectedBoard))
        gate.complete(oldBoard)
    }

    func testWakeAllWaitersWakesEveryParkedWaiter() async throws {
        let gate = BLEDisconnectGate()
        let first = UUID()
        let second = UUID()
        _ = gate.begin(first)
        _ = gate.begin(second)
        let firstWaiter = Task { try await gate.wait(for: first) }
        let secondWaiter = Task { try await gate.wait(for: second) }
        try await Task.sleep(for: .milliseconds(10))
        gate.wakeAllWaiters()
        let firstResult = try await firstWaiter.value
        let secondResult = try await secondWaiter.value
        XCTAssertEqual(firstResult, .superseded)
        XCTAssertEqual(secondResult, .superseded)
        gate.complete(first)
        gate.complete(second)
    }

    // MARK: connect() single-flight attempt token (finding 2)

    /// Pure model of `BLETransport.connect()`'s attempt-token bookkeeping:
    /// entering claims the slot, and the matching `defer` only releases it if
    /// it is still held by the same attempt. This is what lets a superseded
    /// attempt's own unwind run (in any order) without clobbering a newer
    /// attempt that a `disconnect()` in between already let claim the slot.
    private struct SingleFlightSlot {
        private(set) var inProgressAttempt: UUID?

        mutating func enter() -> UUID? {
            guard inProgressAttempt == nil else { return nil }
            let attempt = UUID()
            inProgressAttempt = attempt
            return attempt
        }

        mutating func exit(_ attempt: UUID) {
            if inProgressAttempt == attempt { inProgressAttempt = nil }
        }

        mutating func disconnect() {
            inProgressAttempt = nil
        }
    }

    func testSupersededAttemptsUnwindDoesNotClearNewerAttemptsSlot() {
        var slot = SingleFlightSlot()
        guard let firstAttempt = slot.enter() else { return XCTFail("expected first enter to succeed") }
        // disconnect() frees the slot immediately, before the first attempt's
        // own suspended call stack has unwound...
        slot.disconnect()
        // ...letting a new connect() claim it right away in the same turn.
        guard let secondAttempt = slot.enter() else { return XCTFail("expected second enter to succeed") }
        XCTAssertNotEqual(firstAttempt, secondAttempt)
        // The first attempt's `defer` finally runs; it must not steal the
        // slot back out from under the second attempt.
        slot.exit(firstAttempt)
        XCTAssertEqual(slot.inProgressAttempt, secondAttempt)
        slot.exit(secondAttempt)
        XCTAssertNil(slot.inProgressAttempt)
    }

    func testSlotRejectsConcurrentEntryUntilExit() {
        var slot = SingleFlightSlot()
        guard let attempt = slot.enter() else { return XCTFail("expected first enter to succeed") }
        XCTAssertNil(slot.enter(), "a second connect() must be rejected while one is in flight")
        slot.exit(attempt)
        XCTAssertNotNil(slot.enter(), "the slot must be free again once the sole attempt exits")
    }
}
