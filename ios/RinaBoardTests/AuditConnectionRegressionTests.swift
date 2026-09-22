import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class AuditConnectionRegressionTests: XCTestCase {
    func testQueuedCommandCannotCrossCarrierReplacement() async throws {
        let connection = BoardConnection()
        let old = FakeRinaTransport()
        _ = await connection.connect(using: old)
        old.resetRecordedFrames()
        old.holdNextTransportSend()
        let first = Task { try await connection.command(.setBrightness(raw: 10)) }
        try await old.waitForHeldTransportSend()
        let queued = Task { try await connection.command(.setBrightness(raw: 20)) }
        // Let the second call enter the command pump while the first owns it.
        for _ in 0..<20 { await Task.yield() }
        let fresh = FakeRinaTransport()
        _ = await connection.connect(using: fresh)
        fresh.resetRecordedFrames()
        old.releaseHeldTransportSend()
        _ = try? await first.value
        do {
            _ = try await queued.value
            XCTFail("Old queued command must be cancelled")
        } catch is CancellationError { }
        XCTAssertEqual(fresh.sentCount(type: .cmd), 0)
    }

    func testQueuedFaceDeletionCannotCrossCarrierReplacement() async throws {
        let connection = BoardConnection()
        let old = FakeRinaTransport()
        _ = await connection.connect(using: old)
        old.resetRecordedFrames()
        old.holdNextTransportSend()
        let first = Task { try await connection.command(.setBrightness(raw: 10)) }
        try await old.waitForHeldTransportSend()
        let queued = Task { try await connection.faceDelete(id: "custom_old_board") }
        // Let the second call enter the command pump while the first owns it.
        for _ in 0..<20 { await Task.yield() }
        let fresh = FakeRinaTransport()
        _ = await connection.connect(using: fresh)
        fresh.resetRecordedFrames()
        old.releaseHeldTransportSend()
        _ = try? await first.value
        do {
            _ = try await queued.value
            XCTFail("Old queued command must be cancelled")
        } catch is CancellationError { }
        XCTAssertEqual(fresh.sentCount(type: .cmd), 0)
    }

    func testQueuedBlobCannotBeginOrAbortOnReplacementCarrier() async throws {
        let connection = BoardConnection()
        let old = FakeRinaTransport()
        _ = await connection.connect(using: old)
        old.resetRecordedFrames()
        old.holdNextTransportSend()
        let first = Task { try await connection.uploadBlob(kind: .faces, meta: [:], data: Data([1])) }
        try await old.waitForHeldTransportSend()
        let queued = Task { try await connection.uploadBlob(kind: .faces, meta: [:], data: Data([2])) }
        for _ in 0..<20 { await Task.yield() }
        let fresh = FakeRinaTransport()
        _ = await connection.connect(using: fresh)
        fresh.resetRecordedFrames()
        old.releaseHeldTransportSend()
        _ = try? await first.value
        do {
            _ = try await queued.value
            XCTFail("Old queued upload must be cancelled")
        } catch is CancellationError { }
        XCTAssertEqual(fresh.sentCount(type: .blobBegin), 0)
        XCTAssertEqual(fresh.sentCount(type: .blobAbort), 0)
    }

    func testShortSecondFacesPageFailsInsteadOfReturningPartialDocument() async throws {
        for byteCount in [0, 1, 3] {
            let connection = BoardConnection()
            let transport = FakeRinaTransport()
            _ = await connection.connect(using: transport)
            transport.resetRecordedFrames()
            transport.automaticallyReplies = false
            let request = Task { try await connection.getFaces() }
            try await transport.waitForSent(type: .getFaces, count: 1)
            transport.replyToNext(type: .getFaces, payload: Data([42, 0, 0, 0, 123]),
                                  flags: RinaLinkFrameConstants.flagMore)
            try await transport.waitForSent(type: .getFaces, count: 2)
            transport.replyToNext(type: .getFaces, payload: Data(repeating: 0, count: byteCount))
            do {
                _ = try await request.value
                XCTFail("Short page must fail")
            } catch RinaTransportError.invalidResponse { }
            connection.disconnect()
        }
    }

    func testBlobRejectsAcknowledgementBeyondSentChunk() async throws {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        _ = await connection.connect(using: transport)
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let upload = Task { try await connection.uploadBlob(kind: .faces, meta: [:], data: Data(repeating: 1, count: 94)) }
        try await transport.waitForSent(type: .blobBegin, count: 1)
        transport.replyToNext(type: .blobBegin, json: ["offset": 0, "chunkMax": 47])
        try await transport.waitForSent(type: .blobChunk, count: 1)
        transport.replyToNext(type: .blobChunk, json: ["offset": 94])
        try await transport.waitForSent(type: .blobAbort, count: 1)
        transport.replyToNext(type: .blobAbort, json: ["ok": true])
        do {
            _ = try await upload.value
            XCTFail("ACK must match the submitted chunk end")
        } catch RinaTransportError.invalidResponse { }
        XCTAssertEqual(transport.sentCount(type: .blobEnd), 0)
    }

    func testReliableCommandRejectsNormalNegativeReply() async throws {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        _ = await connection.connect(using: transport)
        transport.commandReply = ["ok": false]
        do {
            _ = try await connection.requestReliable(.setBrightness(raw: 10))
            XCTFail("Business rejection must throw")
        } catch RinaTransportError.underlying { }
    }
}
