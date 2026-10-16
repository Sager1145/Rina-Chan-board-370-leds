import XCTest
import RinaCore
@testable import RinaBoard

/// Regression coverage for board-owned saves and ambiguous commit outcomes.
@MainActor
final class BoardOwnedSaveSafetyTests: XCTestCase {
    func testForeignRenameLearnedByReloadMustStillConflictWithOldEditor() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let original = SavedFace(id: "audit-face", name: "Original", type: .custom,
                                 frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await reload(library, connection, transport, face: original, gen: 5)
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.loadForEditing(FaceEditRequest(id: 1, face: original, location: .board,
                                              asCopy: false, boardID: connection.boardKey,
                                              boardGeneration: connection.connectionGeneration))
        editor.toggle(led: 5, connection: connection)

        // A second client renames without changing pixels; this app only learns
        // the change through GET_FACES, never through its own rename action.
        var foreign = original
        foreign.name = "Other client's name"
        try await reload(library, connection, transport, face: foreign, gen: 6)
        transport.resetRecordedFrames()
        let save = Task {
            await editor.saveEditedFace(name: "My stale editor name", asNew: false,
                                        to: .board, library: library, connection: connection)
        }
        try await transport.waitForSent(type: .cmd, count: 1)
        let submitted = try facePayload(transport)
        let expectation = try XCTUnwrap(submitted["expect"] as? [String: Any])
        // Script the board's actual compare-and-swap rule, not unconditional OK.
        if expectation["name"] as? String == foreign.name {
            transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 7])
        } else {
            let request = try XCTUnwrap(transport.lastSent(type: .cmd))
            transport.emitReply(type: .error, seq: request.seq, payload: try JSONSerialization.data(
                withJSONObject: ["ok": false, "code": 409,
                                 "error": "face changed since it was loaded"]))
            try await transport.waitForSent(type: .getFaces, count: 1)
            transport.replyToNext(type: .getFaces,
                                  payload: prefix(6) + (try FaceDocument(faces: [foreign]).encoded()))
        }
        let success = await save.value
        XCTAssertFalse(success,
                       "Exploratory safety requirement: foreign rename must conflict; sent expect=\(expectation), cached name=\(library.face(id: original.id, in: .board)?.name ?? "nil")")
    }

    func testAcknowledgedCreateWithFailedReadbackMustNotPermitSecondUnidentifiedCreate() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.toggle(led: 7, connection: connection)
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()

        let first = Task {
            await editor.saveEditedFace(name: "Already on board", asNew: false,
                                        to: .board, library: library, connection: connection)
        }
        try await transport.waitForSent(type: .cmd, count: 1)
        let stableID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        // Firmware acknowledges the committed create, but its reply carries no
        // stable created ID. The following GET_FACES fails immediately.
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 1])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let read = try XCTUnwrap(transport.lastSent(type: .getFaces))
        transport.emitReply(type: .error, seq: read.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "audit readback unavailable"]))
        let firstSuccess = await first.value

        // Exercise the actual next Save path, rather than inspecting only the
        // editor's state: a missing ID is a second create on real firmware.
        let second = Task {
            await editor.saveEditedFace(name: "Already on board", asNew: false,
                                        to: .board, library: library, connection: connection)
        }
        try await transport.waitForSent(type: .getFaces, count: 2)
        let secondRead = try XCTUnwrap(transport.lastSent(type: .getFaces))
        transport.emitReply(type: .error, seq: secondRead.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "readback unavailable"]))
        let secondSuccess = await second.value
        XCTAssertFalse(firstSuccess)
        XCTAssertFalse(secondSuccess)
        XCTAssertEqual(transport.sentCount(type: .cmd), 1)
        XCTAssertFalse(stableID.isEmpty)

    }

    func testPendingCreateSurvivesRelaunchAndReconcilesWithoutAnotherWrite() async throws {
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let editor = ControlViewModel(draftStorage: storage)
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.toggle(led: 11, connection: connection)
        let submittedFrame = editor.draftFrame
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let first = Task { await editor.saveEditedFace(name: "Durable", asNew: true, to: .board,
                                                       library: library, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let stableID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        // Before ACK, simulate another process reading the durable operation.
        let restoredBeforeACK = ControlViewModel(draftStorage: storage)
        await restoredBeforeACK.restoreDraft()
        XCTAssertTrue(restoredBeforeACK.hasPendingBoardSave)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 1])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let read = try XCTUnwrap(transport.lastSent(type: .getFaces))
        transport.emitReply(type: .error, seq: read.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "readback lost"]))
        let firstSucceeded = await first.value
        XCTAssertFalse(firstSucceeded)
        let restored = ControlViewModel(draftStorage: storage)
        await restored.restoreDraft()
        restored.connectionChanged(generation: connection.connectionGeneration)
        let retry = Task { await restored.saveEditedFace(name: "Durable", asNew: true, to: .board,
                                                         library: library, connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 2)
        let stored = SavedFace(id: stableID, name: "Durable", type: .custom,
                               frameBytes: submittedFrame.bytes.map(Int.init), order: 1)
        let reconciliation = try XCTUnwrap(transport.lastSent(type: .getFaces))
        transport.emitReply(type: .getFaces, seq: reconciliation.seq,
                            payload: prefix(1) + (try FaceDocument(faces: [stored]).encoded()))
        let succeeded = await retry.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.sentCount(type: .cmd), 1)
        XCTAssertEqual(restored.editingFaceId, stableID)
        let secondRelaunch = ControlViewModel(draftStorage: storage)
        await secondRelaunch.restoreDraft()
        XCTAssertFalse(secondRelaunch.hasPendingBoardSave)
        XCTAssertEqual(secondRelaunch.editingFaceId, stableID)
    }

    func testOfflineSaveLeavesOnlyUnsubmittedDraft() async {
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let editor = ControlViewModel(draftStorage: storage)
        let connection = BoardConnection()
        editor.toggle(led: 9, connection: connection)
        let library = FaceLibraryModel()
        let success = await editor.saveEditedFace(name: "Offline", asNew: true, to: .local,
                                                  library: library, connection: connection)
        XCTAssertFalse(success)
        XCTAssertTrue(library.localDocument.faces.isEmpty)
        XCTAssertFalse(editor.hasPendingBoardSave)
        await editor.persistDraft()
        let restored = ControlViewModel(draftStorage: storage)
        await restored.restoreDraft()
        XCTAssertEqual(restored.draftFrame, editor.draftFrame)
    }

    func testStalePartsMetadataCannotDiscardCustomPixels() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        editor.livePreview = false
        editor.connectionChanged(generation: connection.connectionGeneration)
        let frame = PackedFrame()
        let stale = SavedFace(id: "stale-parts", name: "Hand drawing", type: .parts,
                               frameBytes: frame.bytes.map(Int.init), order: 1,
                               call: .init(leye: "101", reye: "201", mouth: "301", cheek: "400"))
        editor.loadForEditing(FaceEditRequest(id: 1, face: stale, location: .board, asCopy: true,
                                              boardID: connection.boardKey,
                                              boardGeneration: connection.connectionGeneration))
        XCTAssertTrue(editor.fromParts)
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let saving = Task { await editor.saveEditedFace(name: "Hand drawing", asNew: true, to: .board,
                                                        library: FaceLibraryModel(), connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let payload = try facePayload(transport)
        XCTAssertEqual(payload["type"] as? String, "custom")
        XCTAssertEqual(payload["frameHex"] as? String, frame.hex94)
        XCTAssertNil(payload["call"])
        let id = try XCTUnwrap(payload["id"] as? String)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 1])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let stored = SavedFace(id: id, name: "Hand drawing", type: .custom,
                               frameBytes: frame.bytes.map(Int.init), order: 1)
        transport.replyToNext(type: .getFaces, payload: prefix(1) + (try FaceDocument(faces: [stored]).encoded()))
        let succeeded = await saving.value
        XCTAssertTrue(succeeded)
    }

    func testAbsentPendingCreateRetriesSameIDUsingFreshConfirmedGeneration() async throws {
        let (connection, transport) = await connectedBoard(caps: ["faces_conditional_v1"])
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let seed = SavedFace(id: "seed", name: "Seed", type: .default,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await reload(library, connection, transport, face: seed, gen: 5)
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        editor.livePreview = false
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.toggle(led: 7, connection: connection)
        let submitted = editor.draftFrame
        transport.resetRecordedFrames()
        let first = Task { await editor.saveEditedFace(name: "Retry", asNew: true, to: .board,
                                                       library: library, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let id = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        let firstCommand = try XCTUnwrap(transport.lastSent(type: .cmd))
        transport.emitReply(type: .error, seq: firstCommand.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "unknown outcome"]))
        let firstSucceeded = await first.value
        XCTAssertFalse(firstSucceeded)
        let retry = Task { await editor.saveEditedFace(name: "Retry", asNew: true, to: .board,
                                                       library: library, connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        let external = SavedFace(id: "external", name: "Other client", type: .custom,
                                  frameBytes: PackedFrame().bytes.map(Int.init), order: 2)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(6) + (try FaceDocument(faces: [seed, external]).encoded()))
        try await transport.waitForSent(type: .cmd, count: 2)
        let retriedCommand = try XCTUnwrap(transport.lastSent(type: .cmd))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: retriedCommand.payload) as? [String: Any])
        XCTAssertEqual(object["expectedGen"] as? Int, 6)
        XCTAssertEqual(object["createOnly"] as? Bool, true)
        XCTAssertEqual(try facePayload(transport)["id"] as? String, id)
        transport.emitReply(type: .cmd, seq: retriedCommand.seq,
                            payload: try JSONSerialization.data(withJSONObject: ["ok": true, "gen": 7]))
        try await transport.waitForSent(type: .getFaces, count: 2)
        let readback = try XCTUnwrap(transport.lastSent(type: .getFaces))
        let stored = SavedFace(id: id, name: "Retry", type: .custom,
                               frameBytes: submitted.bytes.map(Int.init), order: 3)
        transport.emitReply(type: .getFaces, seq: readback.seq,
                            payload: prefix(7) + (try FaceDocument(faces: [seed, external, stored]).encoded()))
        let succeeded = await retry.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(editor.editingFaceId, id)
    }

    /// The app sends the pixels and the stale call as they are; the board
    /// (`canonicalizeSavedFaces`, saved_faces_storage_test.py) stores the
    /// mismatch as custom, and readback must accept that as saved.
    func testCopyOfLegacyPartsWithChangedPixelsAcceptsBoardCustomBitmap() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let frame = PackedFrame()
        let legacy = SavedFace(id: "legacy-stale", name: UUID().uuidString, type: .parts,
                                frameBytes: frame.bytes.map(Int.init), order: 1,
                                call: .init(leye: "101", reye: "201", mouth: "301", cheek: "400"))
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let copy = Task { await library.copy(legacy, from: .local, to: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let submitted = try facePayload(transport)
        XCTAssertEqual(submitted["type"] as? String, "parts")
        XCTAssertNotNil(submitted["call"])
        XCTAssertEqual(submitted["frameHex"] as? String, frame.hex94)
        let id = try XCTUnwrap(submitted["id"] as? String)
        let name = try XCTUnwrap(submitted["name"] as? String)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 1])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let stored = SavedFace(id: id, name: name, type: .custom,
                               frameBytes: frame.bytes.map(Int.init), order: 1)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(1) + (try FaceDocument(faces: [stored]).encoded()))
        let outcome = await copy.value
        XCTAssertEqual(outcome, .saved(id: id))
    }

    func testVisiblePendingCopyIsRetiredBeforeANewlyNamedCopy() async throws {
        let (connection, transport) = await connectedBoard(caps: ["faces_conditional_v1"])
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        var frame = PackedFrame(); frame.set(11)
        let source = SavedFace(id: "copy-src-" + UUID().uuidString, name: UUID().uuidString, type: .custom,
                               frameBytes: frame.bytes.map(Int.init), order: 1)
        try await reload(library, connection, transport, face: source, gen: 1)

        // First copy commits, but its readback is lost: the result is pending.
        transport.resetRecordedFrames()
        let first = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let firstID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        let firstName = try XCTUnwrap(try facePayload(transport)["name"] as? String)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let lostRead = try XCTUnwrap(transport.lastSent(type: .getFaces))
        transport.emitReply(type: .error, seq: lostRead.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "readback unavailable"]))
        guard case .pending = await first.value else { return XCTFail("expected pending first copy") }

        // A refresh shows that copy, so another Copy is a new, differently named face.
        let firstCopy = SavedFace(id: firstID, name: firstName, type: .custom,
                                  frameBytes: frame.bytes.map(Int.init), order: 2)
        transport.resetRecordedFrames()
        let loading = Task { await library.reload(connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(2) + (try FaceDocument(faces: [source, firstCopy]).encoded()))
        let loaded = await loading.value
        XCTAssertTrue(loaded)

        transport.resetRecordedFrames()
        let second = Task { await library.duplicate(source, from: .board, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let secondID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        let secondName = try XCTUnwrap(try facePayload(transport)["name"] as? String)
        XCTAssertNotEqual(secondID, firstID)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 3])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let secondCopy = SavedFace(id: secondID, name: secondName, type: .custom,
                                   frameBytes: frame.bytes.map(Int.init), order: 3)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(3) + (try FaceDocument(faces: [source, firstCopy, secondCopy]).encoded()))
        let outcome = await second.value
        XCTAssertEqual(outcome, .saved(id: secondID))

        let journal = try await DraftStorage.shared.read("board_face_creates") ?? Data("[]".utf8)
        let text = String(decoding: journal, as: UTF8.self)
        XCTAssertFalse(text.contains(firstID), "A create already visible on the board must not stay pending")
        XCTAssertFalse(text.contains(secondID))
    }

    func testMalformedBoardEnvelopesCannotReplaceConfirmedSnapshotWithEmptySuccess() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let original = SavedFace(id: "confirmed", name: "Confirmed", type: .custom,
                                  frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        try await reload(library, connection, transport, face: original, gen: 1)
        for json in ["{}", "{\"category\":\"unified_saved_faces\",\"faces\":\"bad\"}",
                     "{\"category\":\"foreign\",\"faces\":[]}"] {
            transport.resetRecordedFrames()
            let reading = Task { await library.reload(connection: connection) }
            try await transport.waitForSent(type: .getFaces, count: 1)
            transport.replyToNext(type: .getFaces, payload: prefix(2) + Data(json.utf8))
            let loaded = await reading.value
            XCTAssertFalse(loaded)
            XCTAssertEqual(library.face(id: original.id, in: .board), original)
            XCTAssertNotNil(library.errorMessage)
        }
    }

    func testExplicitLegacyMigrationUsesStableBoardTargetAndNeverWritesSource() async throws {
        let (connection, transport) = await connectedBoard(caps: ["faces_conditional_v1"],
                                                           kind: .wifi(host: "migration.local", port: RinaLinkConstants.tcpPort))
        defer { connection.disconnect() }
        var sourceFrame = PackedFrame()
        sourceFrame.set(9)
        let source = SavedFace(id: "legacy-source", name: "Legacy", type: .custom,
                               frameBytes: sourceFrame.bytes.map(Int.init), order: 1)
        let store = MigrationSourceStore(document: FaceDocument(faces: [source]))
        let library = FaceLibraryModel(localStore: store)
        let sources = await library.legacyMigrationFaces()
        XCTAssertEqual(sources, [source])
        let target = BoardFaceSaveSource(boardID: connection.boardKey, generation: connection.connectionGeneration)
        let seed = SavedFace(id: "seed", name: "Seed", type: .default,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let first = Task { await library.migrateLegacyFaces(sources, to: target, connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(5) + (try FaceDocument(faces: [seed]).encoded()))
        try await transport.waitForSent(type: .cmd, count: 1)
        let stableID = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        XCTAssertTrue(stableID.hasPrefix("migrated_"))
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 6])
        try await transport.waitForSent(type: .getFaces, count: 2)
        let stored = SavedFace(id: stableID, name: "Legacy", type: .custom,
                               frameBytes: sourceFrame.bytes.map(Int.init), order: 2)
        let board = try FaceDocument(faces: [seed, stored]).encoded()
        transport.replyToNext(type: .getFaces, payload: prefix(6) + board)
        let firstResult = await first.value
        XCTAssertEqual(firstResult.succeededIDs, [source.id])
        let second = Task { await library.migrateLegacyFaces(sources, to: target, connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 3)
        transport.replyToNext(type: .getFaces, payload: prefix(6) + board)
        let secondResult = await second.value
        XCTAssertEqual(secondResult.succeededIDs, [source.id])
        XCTAssertEqual(transport.sentCount(type: .cmd), 1)
        let writes = await store.writeCount
        let preserved = try await store.load()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(preserved, FaceDocument(faces: [source]))
    }

    func testConfirmingOldPendingSnapshotDoesNotReportChangedNameAsSaved() async throws {
        let (connection, transport) = await connectedBoard()
        defer { connection.disconnect() }
        let library = FaceLibraryModel()
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        editor.livePreview = false
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.toggle(led: 6, connection: connection)
        let frame = editor.draftFrame
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let first = Task { await editor.saveEditedFace(name: "Original submission", asNew: true, to: .board,
                                                       library: library, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        let id = try XCTUnwrap(try facePayload(transport)["id"] as? String)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 1])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let lost = try XCTUnwrap(transport.lastSent(type: .getFaces))
        transport.emitReply(type: .error, seq: lost.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "lost readback"]))
        let firstSucceeded = await first.value
        XCTAssertFalse(firstSucceeded)
        let retry = Task { await editor.saveEditedFace(name: "Changed name", asNew: true, to: .board,
                                                       library: library, connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 2)
        let read = try XCTUnwrap(transport.lastSent(type: .getFaces))
        let stored = SavedFace(id: id, name: "Original submission", type: .custom,
                               frameBytes: frame.bytes.map(Int.init), order: 1)
        transport.emitReply(type: .getFaces, seq: read.seq,
                            payload: prefix(1) + (try FaceDocument(faces: [stored]).encoded()))
        let newNameSaved = await retry.value
        XCTAssertFalse(newNameSaved)
        XCTAssertFalse(editor.hasPendingBoardSave)
        XCTAssertEqual(editor.draftFrame, frame)
        XCTAssertEqual(library.face(id: id, in: .board)?.name, "Original submission")
        XCTAssertEqual(transport.sentCount(type: .cmd), 1)
        XCTAssertNotNil(library.errorMessage)
    }

    private func connectedBoard(caps: [String] = [], kind: TransportKind = .bluetooth) async -> (BoardConnection, FakeRinaTransport) {
        let transport = FakeRinaTransport(kind: kind)
        transport.commandReply = ["ok": true, "bootId": "1234abcd", "caps": caps]
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func reload(_ library: FaceLibraryModel, _ connection: BoardConnection,
                        _ transport: FakeRinaTransport, face: SavedFace, gen: UInt32) async throws {
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let loading = Task { await library.reload(connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces,
                              payload: prefix(gen) + (try FaceDocument(faces: [face]).encoded()))
        let loaded = await loading.value
        XCTAssertTrue(loaded)
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


private actor MigrationSourceStore: LocalFaceStoring {
    let document: FaceDocument
    private(set) var writeCount = 0
    init(document: FaceDocument) { self.document = document }
    func load() async throws -> FaceDocument? { document }
    func save(_ document: FaceDocument) async throws { writeCount += 1 }
}
