import Foundation
import RinaCore

/// Owns sequence-number allocation, pending-continuation bookkeeping,
/// `FLAG_MORE` chunk aggregation, and post-timeout/cancel quarantine for
/// `BoardConnection`'s single active carrier. Extracted verbatim from
/// `BoardConnection` so this request/reply matching logic can be exercised
/// directly in tests; see `BoardConnection` for how it fits into the rest of
/// the protocol handling (RINALINK_PROTOCOL_V1 §2, A1).
@MainActor
final class RinaRequestBroker {
    private var nextSeq: UInt8 = 1
    private var pending: [UInt8: PendingRequest] = [:]
    /// Retain only matching metadata until the old reply finishes or the carrier resets.
    private struct QuarantinedRequest {
        let replyType: UInt8
        let aggregateMore: Bool
    }
    private var quarantinedSeqs: [UInt8: QuarantinedRequest] = [:]
    /// Test/diagnostic view of how many retired sequence numbers are still quarantined.
    var quarantinedSequenceCount: Int { quarantinedSeqs.count }
    /// Cumulative number of times a seq was quarantined (tests/diagnostics).
    private(set) var quarantineEventCount = 0
    private static let quarantineReconnectThreshold = 128
    private static let maxAggregatedReplyBytes = 256 * 1024

    /// `true` once the quarantine set has reached `quarantineReconnectThreshold`.
    var isQuarantineOverThreshold: Bool { quarantinedSeqs.count >= Self.quarantineReconnectThreshold }

    /// Fired synchronously from `quarantine(_:request:recover:)` the moment a
    /// *recoverable* quarantine crosses the threshold. `BoardConnection`
    /// installs this to defer through its own session-gated `Task` and tear
    /// the carrier down; never fired by `failAll(_:)`'s non-recoverable path.
    var onQuarantineOverflow: (@MainActor () -> Void)?

    private final class PendingRequest {
        let id: UUID
        let replyType: UInt8
        /// When false (GET_FACES), a terminal frame resolves the request
        /// immediately regardless of `FLAG_MORE` — for that message `MORE`
        /// means "call again with a higher offset", not "more chunks of this
        /// same reply are coming on this seq" (A1).
        let aggregateMore: Bool
        var accumulated = Data()
        let continuation: CheckedContinuation<RinaLinkFrame, Error>
        let timeoutTask: Task<Void, Never>
        var sendTask: Task<Void, Never>?

        init(
            id: UUID,
            replyType: UInt8,
            aggregateMore: Bool,
            continuation: CheckedContinuation<RinaLinkFrame, Error>,
            timeoutTask: Task<Void, Never>,
            sendTask: Task<Void, Never>?
        ) {
            self.id = id
            self.replyType = replyType
            self.aggregateMore = aggregateMore
            self.continuation = continuation
            self.timeoutTask = timeoutTask
            self.sendTask = sendTask
        }
    }

    /// Clears the quarantine set only — a fresh carrier has a fresh
    /// board-side parser/reply queue, so sequence IDs poisoned by uncertain
    /// requests on the old carrier can be reused. `nextSeq` itself
    /// intentionally keeps advancing across carriers to avoid immediate
    /// reuse and is NEVER reset here.
    func resetQuarantine() {
        quarantinedSeqs.removeAll()
    }

