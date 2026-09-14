import Foundation
import RinaCore

/// Result of `BLEDisconnectGate.wait(for:timeout:)`: whether the previous
/// cancellation actually drained, or the wait simply ran out of patience.
/// A timeout no longer throws — the caller decides how to proceed (e.g. by
/// force-completing the entry) instead of surfacing a dead-end error.
enum GateWaitResult: Equatable {
    case drained
    case timedOut
    /// The connect attempt that started this wait was abandoned (e.g. an
    /// explicit `disconnect()` superseded it) before the entry actually
    /// drained or timed out. Unlike `.drained`, the pending entry itself is
    /// left untouched — the underlying cancel may still be genuinely in
    /// flight — so the caller must not treat this as license to reuse the
    /// peripheral.
    case superseded
}

/// What a caller should do after `BLEDisconnectGate.wait` reports
/// `.timedOut`, decided purely from the peripheral's current CoreBluetooth
/// state so the branching logic in `BLETransport` is unit-testable without a
/// real `CBCentralManager`.
enum GateTimeoutAction: Equatable {
    /// The peripheral already reports `.disconnected`, so no cancel is in
    /// flight for it to race with; the gate entry can be cleared immediately.
    case forceCompleteNow
    /// The peripheral is still connecting/connected: re-issue the cancel,
    /// give it a short grace period, then force-clear if it still doesn't
    /// drain.
    case recancelThenForce
}

/// Pure bookkeeping for the "ignore a late terminal callback from a
/// force-completed cancel" marker used by `BLETransport`. CoreBluetooth
/// callbacks only carry a peripheral identifier, not an attempt ID, and the
/// same `CBPeripheral` object is reused for the new attempt, so a late
/// callback for the old cancel cannot be told apart from an early failure of
/// the new attempt except by this marker. Extracted as a value type so its
/// lifecycle (armed on a genuine timeout, never on a drained wait, consumed
/// once, cleared on abandonment/reset) is unit-testable without CoreBluetooth.
///
/// Trade-off: if an ignored callback was actually the new attempt's own
/// failure, it is silently dropped — the 15 s connect timeout still fails
/// that attempt, just without the CoreBluetooth error detail.
struct GateRecoveryBookkeeping: Equatable {
    private(set) var armed: Set<UUID> = []

    /// Call with the result of the grace-period gate wait/timeout decision.
    /// Only a `.timedOut` result arms the marker — a `.drained` wait means
    /// the retained re-cancel got its own terminal callback, so there is
    /// nothing "late" left to ignore, and arming it anyway would swallow a
    /// genuine failure of the new attempt. Returns whether it armed.
    @discardableResult
    mutating func onGraceWaitResult(_ result: GateWaitResult, id: UUID) -> Bool {
        guard result == .timedOut else { return false }
        armed.insert(id)
        return true
    }

    /// A fresh cancel is starting for this identifier (e.g. `cancelLink`);
    /// any previous force-complete marker for it is stale.
    mutating func onCancelBegin(id: UUID) {
        armed.remove(id)
    }

    /// The new attempt's link is confirmed live (`didConnect`): nothing
    /// arriving from now on can belong to the old cancelled link.
    mutating func onDidConnect(id: UUID) {
        armed.remove(id)
    }

    /// A terminal callback arrived for `id`. Returns whether it should be
    /// ignored; consumes the marker so only a single callback is swallowed.
    mutating func onTerminal(id: UUID) -> Bool {
        armed.remove(id) != nil
    }

    /// The attempt that armed this marker was abandoned before ever seeing a
    /// terminal callback (e.g. `resumeConnect(.failure)`, `disconnect()`).
    mutating func onAbandon(id: UUID) {
        armed.remove(id)
    }

    /// Full reset, e.g. when Bluetooth becomes unavailable.
    mutating func onReset() {
        armed.removeAll()
    }
}

/// CoreBluetooth's callbacks identify the peripheral, not the connect attempt.
/// Do not reuse a peripheral until its previous cancellation has completed.
@MainActor
final class BLEDisconnectGate {
    private var pending: Set<UUID> = []
    private var waiters: [UUID: (peripheral: UUID, continuation: CheckedContinuation<GateWaitResult, Error>)] = [:]

    func begin(_ peripheral: UUID) -> Bool { pending.insert(peripheral).inserted }
    func contains(_ peripheral: UUID) -> Bool { pending.contains(peripheral) }

    @discardableResult
    func complete(_ peripheral: UUID) -> Bool {
        guard pending.remove(peripheral) != nil else { return false }
        let ids = waiters.filter { $0.value.peripheral == peripheral }.map(\.key)
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume(returning: .drained) }
        return true
    }

    func completeAll() {
        for peripheral in Array(pending) { complete(peripheral) }
    }

    /// Wakes every waiter currently parked, for whichever peripheral it is
    /// actually parked on, with `.superseded` — WITHOUT removing any pending
    /// entry, since the underlying cancel may still be genuinely in flight
    /// (must not be confused with `complete`/`forceComplete`). Used when the
    /// connect attempt that started a wait has itself been abandoned (e.g.
    /// `BLETransport.disconnect()`), so its caller can stop blocking without
    /// pretending the old link actually finished draining.
    ///
    /// Deliberately not parameterized by peripheral identifier: the caller
    /// (`BLETransport.disconnect()`) cannot reliably know which peripheral a
    /// parked wait is for — e.g. when switching boards, `peripheralIdentifier`
    /// may already have been updated to the *new* board before `disconnect()`
    /// runs. `connect()` is single-flight, so at most one wait is ever parked
    /// at a time, and waking it unconditionally is always correct.
    func wakeAllWaiters() {
        let ids = Array(waiters.keys)
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume(returning: .superseded) }
    }

    /// Removes the entry unconditionally and resumes its waiters as `.drained`.
    /// Used when CoreBluetooth never delivers a terminal callback for a
    /// cancelled connection (e.g. the peripheral object was released before
    /// the cancel completed).
    func forceComplete(_ peripheral: UUID) {
        guard pending.remove(peripheral) != nil else { return }
        let ids = waiters.filter { $0.value.peripheral == peripheral }.map(\.key)
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume(returning: .drained) }
    }

    func wait(for peripheral: UUID, timeout: TimeInterval = 5) async throws -> GateWaitResult {
        try Task.checkCancellation()
        guard pending.contains(peripheral) else { return .drained }
        let id = UUID()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self.timeOut(id)
        }
        defer { deadline.cancel() }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GateWaitResult, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !pending.contains(peripheral) {
                    continuation.resume(returning: .drained)
                } else {
                    waiters[id] = (peripheral, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        try Task.checkCancellation()
        return result
    }

    /// A timeout only releases this waiter with `.timedOut`. The old radio
    /// operation's entry stays pending until CoreBluetooth delivers its
    /// terminal callback, or the caller decides to `forceComplete` it.
    private func timeOut(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: .timedOut)
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
