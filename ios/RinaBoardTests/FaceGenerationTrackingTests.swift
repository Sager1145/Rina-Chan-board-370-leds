import XCTest
import RinaCore
@testable import RinaBoard

/// `FaceLibraryModel` applies a face write in place instead of re-reading the
/// whole library only when the reply's generation is exactly one past the
/// generation the model shows. Otherwise another writer — the WebUI, another
/// phone, or another model on this same connection — may have changed
/// `saved_faces.json` underneath it.
@MainActor
final class FaceGenerationTrackingTests: XCTestCase {
    private func connectedBoard() async -> (BoardConnection, FakeRinaTransport) {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func genPrefix(_ gen: UInt32) -> Data {
        var bytes = Data(count: 4)
        bytes[0] = UInt8(gen & 0xFF)
        bytes[1] = UInt8((gen >> 8) & 0xFF)
        bytes[2] = UInt8((gen >> 16) & 0xFF)
        bytes[3] = UInt8((gen >> 24) & 0xFF)
        return bytes
    }

    private let u1 = SavedFace(id: "u1", name: "U1", type: .custom,
                               frameBytes: PackedFrame().bytes.map(Int.init), order: 1)

    /// A model showing the library read at `gen`.
    private func loadModel(_ connection: BoardConnection, _ transport: FakeRinaTransport,
                           gen: UInt32) async throws -> FaceLibraryModel {
        let model = FaceLibraryModel()
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let loading = Task { await model.reload(connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: genPrefix(gen) + (try FaceDocument(faces: [u1]).encoded()))
        let loaded = await loading.value
        XCTAssertTrue(loaded)
        transport.automaticallyReplies = true
        return model
    }

    /// Renames u1 with a reply carrying `gen` (none when nil) and reports
    /// whether the model read the library back instead of patching it.
    private func renameReadsBack(_ model: FaceLibraryModel, replyGen gen: Int?,
                                 _ connection: BoardConnection, _ transport: FakeRinaTransport) async throws -> Bool {
        let face = try XCTUnwrap(model.face(id: "u1", in: .board))
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let renaming = Task { await model.rename(face, to: "U1 \(UUID().uuidString.prefix(4))", in: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        var reply: [String: Any] = ["ok": true]
        if let gen { reply["gen"] = gen }
        // A readback, if any, gets an unusable automatic reply instead of hanging.
        transport.automaticallyReplies = true
        transport.replyToNext(type: .cmd, json: reply)
        _ = await renaming.value
        return !transport.sentFrames(type: .getFaces).isEmpty
    }

    func testReplyOneGenerationPastTheShownLibraryIsAppliedInPlace() async throws {
        let (connection, transport) = await connectedBoard()
        let model = try await loadModel(connection, transport, gen: 5)
        let readBack = try await renameReadsBack(model, replyGen: 6, connection, transport)
        XCTAssertFalse(readBack, "gen 6 straight after showing gen 5 is this model's own write")
        XCTAssertEqual(model.boardFacesGen, 6)
    }

    func testGenerationJumpFromAnotherClientReadsBack() async throws {
        let (connection, transport) = await connectedBoard()
        let model = try await loadModel(connection, transport, gen: 5)
        let readBack = try await renameReadsBack(model, replyGen: 9, connection, transport)
        XCTAssertTrue(readBack, "someone else mutated the document")
    }

    /// Firmware that reports no `gen` cannot support the check.
    func testReplyWithoutAGenerationReadsBack() async throws {
        let (connection, transport) = await connectedBoard()
        let model = try await loadModel(connection, transport, gen: 5)
        let readBack = try await renameReadsBack(model, replyGen: nil, connection, transport)
        XCTAssertTrue(readBack)
    }

    /// Another model on the same connection (a multi-board save target, the
    /// editor) wrote in between. The connection's own generation advanced with
    /// it, so only the generation the model shows can tell.
    func testWriteByAnotherModelOnTheSameConnectionReadsBack() async throws {
        let (connection, transport) = await connectedBoard()
        let model = try await loadModel(connection, transport, gen: 5)
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let other = Task { try await connection.faceDelete(id: "x") }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 6])
        _ = try await other.value
        transport.automaticallyReplies = true
        let readBack = try await renameReadsBack(model, replyGen: 7, connection, transport)
        XCTAssertTrue(readBack, "the model shows gen 5; gen 7 hides another write")
    }

    /// A generation only means something inside the carrier that reported it.
    func testGenerationIsForgottenWhenTheCarrierStops() async throws {
        let (connection, transport) = await connectedBoard()
        _ = try await loadModel(connection, transport, gen: 5)
        XCTAssertEqual(connection.currentFacesGeneration, 5)
        connection.disconnect()
        let reconnected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(reconnected)
        XCTAssertNil(connection.currentFacesGeneration,
                     "the pre-disconnect generation must not survive the carrier")
    }

    // MARK: R07 — a board switch mid-flight must not overwrite the new board's state

    private func wifiBoard(host: String) async -> (BoardConnection, FakeRinaTransport) {
        let connection = BoardConnection()
        let transport = FakeRinaTransport(kind: .wifi(host: host, port: RinaLinkConstants.tcpPort))
        transport.commandReply = ["ok": true, "gen": 1]
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    /// Loads `faces` into `model` as `connection`'s board library.
    private func scriptedReload(_ model: FaceLibraryModel, _ connection: BoardConnection,
                                _ transport: FakeRinaTransport, faces: [SavedFace]) async throws {
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let task = Task { await model.reload(connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: genPrefix(0) + (try FaceDocument(faces: faces).encoded()))
        _ = await task.value
        transport.automaticallyReplies = true
    }

    /// `FaceLibraryModel.rename`'s board-mutating await can outlive the board
    /// switch that made `connection` stale: a rename in flight on board A must
    /// not overwrite `faceDocument`/`boardID`/`boardGeneration`/`errorMessage`
    /// once the model has already moved on to board B (R07), even though the
    /// rename itself genuinely succeeded on A.
    func testStaleBoardSwitchDuringRenameDoesNotOverwriteTheNewBoardsState() async throws {
        let model = FaceLibraryModel()
        let (connectionA, transportA) = await wifiBoard(host: "board-a.local")
        let (connectionB, transportB) = await wifiBoard(host: "board-b.local")

        let faceA = SavedFace(id: "u1", name: "Original", type: .custom,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await scriptedReload(model, connectionA, transportA, faces: [faceA])

        transportA.resetRecordedFrames()
        transportA.automaticallyReplies = false
        let renameTask = Task { await model.rename(faceA, to: "Renamed", in: .board, connection: connectionA) }
        try await transportA.waitForSent(type: .cmd, count: 1)

        // The model switches to board B and reloads its library while A's
        // rename reply is still held back.
        model.synchronizeBoardGeneration(connectionB.connectionGeneration)
        let faceB = SavedFace(id: "b1", name: "Board B face", type: .custom,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await scriptedReload(model, connectionB, transportB, faces: [faceB])

        // Now release A's rename reply.
        transportA.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])
        let renamed = await renameTask.value
        transportA.automaticallyReplies = true

        XCTAssertTrue(renamed, "the rename itself succeeded on the old board")
        XCTAssertEqual(model.boardID, connectionB.boardKey)
        XCTAssertEqual(model.boardGeneration, connectionB.connectionGeneration)
        XCTAssertEqual(model.faceDocument.faces.map(\.id), ["b1"],
                       "board A's rename must not leak into board B's document")
        XCTAssertNil(model.errorMessage)
        connectionA.disconnect()
        connectionB.disconnect()
    }

    /// A whole-library upload has a second, implicit mutation: its follow-up
    /// reload. If board A's BLOB_END arrives after the model has moved to B,
    /// that reload must not start against A or replace B's published library
    /// (R02).
    func testStaleBoardSwitchDuringFaceImportDoesNotReloadTheOldBoard() async throws {
        let model = FaceLibraryModel()
        let (connectionA, transportA) = await wifiBoard(host: "board-a.local")
        let (connectionB, transportB) = await wifiBoard(host: "board-b.local")
        let faceA = SavedFace(id: "a1", name: "Imported A", type: .custom,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        let imported = try FaceDocument(faces: [faceA]).encoded()

        transportA.resetRecordedFrames()
        transportA.automaticallyReplies = false
        let importTask = Task {
            await model.importDocument(from: imported, to: .board, connection: connectionA)
        }
        try await transportA.waitForSent(type: .blobBegin, count: 1)
        let beginFrame = try XCTUnwrap(transportA.lastSent(type: .blobBegin))
        let beginJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: beginFrame.payload) as? [String: Any]
        )
        let totalBytes = try XCTUnwrap(beginJSON["totalBytes"] as? Int)

        model.synchronizeBoardGeneration(connectionB.connectionGeneration)
        let faceB = SavedFace(id: "b1", name: "Board B face", type: .custom,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await scriptedReload(model, connectionB, transportB, faces: [faceB])

        transportA.replyToNext(type: .blobBegin, json: ["ok": true, "offset": 0])
        var offset = 0
        var chunkCount = 0
        while offset < totalBytes {
            chunkCount += 1
            try await transportA.waitForSent(type: .blobChunk, count: chunkCount)
            let chunk = try XCTUnwrap(transportA.lastSent(type: .blobChunk))
            offset += chunk.payload.count - 4
            transportA.replyToNext(type: .blobChunk, json: ["ok": true, "offset": offset])
        }
        try await transportA.waitForSent(type: .blobEnd, count: 1)
        transportA.replyToNext(type: .blobEnd, json: ["ok": true])

        // If the stale import incorrectly starts GET_FACES, answer it so the
        // test fails on state/count assertions instead of hanging forever.
        let staleReloadResponder = Task { @MainActor in
            for _ in 0..<200 {
                if transportA.sentCount(type: .getFaces) > 0 {
                    transportA.replyToNext(type: .getFaces,
                                           payload: self.genPrefix(1) + (try! FaceDocument(faces: [faceA]).encoded()))
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        await importTask.value
        staleReloadResponder.cancel()
        _ = try? await staleReloadResponder.value

        XCTAssertEqual(transportA.sentCount(type: .getFaces), 0,
                       "a completed upload for stale board A must not initiate a reload")
        XCTAssertEqual(model.boardID, connectionB.boardKey)
        XCTAssertEqual(model.boardGeneration, connectionB.connectionGeneration)
        XCTAssertEqual(model.faceDocument.faces.map(\.id), ["b1"])
        XCTAssertNil(model.errorMessage)
        connectionA.disconnect()
        connectionB.disconnect()
    }

    func testStaleBoardSwitchDuringFailedFaceImportDoesNotReplaceNewBoardError() async throws {
        let model = FaceLibraryModel()
        let (connectionA, transportA) = await wifiBoard(host: "board-a.local")
        let (connectionB, transportB) = await wifiBoard(host: "board-b.local")
        let faceA = SavedFace(id: "a1", name: "Imported A", type: .custom,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        let imported = try FaceDocument(faces: [faceA]).encoded()

        transportA.resetRecordedFrames()
        transportA.automaticallyReplies = false
        let importTask = Task {
            await model.importDocument(from: imported, to: .board, connection: connectionA)
        }
        try await transportA.waitForSent(type: .blobBegin, count: 1)

        model.synchronizeBoardGeneration(connectionB.connectionGeneration)
        let faceB = SavedFace(id: "b1", name: "Board B face", type: .custom,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await scriptedReload(model, connectionB, transportB, faces: [faceB])
        model.errorMessage = "Board B warning"

        // Retiring A fails its held upload. That failure belongs to A and must
        // not publish over B's current error/document state.
        connectionA.disconnect()
        await importTask.value

        XCTAssertEqual(model.boardID, connectionB.boardKey)
        XCTAssertEqual(model.boardGeneration, connectionB.connectionGeneration)
        XCTAssertEqual(model.faceDocument.faces.map(\.id), ["b1"])
        XCTAssertEqual(model.errorMessage, "Board B warning")
        connectionB.disconnect()
    }

    /// A refresh of the SAME board also moves the load revision. A rename that
    /// raced it succeeded on the board, so the model must re-read rather than
    /// keep whatever the refresh fetched (possibly from before the rename).
    func testSameBoardRefreshDuringRenameReReadsInsteadOfDroppingTheResult() async throws {
        let model = FaceLibraryModel()
        let (connection, transport) = await wifiBoard(host: "board-a.local")
        let original = SavedFace(id: "u1", name: "Original", type: .custom,
                                 frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await scriptedReload(model, connection, transport, faces: [original])

        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let renameTask = Task { await model.rename(original, to: "Renamed", in: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)

        let refreshTask = Task { await model.reload(connection: connection) }
        for _ in 0..<5 { await Task.yield() }
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])

        // The refresh's read predates the rename; the re-read does not.
        var renamedFace = original
        renamedFace.name = "Renamed"
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: genPrefix(0) + (try FaceDocument(faces: [original]).encoded()))
        try await transport.waitForSent(type: .getFaces, count: 2)
        transport.replyToNext(type: .getFaces, payload: genPrefix(2) + (try FaceDocument(faces: [renamedFace]).encoded()))

        let renamed = await renameTask.value
        _ = await refreshTask.value
        transport.automaticallyReplies = true

        XCTAssertTrue(renamed)
        XCTAssertEqual(model.faceDocument.faces.map(\.name), ["Renamed"])
        XCTAssertEqual(model.boardGeneration, connection.connectionGeneration)
        connection.disconnect()
    }
}