    /// Sends one framed request and awaits its reply. `aggregateMore: true`
    /// treats `FLAG_MORE` on the terminal frame as "more chunks of this same
    /// reply follow on this seq" and keeps waiting; `false` resolves the
    /// request on the first frame either way (A1). `encode` receives the
    /// allocated seq and must be synchronous (no `await` may land between
    /// seq allocation and `pending` registration). `write` performs the
    /// actual transport send; `onWriteFailure` is invoked whenever `write`
    /// throws, regardless of whether a pending entry was still registered
    /// for this seq.
    func request(
        replyType: UInt8,
        aggregateMore: Bool,
        timeout: TimeInterval,
        encode: (UInt8) throws -> Data,
        write: @escaping @MainActor (Data) async throws -> Void,
        onWriteFailure: @escaping @MainActor (Error) -> Void
    ) async throws -> RinaLinkFrame {
        let seq = try nextSequenceNumber()
        let requestID = UUID()
        let data = try encode(seq)

        let reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RinaLinkFrame, Error>) in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    if let request = self.removePending(seq: seq, requestID: requestID) {
                        self.quarantine(seq, request: request)
                        request.sendTask?.cancel()
                        request.continuation.resume(throwing: RinaTransportError.timeout)
                    }
                }
                pending[seq] = PendingRequest(id: requestID,
                                              replyType: replyType,
                                              aggregateMore: aggregateMore,
                                              continuation: continuation,
                                              timeoutTask: timeoutTask,
                                              sendTask: nil)
                let sendTask = Task {
                    do {
                        try await write(data)
                    } catch {
                        if let request = self.removePending(seq: seq, requestID: requestID) {
                            self.quarantine(seq, request: request)
                            request.timeoutTask.cancel()
                            request.continuation.resume(throwing: error)
                        }
                        onWriteFailure(error)
                    }
                }
                // This closure is synchronous on MainActor, so cancellation
                // cannot remove `pending[seq]` between registration and storing
                // the task handle. A cancelled queued transport write is now
                // removed before BLE back-pressure clears.
                pending[seq]?.sendTask = sendTask
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending(seq: seq, requestID: requestID)
            }
        }
        return reply
    }

    /// Routes one decoded reply frame to its matching pending request, or to
    /// the quarantine table if its seq was retired by a timeout/cancel.
    func deliver(_ frame: RinaLinkFrame) {
        // A1/quarantine: a reply for a seq we already gave up on (timed out)
        // must not be delivered to a different, newer request that happens to
        // have been assigned the same (reused) seq.
        if let retired = quarantinedSeqs[frame.seq] {
            if frame.type == retired.replyType || frame.isError {
                if !retired.aggregateMore || !frame.isMore {
                    quarantinedSeqs.removeValue(forKey: frame.seq)
                }
            }
            return
        }

        // Reply matching by seq, aggregating MORE-flagged chunks only for
        // requests that opted into aggregation (`aggregateMore == true`).
        guard let request = pending[frame.seq], frame.type == request.replyType || frame.isError else {
            return
        }
        guard frame.payload.count <= Self.maxAggregatedReplyBytes - request.accumulated.count else {
            pending.removeValue(forKey: frame.seq)
            quarantine(frame.seq, request: request)
            request.timeoutTask.cancel()
            request.sendTask?.cancel()
            request.continuation.resume(throwing: RinaTransportError.invalidResponse)
            return
        }
        request.accumulated.append(frame.payload)
        if request.aggregateMore, frame.isMore {
            return
        }
        pending.removeValue(forKey: frame.seq)
        request.timeoutTask.cancel()
        if frame.isError {
            let err = (try? JSONDecoder().decode(RinaLinkError.self, from: request.accumulated))
                ?? RinaLinkError(error: "unknown error")
            request.continuation.resume(throwing: err)
        } else {
            // H1: propagate the terminal frame's flags (e.g. MORE meaning "call
            // again with a higher offset") instead of hardcoding 0.
            request.continuation.resume(returning: RinaLinkFrame(type: frame.type, seq: frame.seq, flags: frame.flags, payload: request.accumulated))
        }
    }

    /// Fails every currently-pending request with `error`, quarantining each
    /// seq non-recoverably (never fires `onQuarantineOverflow`).
    func failAll(_ error: Error) {
        for (seq, request) in pending {
            quarantine(seq, request: request, recover: false)
            request.timeoutTask.cancel()
            request.sendTask?.cancel()
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    private func nextSequenceNumber() throws -> UInt8 {
        // Skip seq values still awaiting a reply, or still quarantined from a
        // recent timeout, so a wraparound can't collide with an in-flight (or
        // still-possibly-replying) request.
        var candidate = nextSeq
        var attempts = 0
        while pending[candidate] != nil || quarantinedSeqs[candidate] != nil, attempts < 255 {
            candidate = candidate == 255 ? 1 : candidate + 1
            attempts += 1
        }
        guard pending[candidate] == nil, quarantinedSeqs[candidate] == nil else {
            throw RinaTransportError.sequenceSpaceExhausted
        }
        nextSeq = candidate == 255 ? 1 : candidate + 1
        return candidate
    }

    private func quarantine(_ seq: UInt8, request: PendingRequest, recover: Bool = true) {
        quarantineEventCount += 1
        quarantinedSeqs[seq] = QuarantinedRequest(replyType: request.replyType,
                                                aggregateMore: request.aggregateMore)
        guard recover, quarantinedSeqs.count >= Self.quarantineReconnectThreshold else { return }
        onQuarantineOverflow?()
    }

    private func removePending(seq: UInt8, requestID: UUID) -> PendingRequest? {
        guard pending[seq]?.id == requestID else { return nil }
        return pending.removeValue(forKey: seq)
    }

    private func cancelPending(seq: UInt8, requestID: UUID) {
        guard let request = removePending(seq: seq, requestID: requestID) else { return }
        request.timeoutTask.cancel()
        request.sendTask?.cancel()
        quarantine(seq, request: request)
        request.continuation.resume(throwing: CancellationError())
    }
}
