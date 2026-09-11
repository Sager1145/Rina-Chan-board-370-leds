import Foundation

/// A tiny "latest value wins" coalescing sender for slider/live-edit sends
/// (brightness, auto-interval, scroll fps, live pixel frames): `submit`
/// stores the latest value; a single serialized loop task drains it, sending
/// at most every `minInterval` and always using whatever the newest
/// submitted value is by the time it gets a turn — older values submitted in
/// between are simply dropped, never queued, so a fast drag can never
/// produce out-of-order sends.
@MainActor
final class LatestValueSender<T: Sendable> {
    private let minInterval: TimeInterval
    private let send: (T) async -> Void
    private var pending: T?
    private var loopTask: Task<Void, Never>?

    init(minInterval: TimeInterval, send: @escaping (T) async -> Void) {
        self.minInterval = minInterval
        self.send = send
    }

    /// Records `value` as the latest to send and (re)starts the drain loop
    /// if it isn't already running.
    func submit(_ value: T) {
        pending = value
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let next = self.pending else { break }
                self.pending = nil
                await self.send(next)
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: UInt64(self.minInterval * 1_000_000_000))
            }
            self.loopTask = nil
        }
    }

    /// Cancels the drain loop and drops any not-yet-sent value.
    func cancel() {
        loopTask?.cancel()
        loopTask = nil
        pending = nil
    }

    deinit {
        loopTask?.cancel()
    }
}
