import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class FacesTransferTests: XCTestCase {
    func testConcurrentLibraryReadersShareOneDownloadAndDoNotSendDisplayFrames() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let first = Task { try await connection.getFaces() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        let second = Task { try await connection.getFaces() }
        // Let the second waiter join before replying to the first page.
        for _ in 0..<20 { await Task.yield() }
        let document = try FaceDocument().encoded()
        transport.replyToNext(type: .getFaces, payload: Data([7,0,0,0]) + document)
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a, document)
        XCTAssertEqual(b, document)
        XCTAssertEqual(transport.sentFrames(type: .getFaces).count, 1)
        XCTAssertEqual(transport.sentFrames(type: .setFrame).count, 0)
    }

    func testUnchangedLibraryUsesBoardConfirmedCachedDocument() async throws {
        let transport = FakeRinaTransport()
        transport.commandReply = ["ok": true, "defaultName": "RinaBoard-80B54EF74801", "bootId": "same-boot", "caps": ["faces_conditional_read_v1"]]
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let document = try FaceDocument().encoded()
        let first = Task { try await connection.getFaces() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: Data([4,0,0,0]) + document)
        _ = try await first.value
        transport.resetRecordedFrames()
        let second = Task { try await connection.getFaces() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        let request = try XCTUnwrap(transport.lastSent(type: .getFaces))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
        XCTAssertEqual(fields["ifUnchanged"] as? Bool, true)
        XCTAssertEqual(fields["gen"] as? Int, 4)
        XCTAssertEqual(fields["bootId"] as? String, "same-boot")
        transport.replyToNext(type: .getFaces, payload: Data([4,0,0,0]))
        let result = try await second.value
        XCTAssertEqual(result, document)
        XCTAssertEqual(connection.currentFacesGeneration, 4)
    }

    func testConditionalUpsertKeepsExplicitEditorVersionAndCreateOnly() async throws {
        let transport = FakeRinaTransport()
        transport.commandReply = ["ok": true, "bootId": "original", "caps": ["faces_conditional_v1", "faces_parts_v4"]]
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetRecordedFrames()
        let face = FaceUpsertPayload(id: "stable", name: "Test", type: "custom",
                                     frameHex: PackedFrame().hex94)
        _ = try await connection.faceUpsert(face, createOnly: true, expectedBootId: "editing-boot", expectedGen: 8)
        let frame = try XCTUnwrap(transport.sentFrames(type: .cmd).last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        let payload = json
        XCTAssertEqual(payload["expectedBootId"] as? String, "editing-boot")
        XCTAssertEqual(payload["expectedGen"] as? Int, 8)
        XCTAssertEqual(payload["createOnly"] as? Bool, true)
    }

    /// The status event already reports the library generation, so a write
    /// with no loaded document must not download the whole library for it.
    func testWriteWithoutLoadedLibraryTakesGenerationFromStatus() async throws {
        let transport = FakeRinaTransport()
        transport.commandReply = ["ok": true, "bootId": "boot-a", "caps": ["faces_conditional_v1"]]
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.emitEvent(type: .evStatus, json: ["ok": true, "v": 2, "facesGeneration": 5])
        for _ in 0..<200 where connection.boardFacesGeneration != 5 { await Task.yield() }
        XCTAssertEqual(connection.boardFacesGeneration, 5)
        transport.resetRecordedFrames()
        _ = try await connection.faceRename(id: "user_a", name: "B")
        XCTAssertEqual(transport.sentFrames(type: .getFaces).count, 0)
        let frame = try XCTUnwrap(transport.sentFrames(type: .cmd).last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        XCTAssertEqual(json["expectedGen"] as? Int, 5)
        XCTAssertEqual(json["expectedBootId"] as? String, "boot-a")
    }

    /// Another client's write shows up as a status generation ahead of the
    /// one this connection read.
    func testStatusGenerationAheadOfLoadedLibraryMarksItStale() async throws {
        let transport = FakeRinaTransport()
        transport.commandReply = ["ok": true, "bootId": "boot-a", "caps": ["faces_conditional_v1"]]
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.automaticallyReplies = false
        let read = Task { try await connection.getFaces() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: Data([4,0,0,0]) + (try FaceDocument().encoded()))
        _ = try await read.value
        transport.emitEvent(type: .evStatus, json: ["ok": true, "v": 3, "facesGeneration": 4])
        for _ in 0..<200 where connection.boardFacesGeneration != 4 { await Task.yield() }
        XCTAssertFalse(connection.facesDocumentIsStale)
        transport.emitEvent(type: .evStatus, json: ["ok": true, "v": 4, "facesGeneration": 5])
        for _ in 0..<200 where connection.boardFacesGeneration != 5 { await Task.yield() }
        XCTAssertTrue(connection.facesDocumentIsStale)
    }

    /// The board sends a write's reply and the status it causes back to back;
    /// over TCP they can share one read, and the status is applied before the
    /// awaiting write resumes. Our own write must not look like another
    /// client's (that would download the whole library again).
    func testOwnWriteWhoseStatusSharesTheReplyReadIsNotStale() async throws {
        let transport = FakeRinaTransport()
        transport.commandReply = ["ok": true, "bootId": "boot-a", "caps": ["faces_conditional_v1"]]
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.automaticallyReplies = false
        let read = Task { try await connection.getFaces() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: Data([4,0,0,0]) + (try FaceDocument().encoded()))
        _ = try await read.value
        transport.resetRecordedFrames()
        let rename = Task { try await connection.faceRename(id: "user_a", name: "B") }
        try await transport.waitForSent(type: .cmd, count: 1)
        let request = try XCTUnwrap(transport.lastSent(type: .cmd))
        let reply = try JSONSerialization.data(withJSONObject: ["ok": true, "v": 5, "gen": 5, "count": 1])
        let status = try JSONSerialization.data(withJSONObject: ["ok": true, "v": 5, "facesGeneration": 5])
        transport.emitInOneRead([
            RinaLinkFrame(type: RinaLinkMessageType.cmd.replyType, seq: request.seq, flags: 0, payload: reply),
            RinaLinkFrame(type: RinaLinkMessageType.evStatus.rawValue, seq: 0, flags: 0, payload: status),
        ])
        var sawStale = false
        for _ in 0..<500 where connection.boardFacesGeneration != 5 || connection.currentFacesGeneration != 5 {
            sawStale = sawStale || connection.facesDocumentIsStale
            await Task.yield()
        }
        sawStale = sawStale || connection.facesDocumentIsStale
        _ = try await rename.value
        XCTAssertEqual(connection.currentFacesGeneration, 5)
        XCTAssertFalse(sawStale)
        XCTAssertFalse(connection.facesDocumentIsStale)
    }
}
