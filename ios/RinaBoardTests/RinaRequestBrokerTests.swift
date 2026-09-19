import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class RinaRequestBrokerTests: XCTestCase {
    /// Drives `broker.request(...)` with a capturing `write` that records the
    /// encoded frame and never throws, returning the allocated seq.
    private func send(
        _ broker: RinaRequestBroker,
        replyType: UInt8,
        aggregateMore: Bool,
        timeout: TimeInterval = 5,
        sentSeqs: SentSeqBox
    ) -> Task<RinaLinkFrame, Error> {
        Task { @MainActor in
            try await broker.request(
                replyType: replyType,
                aggregateMore: aggregateMore,
                timeout: timeout,
                encode: { seq in
                    sentSeqs.seqs.append(seq)
                    return Data([seq])
                },
                write: { _ in },
                onWriteFailure: { _ in }
            )
        }
    }

    /// Box so the synchronous `encode` closure above can report which seq it
    /// was allocated back to the test.
    private final class SentSeqBox {
        var seqs: [UInt8] = []
    }

    func testQuarantinedAggregateMoreSeqSurvivesMoreChunksUntilTerminal() async throws {
        let broker = RinaRequestBroker()
        let sent = SentSeqBox()
        let task = send(broker, replyType: 0x82, aggregateMore: true, timeout: 0.01, sentSeqs: sent)
        try await Task.sleep(for: .milliseconds(50))
        do { _ = try await task.value; XCTFail("expected timeout") } catch RinaTransportError.timeout {}
        let seq = try XCTUnwrap(sent.seqs.first)
        XCTAssertEqual(broker.quarantinedSequenceCount, 1)

        broker.deliver(RinaLinkFrame(type: 0x82, seq: seq, flags: RinaLinkFrameConstants.flagMore, payload: Data([1])))
        XCTAssertEqual(broker.quarantinedSequenceCount, 1)
        broker.deliver(RinaLinkFrame(type: 0x82, seq: seq, flags: RinaLinkFrameConstants.flagMore, payload: Data([2])))
        XCTAssertEqual(broker.quarantinedSequenceCount, 1)
        broker.deliver(RinaLinkFrame(type: 0x82, seq: seq, flags: 0, payload: Data([3])))
        XCTAssertEqual(broker.quarantinedSequenceCount, 0)
    }

    func testQuarantinedNonAggregateSeqReleasedByFirstFrameEvenWithMore() async throws {
        let broker = RinaRequestBroker()
        let sent = SentSeqBox()
        let task = send(broker, replyType: 0x82, aggregateMore: false, timeout: 0.01, sentSeqs: sent)
        try await Task.sleep(for: .milliseconds(50))
        do { _ = try await task.value; XCTFail("expected timeout") } catch RinaTransportError.timeout {}
        let seq = try XCTUnwrap(sent.seqs.first)
        XCTAssertEqual(broker.quarantinedSequenceCount, 1)

        broker.deliver(RinaLinkFrame(type: 0x82, seq: seq, flags: RinaLinkFrameConstants.flagMore, payload: Data([1])))
        XCTAssertEqual(broker.quarantinedSequenceCount, 0)
    }

    func testQuarantinedSeqReleasedByErrorFrameOfDifferentType() async throws {
        let broker = RinaRequestBroker()
        let sent = SentSeqBox()
        let task = send(broker, replyType: 0x82, aggregateMore: true, timeout: 0.01, sentSeqs: sent)
        try await Task.sleep(for: .milliseconds(50))
        do { _ = try await task.value; XCTFail("expected timeout") } catch RinaTransportError.timeout {}
        let seq = try XCTUnwrap(sent.seqs.first)
        XCTAssertEqual(broker.quarantinedSequenceCount, 1)

        broker.deliver(RinaLinkFrame(type: RinaLinkMessageType.error.rawValue, seq: seq, flags: 0,
                                     payload: try JSONEncoder().encode(RinaLinkError(error: "nope"))))
        XCTAssertEqual(broker.quarantinedSequenceCount, 0)
    }

    func testWrongNonErrorTypeIsDroppedAndRequestStaysPending() async throws {
        let broker = RinaRequestBroker()
        let sent = SentSeqBox()
        let task = send(broker, replyType: 0x82, aggregateMore: true, timeout: 5, sentSeqs: sent)
        try await Task.sleep(for: .milliseconds(20))
        let seq = try XCTUnwrap(sent.seqs.first)

        // A frame with the right seq but a type that is neither the expected
        // reply type nor an error must be silently dropped.
        broker.deliver(RinaLinkFrame(type: 0x50, seq: seq, flags: 0, payload: Data([9])))
        // The request is still pending: it now completes normally.
        broker.deliver(RinaLinkFrame(type: 0x82, seq: seq, flags: 0, payload: Data([7])))
        let reply = try await task.value
        XCTAssertEqual(reply.payload, Data([7]))
    }

    func testCrossingThresholdOnRecoverablePathFiresOverflowFailAllDoesNot() async throws {
        // Reaching quarantineReconnectThreshold (128) via real timeouts would
        // need 128 short-timeout requests; use a handful of ms-scale timeouts
        // in a tight loop, which is fast and still exercises the real path
        // rather than adding a test-only hook to production code.
        let broker = RinaRequestBroker()
        var overflowCount = 0
        broker.onQuarantineOverflow = { overflowCount += 1 }

        var tasks: [Task<RinaLinkFrame, Error>] = []
        for _ in 0..<128 {
            let sent = SentSeqBox()
            tasks.append(send(broker, replyType: 0x82, aggregateMore: true, timeout: 0.001, sentSeqs: sent))
            // Let this request register and time out before the next one;
            // the quarantined seqs accumulate to exactly the threshold.
            try await Task.sleep(for: .milliseconds(3))
        }
        for task in tasks {
            do { _ = try await task.value } catch {}
        }
        XCTAssertGreaterThanOrEqual(overflowCount, 1)

        let broker2 = RinaRequestBroker()
        var overflowCount2 = 0
        broker2.onQuarantineOverflow = { overflowCount2 += 1 }
        // failAll's quarantine is non-recoverable and must never fire the hook,
        // regardless of how many requests it quarantines.
        var tasks2: [Task<RinaLinkFrame, Error>] = []
        for _ in 0..<128 {
            let sent = SentSeqBox()
            tasks2.append(send(broker2, replyType: 0x82, aggregateMore: true, timeout: 30, sentSeqs: sent))
            try await Task.sleep(for: .milliseconds(1))
        }
        broker2.failAll(RinaTransportError.notConnected)
        for task in tasks2 {
            do { _ = try await task.value } catch {}
        }
        XCTAssertEqual(overflowCount2, 0)
    }

    func testErrorReplyAcrossMoreChunksDecodesAccumulatedPayload() async throws {
        let broker = RinaRequestBroker()
        let sent = SentSeqBox()
        let task = send(broker, replyType: 0x82, aggregateMore: true, timeout: 5, sentSeqs: sent)
        try await Task.sleep(for: .milliseconds(20))
        let seq = try XCTUnwrap(sent.seqs.first)

        let fullError = RinaLinkError(error: "chunked failure", code: 500)
        let encoded = try JSONEncoder().encode(fullError)
        let mid = encoded.count / 2
        let firstHalf = encoded.prefix(mid)
        let secondHalf = encoded.suffix(from: mid)

        broker.deliver(RinaLinkFrame(type: RinaLinkMessageType.error.rawValue, seq: seq,
                                     flags: RinaLinkFrameConstants.flagMore, payload: Data(firstHalf)))
        broker.deliver(RinaLinkFrame(type: RinaLinkMessageType.error.rawValue, seq: seq,
                                     flags: 0, payload: Data(secondHalf)))
        do {
            _ = try await task.value
            XCTFail("expected error reply")
        } catch let error as RinaLinkError {
            XCTAssertEqual(error.error, "chunked failure")
            XCTAssertEqual(error.code, 500)
        }
    }

    func testLateReplyAfterCancellationDoesNotResumeTwiceOrResolveNewerRequest() async throws {
        let broker = RinaRequestBroker()
        let sent1 = SentSeqBox()
        let task = send(broker, replyType: 0x82, aggregateMore: true, timeout: 30, sentSeqs: sent1)
        try await Task.sleep(for: .milliseconds(20))
        let retiredSeq = try XCTUnwrap(sent1.seqs.first)

        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}

        // A late reply for the cancelled (now quarantined) seq must not crash
        // or resolve anything.
        broker.deliver(RinaLinkFrame(type: 0x82, seq: retiredSeq, flags: 0, payload: Data([1])))

        // A newer request that is assigned a different seq must resolve on
        // its own reply only, never on the stale one above.
        let sent2 = SentSeqBox()
        let fresh = send(broker, replyType: 0x82, aggregateMore: true, timeout: 5, sentSeqs: sent2)
        try await Task.sleep(for: .milliseconds(20))
        let freshSeq = try XCTUnwrap(sent2.seqs.first)
        XCTAssertNotEqual(freshSeq, retiredSeq)
        broker.deliver(RinaLinkFrame(type: 0x82, seq: freshSeq, flags: 0, payload: Data([42])))
        let reply = try await fresh.value
        XCTAssertEqual(reply.payload, Data([42]))
    }
}
