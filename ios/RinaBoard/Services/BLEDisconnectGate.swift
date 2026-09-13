import Foundation
import RinaCore

/// CoreBluetooth's callbacks identify the peripheral, not the connect attempt.
/// Do not reuse a peripheral until its previous cancellation has completed.
@MainActor
final class BLEDisconnectGate {
    private var pending: Set<UUID> = []
    private var waiters: [UUID: (peripheral: UUID, continuation: CheckedContinuation<Void, Error>)] = [:]

    func begin(_ peripheral: UUID) -> Bool { pending.insert(peripheral).inserted }
    func contains(_ peripheral: UUID) -> Bool { pending.contains(peripheral) }

    @discardableResult
    func complete(_ peripheral: UUID) -> Bool {
        guard pending.remove(peripheral) != nil else { return false }
        let ids = waiters.filter { $0.value.peripheral == peripheral }.map(\.key)
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume() }
        return true
    }

    func completeAll() {
        for peripheral in Array(pending) { complete(peripheral) }
    }

    func wait(for peripheral: UUID, timeout: TimeInterval = 5) async throws {
        try Task.checkCancellation()
        guard pending.contains(peripheral) else { return }
        let id = UUID()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self.fail(id, error: RinaTransportError.underlying("上一条蓝牙连接尚未断开，请稍后重试"))
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !pending.contains(peripheral) {
                    continuation.resume()
                } else {
                    waiters[id] = (peripheral, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.fail(id, error: CancellationError()) }
        }
        try Task.checkCancellation()
    }

    private func fail(_ id: UUID, error: Error) {
        // A timeout/cancel only releases this waiter. The old radio operation
        // remains pending until CoreBluetooth delivers its terminal callback.
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }
}
