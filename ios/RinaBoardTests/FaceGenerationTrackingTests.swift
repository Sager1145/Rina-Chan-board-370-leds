import XCTest
import RinaCore
@testable import RinaBoard

/// `lastFaceOpGenMatchedExpectation` is what lets `FaceLibraryModel` apply an
/// optimistic in-place mutation instead of re-fetching the whole document. It
/// may only be true when the reply's generation is exactly one past a
/// generation this carrier actually observed; otherwise another client (the
/// WebUI) may have changed `saved_faces.json` underneath us.
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

    /// Reads the library at `gen`, so the connection has an observed generation.
    private func readFaces(_ connection: BoardConnection, _ transport: FakeRinaTransport,
                           gen: UInt32) async throws {
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let task = Task { try await connection.getFaces() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces,
                              payload: genPrefix(gen) + (try FaceDocument().encoded()))
        _ = try await task.value
        transport.automaticallyReplies = true
    }

    /// Runs one face op whose reply carries `gen`.
    private func renameReplying(gen: Int, _ connection: BoardConnection,
                                _ transport: FakeRinaTransport) async throws {
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let task = Task { try await connection.faceRename(id: "u1", name: "renamed") }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": gen])
        _ = try await task.value
        transport.automaticallyReplies = true
    }

    func testReplyOneGenerationPastTheReadGenerationMatches() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)
        try await renameReplying(gen: 6, connection, transport)
        XCTAssertTrue(connection.lastFaceOpGenMatchedExpectation,
                      "gen 6 straight after reading gen 5 is our own mutation")
    }

    /// A concurrent WebUI edit shows up as a generation jump. This is the case
    /// that used to be invisible, because `getFaces()` never recorded a
    /// generation for the reply to be compared against.
    func testGenerationJumpFromAnotherClientDoesNotMatch() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)
        try await renameReplying(gen: 9, connection, transport)
        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
                       "someone else mutated the document; callers must reload")
    }

    func testFaceOpWithNoPriorReadDoesNotMatch() async throws {
        let (connection, transport) = await connectedBoard()
        try await renameReplying(gen: 3, connection, transport)
        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
                       "without an observed generation there is no basis to claim we are in sync")
    }

    /// Firmware that reports no `gen` at all cannot support this check, so the
    /// reply must not be taken as "still in sync" — the caller reloads instead.
    /// The previous behavior left the flag at whatever the last op had set,
    /// which silently reused a stale verdict.
    func testReplyWithoutAGenerationNeverCountsAsInSync() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)
        try await renameReplying(gen: 6, connection, transport)
        XCTAssertTrue(connection.lastFaceOpGenMatchedExpectation)

        // Same connection, next reply carries no `gen`.
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let task = Task { try await connection.faceRename(id: "u1", name: "again") }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true])
        _ = try await task.value
        transport.automaticallyReplies = true

        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
                       "a reply without a generation must not inherit the previous verdict")
    }

    /// A generation only means something inside the carrier that reported it.
    func testGenerationIsForgottenWhenTheCarrierStops() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)

        connection.disconnect()
        let transport2 = FakeRinaTransport()
        let reconnected = await connection.connect(using: transport2)
        XCTAssertTrue(reconnected)

        // Even the arithmetically "correct" next generation must not be trusted:
        // the board may have been edited by another client while we were away.
        try await renameReplying(gen: 6, connection, transport2)
        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
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
