import XCTest
import RinaCore
@testable import RinaBoard

/// A board rejection is a known outcome, and a journaled direct create must
/// not outlive the point where it can still be reconciled.
@MainActor
final class Fix44FacesTests: XCTestCase {
    func testLibraryFullRejectionFailsWithTheBoardsReasonAndLeavesNoPendingSave() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        editor.livePreview = false
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.toggle(led: 7, connection: connection)
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()

        let saving = Task { await editor.saveEditedFace(name: "One too many", asNew: true, to: .board,
                                                        library: library, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        try reject(transport, code: 413, error: "too many faces; firmware max is 128")
        let saved = await saving.value

        XCTAssertFalse(saved)
        XCTAssertEqual(library.errorMessage, "too many faces; firmware max is 128")
        XCTAssertFalse(editor.hasPendingBoardSave)
        XCTAssertEqual(transport.sentCount(type: .cmd), 1)
        XCTAssertEqual(transport.sentCount(type: .getFaces), 0)
    }

    func testRejectedDirectCreateIsNotKeptInTheJournal() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let source = sourceFace()
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()

        let copy = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let id = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        try reject(transport, code: 413, error: "too many faces; firmware max is 128")
        let outcome = await copy.value

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(library.errorMessage, "too many faces; firmware max is 128")
        let journal = try await journalText()
        XCTAssertFalse(journal.contains(id), "A create the board refused has nothing left to reconcile")
    }

    func testRenamedPendingCopyDoesNotBlockAnotherCopyOfTheSameFace() async throws {
        let (connection, transport) = await connectedBoard(caps: ["faces_conditional_v1"])
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let source = sourceFace()
        try await reload(library, connection, transport, faces: [source], gen: 1)

        // The first copy commits, but its readback is lost: the result is pending.
        transport.resetRecordedFrames()
        let first = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let firstID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        let firstName = try XCTUnwrap(try facePayload(transport)["name"] as? String)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])
        try await transport.waitForSent(type: .getFaces, count: 1)
        try reject(transport, type: .getFaces, code: 503, error: "readback unavailable")
        guard case .pending = await first.value else { return XCTFail("expected pending first copy") }

        // The copy is on the board and has been renamed since, so its old
        // name is free again and the next copy asks for exactly the same face.
        let renamed = SavedFace(id: firstID, name: "Renamed " + UUID().uuidString, type: .custom,
                                frameBytes: source.frameBytes, order: 2)
        try await reload(library, connection, transport, faces: [source, renamed], gen: 2)

        transport.resetRecordedFrames()
        let second = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(2) + (try FaceDocument(faces: [source, renamed]).encoded()))
        try await transport.waitForSent(type: .cmd, count: 1)
        let secondID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertEqual(try facePayload(transport)["name"] as? String, firstName)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 3])
        try await transport.waitForSent(type: .getFaces, count: 2)
        let secondCopy = SavedFace(id: secondID, name: firstName, type: .custom,
                                   frameBytes: source.frameBytes, order: 3)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(3) + (try FaceDocument(faces: [source, renamed, secondCopy]).encoded()))
        let outcome = await second.value

        XCTAssertEqual(outcome, .saved(id: secondID))
        XCTAssertEqual(library.face(id: firstID, in: .board)?.name, renamed.name)
        let journal = try await journalText()
        XCTAssertFalse(journal.contains(firstID), "A create that landed and was renamed must not stay pending")
        XCTAssertFalse(journal.contains(secondID))
    }

    /// Without `faces_conditional_v1` the old id cannot be retried, but one
    /// warning must be enough: the following attempt is a new create.
    func testLegacyFirmwareAbsentPendingCopyIsRefusedOnceThenCreatedAnew() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let source = sourceFace()
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()

        // A 5xx leaves the outcome unknown, so this create stays journaled.
        let first = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let firstID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        let name = try XCTUnwrap(try facePayload(transport)["name"] as? String)
        try reject(transport, code: 503, error: "unknown outcome")
        guard case .pending = await first.value else { return XCTFail("expected pending first copy") }

        // The board is read and does not hold it: refused, without a write.
        let board = prefix(1) + (try FaceDocument(faces: [source]).encoded())
        transport.resetRecordedFrames()
        let second = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: board)
        let refused = await second.value
        XCTAssertEqual(refused, .pending(id: firstID))
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(transport.sentCount(type: .cmd), 0)

        transport.resetRecordedFrames()
        let third = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let thirdID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        XCTAssertNotEqual(thirdID, firstID)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let copy = SavedFace(id: thirdID, name: name, type: .custom,
                             frameBytes: source.frameBytes, order: 2)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(2) + (try FaceDocument(faces: [source, copy]).encoded()))
        let outcome = await third.value

        XCTAssertEqual(outcome, .saved(id: thirdID))
        let journal = try await journalText()
        XCTAssertFalse(journal.contains(firstID))
        XCTAssertFalse(journal.contains(thirdID))
    }

    private func sourceFace() -> SavedFace {
        var frame = PackedFrame(); frame.set(11)
        return SavedFace(id: "fix44-src-" + UUID().uuidString, name: UUID().uuidString, type: .custom,
                         frameBytes: frame.bytes.map(Int.init), order: 1)
    }

    private func journalText() async throws -> String {
        let journal = try await DraftStorage.shared.read("board_face_creates") ?? Data("[]".utf8)
        return String(decoding: journal, as: UTF8.self)
    }

    private func connectedBoard(caps: [String] = []) async -> (BoardConnection, FakeRinaTransport) {
        let transport = FakeRinaTransport(kind: .bluetooth)
        transport.commandReply = ["ok": true, "bootId": "1234abcd", "caps": caps]
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func reload(_ library: FaceLibraryModel, _ connection: BoardConnection,
                        _ transport: FakeRinaTransport, faces: [SavedFace], gen: UInt32) async throws {
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let loading = Task { await library.reload(connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(gen) + (try FaceDocument(faces: faces).encoded()))
        let loaded = await loading.value
        XCTAssertTrue(loaded)
    }

    /// Answers the last request of `type` with a board error frame.
    private func reject(_ transport: FakeRinaTransport, type: RinaLinkMessageType = .cmd,
                        code: Int, error: String) throws {
        let request = try XCTUnwrap(transport.lastSent(type: type))
        transport.emitReply(type: .error, seq: request.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": code, "error": error]))
    }

    private func facePayload(_ transport: FakeRinaTransport) throws -> [String: Any] {
        let request = try XCTUnwrap(transport.lastSent(type: .cmd))
        let command = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
        XCTAssertEqual(command["cmd"] as? String, "face_upsert")
        return try XCTUnwrap(command["face"] as? [String: Any])
    }

    private func prefix(_ value: UInt32) -> Data {
        Data([UInt8(value & 255), UInt8((value >> 8) & 255),
              UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)])
    }
}
