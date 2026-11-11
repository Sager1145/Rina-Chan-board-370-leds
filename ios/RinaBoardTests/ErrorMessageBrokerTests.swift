import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// An error frame whose payload is not a well-formed `RinaLinkError` must
/// still surface what the board said, never a placeholder.
@MainActor
final class ErrorMessageBrokerTests: XCTestCase {
    private final class SentSeqBox {
        var seqs: [UInt8] = []
    }

    /// Sends one request, answers it with an error frame carrying `payload`,
    /// and returns the error the request threw.
    private func errorThrown(forErrorFramePayload payload: Data) async throws -> RinaLinkError {
        let broker = RinaRequestBroker()
        let sent = SentSeqBox()
        let task = Task { @MainActor in
            try await broker.request(
                replyType: 0x82,
                aggregateMore: true,
                timeout: 5,
                encode: { seq in
                    sent.seqs.append(seq)
                    return Data([seq])
                },
                write: { _ in },
                onWriteFailure: { _ in }
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let seq = try XCTUnwrap(sent.seqs.first)
        broker.deliver(RinaLinkFrame(type: RinaLinkMessageType.error.rawValue, seq: seq, flags: 0, payload: payload))
        do {
            _ = try await task.value
            XCTFail("expected the request to fail")
            throw RinaTransportError.invalidResponse
        } catch let error as RinaLinkError {
            return error
        }
    }

    func testTruncatedErrorFrameKeepsTheBoardText() async throws {
        let error = try await errorThrown(forErrorFramePayload: Data(#"{"ok":false,"error":"flash write fai"#.utf8))
        XCTAssertNotEqual(error.error, "unknown error")
        XCTAssertTrue(error.error.contains("flash write fai"))
        XCTAssertTrue(RinaErrorText.message(for: error).contains("flash write fai"))
    }

    func testErrorFrameWithLooseFieldsKeepsTextAndCode() async throws {
        let error = try await errorThrown(forErrorFramePayload: Data(#"{"message":"flash busy","code":503}"#.utf8))
        XCTAssertEqual(error, RinaLinkError(error: "flash busy", code: 503))
        let message = RinaErrorText.message(for: error)
        XCTAssertTrue(message.contains("flash busy"))
        XCTAssertTrue(message.contains("503"))
    }

    func testPlainTextErrorFrameIsUsedAsTheBoardText() async throws {
        let error = try await errorThrown(forErrorFramePayload: Data("  out of heap\n".utf8))
        XCTAssertEqual(error.error, "out of heap")
        XCTAssertNil(error.code)
    }

    func testEmptyOrBinaryErrorFrameReportsAnUnknownBoardError() async throws {
        for payload in [Data(), Data([0xFF, 0xFE, 0x80])] {
            let error = try await errorThrown(forErrorFramePayload: payload)
            XCTAssertEqual(error.error, "")
            XCTAssertNil(error.code)
            XCTAssertEqual(RinaErrorText.message(for: error), RinaErrorText.boardMessage(nil, code: nil))
            XCTAssertFalse(RinaErrorText.message(for: error).isEmpty)
        }
    }

    func testWellFormedErrorFrameIsUnchanged() async throws {
        let original = RinaLinkError(error: "unexpected chunk offset", code: 400, expectedOffset: 94)
        let error = try await errorThrown(forErrorFramePayload: try JSONEncoder().encode(original))
        XCTAssertEqual(error, original)
    }
}
