import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class MultiBoardFaceSaveTests: XCTestCase {
    func testTwoLibrariesPartialSaveRestoresAndRetriesOnlyUnconfirmedTarget() async throws {
        let (a, ta) = await connected("a.local")
        let (b, tb) = await connected("b.local")
        let (c, tc) = await connected("c.local")
        defer { a.disconnect(); b.disconnect(); c.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let da = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board A", connection: a))
        let db = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board B", connection: b))
        var edited = PackedFrame(); edited.set(7)
        let originalA = face("same-id", "A original", led: nil, order: 1)
        let foreignB = face("same-id", "B unrelated", led: 9, order: 1)
        let snapshot = MultiBoardFaceSaveSnapshot(frameHex: edited.hex94, type: "custom", originBoardID: da.id,
                                                  editingFaceID: originalA.id, overwriteID: originalA.id,
                                                  overwriteSource: BoardFaceSaveSource(boardID: da.id, generation: da.generation,
                                                                                       expectedBootId: "1234abcd", expectedGen: 5),
                                                  expectation: FaceExpectation(name: originalA.name, frameHex: PackedFrame().hex94))
        let prepared = await coordinator.prepare(name: "Both", snapshot: snapshot, destinations: [da, db])
        XCTAssertTrue(prepared)
        let targetA = try XCTUnwrap(coordinator.operation?.targets.first { $0.id == da.id })
        let targetB = try XCTUnwrap(coordinator.operation?.targets.first { $0.id == db.id })
        XCTAssertEqual(targetA.payload.id, originalA.id)
        XCTAssertNotEqual(targetB.payload.id, foreignB.id, "Remote boards must never reuse a source board's face ID")
        // The complete multi-board operation is durable before a board request.
        let beforeSend = MultiBoardFaceSaveCoordinator(storage: storage)
        await beforeSend.restore()
        XCTAssertEqual(beforeSend.operation?.targets.map(\.payload.id), coordinator.operation?.targets.map(\.payload.id))
        ta.automaticallyReplies = false; tb.automaticallyReplies = false
        ta.resetRecordedFrames(); tb.resetRecordedFrames(); tc.resetRecordedFrames()
        let save = Task { await coordinator.savePrepared() }
        try await ta.waitForSent(type: .getFaces, count: 1)
        ta.replyToNext(type: .getFaces, payload: prefix(5) + (try FaceDocument(faces: [originalA]).encoded()))
        try await ta.waitForSent(type: .cmd, count: 1)
        XCTAssertEqual(try payload(ta)["id"] as? String, originalA.id)
        ta.replyToNext(type: .cmd, json: ["ok": true, "gen": 6])
        try await ta.waitForSent(type: .getFaces, count: 2)
        let savedA = SavedFace(id: originalA.id, name: "Both", type: .custom,
                               frameBytes: edited.bytes.map(Int.init), order: 1)
        ta.replyToNext(type: .getFaces, payload: prefix(6) + (try FaceDocument(faces: [savedA]).encoded()))
        try await tb.waitForSent(type: .getFaces, count: 1)
        tb.replyToNext(type: .getFaces, payload: prefix(12) + (try FaceDocument(faces: [foreignB]).encoded()))
        try await tb.waitForSent(type: .cmd, count: 1)
        XCTAssertEqual(try payload(tb)["id"] as? String, targetB.payload.id)
        let commandB = try command(tb)
        XCTAssertEqual(commandB["createOnly"] as? Bool, true)
        tb.replyToNext(type: .cmd, json: ["ok": true, "gen": 13])
        try await tb.waitForSent(type: .getFaces, count: 2)
        let lostRead = try XCTUnwrap(tb.lastSent(type: .getFaces))
        tb.emitReply(type: .error, seq: lostRead.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "readback unavailable"]))
        await save.value
        XCTAssertFalse(coordinator.allConfirmed)
        XCTAssertEqual(coordinator.operation?.targets.map(\.status), [.confirmed, .pending])
        let restored = MultiBoardFaceSaveCoordinator(storage: storage)
        await restored.restore()
        XCTAssertEqual(restored.operation?.targets.map(\.status), [.confirmed, .pending])
        let retry = Task { await restored.retry(using: [da, db, try XCTUnwrap(FrozenFaceSaveDestination(name: "New board", connection: c))]) }
        try await tb.waitForSent(type: .getFaces, count: 3)
        let reconcileRead = try XCTUnwrap(tb.lastSent(type: .getFaces))
        let savedB = SavedFace(id: try XCTUnwrap(targetB.payload.id), name: "Both", type: .custom,
                               frameBytes: edited.bytes.map(Int.init), order: 2)
        tb.emitReply(type: .getFaces, seq: reconcileRead.seq,
                     payload: prefix(13) + (try FaceDocument(faces: [foreignB, savedB]).encoded()))
        try await retry.value
        XCTAssertTrue(restored.allConfirmed)
        XCTAssertEqual(ta.sentCount(type: .cmd), 1)
        XCTAssertEqual(ta.sentCount(type: .getFaces), 2, "Confirmed destinations are never reread or resent by retry")
        XCTAssertEqual(tb.sentCount(type: .cmd), 1, "The committed pending ID is confirmed without another mutation")
        XCTAssertEqual(tc.sentCount(type: .getFaces), 0, "A new board cannot join an earlier All selection")
        XCTAssertEqual(tc.sentCount(type: .cmd), 0)
    }

    func testReconnectRequiresExplicitRetryAndKeepsOriginalIDWithoutAddingNewBoard() async throws {
        let (board, oldTransport) = await connected("same.local", physicalID: "AABBCCDDEEFF")
        let (other, otherTransport) = await connected("later.local")
        defer { board.disconnect(); other.disconnect() }
        let old = try XCTUnwrap(FrozenFaceSaveDestination(name: "Original", connection: board))
        let coordinator = MultiBoardFaceSaveCoordinator(storage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let snapshot = MultiBoardFaceSaveSnapshot(frameHex: PackedFrame().hex94, type: "custom", originBoardID: old.id)
        let prepared = await coordinator.prepare(name: "Stable", snapshot: snapshot, destinations: [old])
        XCTAssertTrue(prepared)
        let stableID = try XCTUnwrap(coordinator.operation?.targets.first?.payload.id)
        board.disconnect()
        let newTransport = FakeRinaTransport(kind: .wifi(host: "same.local", port: RinaLinkConstants.tcpPort))
        newTransport.commandReply = ["ok": true, "bootId": "1234abcd", "caps": ["faces_conditional_v1"], "defaultName": "RinaBoard-AABBCCDDEEFF"]
        let connected = await board.connect(using: newTransport)
        XCTAssertTrue(connected)
        newTransport.resetRecordedFrames(); otherTransport.resetRecordedFrames(); oldTransport.resetRecordedFrames()
        await coordinator.savePrepared()
        XCTAssertEqual(coordinator.operation?.targets.first?.status, .unavailable)
        XCTAssertEqual(newTransport.sentCount(type: .cmd), 0)
        XCTAssertEqual(newTransport.sentCount(type: .getFaces), 0)
        let rebound = try XCTUnwrap(FrozenFaceSaveDestination(name: "Reconnected", connection: board))
        let later = try XCTUnwrap(FrozenFaceSaveDestination(name: "Later", connection: other))
        newTransport.automaticallyReplies = false
        let retry = Task { await coordinator.retry(using: [rebound, later]) }
        try await newTransport.waitForSent(type: .getFaces, count: 1)
        newTransport.replyToNext(type: .getFaces, payload: prefix(1) + (try FaceDocument().encoded()))
        try await newTransport.waitForSent(type: .cmd, count: 1)
        XCTAssertEqual(try payload(newTransport)["id"] as? String, stableID)
        newTransport.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])
        try await newTransport.waitForSent(type: .getFaces, count: 2)
        let stored = SavedFace(id: stableID, name: "Stable", type: .custom,
                               frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        newTransport.replyToNext(type: .getFaces, payload: prefix(2) + (try FaceDocument(faces: [stored]).encoded()))
        await retry.value
        XCTAssertTrue(coordinator.allConfirmed)
        XCTAssertEqual(otherTransport.sentCount(type: .getFaces), 0)
        XCTAssertEqual(otherTransport.sentCount(type: .cmd), 0)
    }

    func testAllToggleUsesFrozenInventoryAndIndividualTogglesDeriveMixedState() async throws {
        let (a, _) = await connected("pick-a.local")
        let (b, _) = await connected("pick-b.local")
        defer { a.disconnect(); b.disconnect() }
        let da = try XCTUnwrap(FrozenFaceSaveDestination(name: "A", connection: a))
        let db = try XCTUnwrap(FrozenFaceSaveDestination(name: "B", connection: b))
        var selection = FaceSaveDestinationSelection(destinations: [da, db], currentID: da.id)
        XCTAssertEqual(selection.selectedIDs, [da.id])
        XCTAssertFalse(selection.allSelected)
        selection.setAll(true)
        XCTAssertEqual(selection.selectedIDs, [da.id, db.id])
        XCTAssertTrue(selection.allSelected)
        selection.set(da.id, selected: false)
        XCTAssertFalse(selection.allSelected)
        XCTAssertEqual(selection.selectedIDs, [db.id])
        selection.set("board:new-after-open", selected: true)
        XCTAssertEqual(selection.selectedIDs, [db.id])
    }

    func testOfflinePrimaryCanChooseSoleOtherBoardAndRemoteResultCannotRetargetEditor() async throws {
        let (primary, _) = await connected("offline-primary.local")
        let (remote, _) = await connected("only-online.local")
        defer { primary.disconnect(); remote.disconnect() }
        let originalKey = try XCTUnwrap(primary.boardKey)
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        editor.livePreview = false
        editor.connectionChanged(generation: primary.connectionGeneration)
        editor.boardDidChange(to: originalKey)
        let original = face("source-face", "Original", led: 4, order: 1)
        editor.loadForEditing(FaceEditRequest(id: 1, face: original, location: .board, asCopy: false,
                                              boardID: originalKey, boardGeneration: primary.connectionGeneration))
        primary.disconnect()
        let destination = try XCTUnwrap(FrozenFaceSaveDestination(name: "Online", connection: remote))
        XCTAssertTrue(FaceSaveDestinationSelection.requiresPicker([destination], activeConnection: primary))
        var selection = FaceSaveDestinationSelection(destinations: [destination], currentID: originalKey)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.setAll(true)
        XCTAssertEqual(selection.selectedIDs, [destination.id])
        let snapshot = editor.multiBoardSaveSnapshot(asNew: false, originBoardID: originalKey)
        let operation = MultiBoardFaceSaveCoordinator.Operation(id: UUID(), name: "Remote copy", snapshot: snapshot,
            targets: [.init(id: destination.id, name: destination.name, generation: destination.generation,
                            carrier: destination.carrier,
                            payload: .init(id: "remote-copy", name: "Remote copy", type: "custom", frameHex: snapshot.frameHex),
                            source: .init(boardID: destination.id, generation: destination.generation),
                            createOnly: true, status: .confirmed)])
        let adopted = await editor.adoptMultiBoardSave(operation, connection: primary)
        XCTAssertFalse(adopted)
        XCTAssertEqual(editor.editingFaceId, original.id)
        XCTAssertEqual(editor.editingBaseline?.name, original.name)
        XCTAssertEqual(editor.draftFrame, original.packedFrame)
    }

    func testCorruptPendingJournalBlocksNewIDsWithoutOverwritingEvidence() async throws {
        let (connection, transport) = await connected("corrupt.local")
        defer { connection.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let corrupt = Data("{unfinished pending operation".utf8)
        try await storage.write(corrupt, name: "multi_board_face_save")
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let destination = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board", connection: connection))
        transport.resetRecordedFrames()
        let prepared = await coordinator.prepare(name: "New", snapshot: .init(frameHex: PackedFrame().hex94, type: "custom"),
                                                  destinations: [destination])
        XCTAssertFalse(prepared)
        XCTAssertNil(coordinator.operation)
        let preserved = try await storage.read("multi_board_face_save")
        XCTAssertEqual(preserved, corrupt)
        XCTAssertEqual(transport.sentCount(type: .cmd), 0)
        XCTAssertEqual(transport.sentCount(type: .getFaces), 0)
    }

    func testEndingUnfinishedOperationReleasesSaveGateWithoutSending() async throws {
        let (connection, transport) = await connected("gone.local")
        defer { connection.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let destination = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board", connection: connection))
        let snapshot = MultiBoardFaceSaveSnapshot(frameHex: PackedFrame().hex94, type: "custom")
        let prepared = await coordinator.prepare(name: "Old", snapshot: snapshot, destinations: [destination])
        XCTAssertTrue(prepared)
        // The original board never comes back: retry without it.
        await coordinator.retry(using: [])
        XCTAssertEqual(coordinator.operation?.targets.map(\.status), [.unavailable])
        await coordinator.finishIfConfirmed()
        let stillRetained = try await MultiBoardFaceSaveCoordinator.hasRetainedOperation(in: storage)
        XCTAssertTrue(stillRetained, "Finish alone must not drop an unconfirmed target")

        transport.resetRecordedFrames()
        let ended = await coordinator.endOperation()
        XCTAssertTrue(ended)
        XCTAssertNil(coordinator.operation)
        let retained = try await MultiBoardFaceSaveCoordinator.hasRetainedOperation(in: storage)
        XCTAssertFalse(retained)
        XCTAssertEqual(transport.sentCount(type: .cmd), 0, "Ending an operation never sends or rolls back")
        let next = await coordinator.prepare(name: "Unrelated", snapshot: snapshot, destinations: [destination])
        XCTAssertTrue(next, "An unrelated save can start once the old operation is ended")
    }

    func testRetryDuringEndingCannotRewriteTheJournal() async throws {
        let (connection, transport) = await connected("ending-race.local")
        defer { connection.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let destination = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board", connection: connection))
        let prepared = await coordinator.prepare(name: "Old", snapshot: .init(frameHex: PackedFrame().hex94, type: "custom"),
                                                  destinations: [destination])
        XCTAssertTrue(prepared)
        await coordinator.retry(using: [])
        transport.resetRecordedFrames()
        var retriedWhileEnding = false
        let ended = await coordinator.endOperation {
            XCTAssertTrue(coordinator.isRunning, "Ending must hold the busy flag while adoption suspends")
            await coordinator.retry(using: [destination])
            retriedWhileEnding = true
        }
        XCTAssertTrue(retriedWhileEnding)
        XCTAssertTrue(ended)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.operation)
        let retained = try await MultiBoardFaceSaveCoordinator.hasRetainedOperation(in: storage)
        XCTAssertFalse(retained)
        XCTAssertEqual(transport.sentCount(type: .getFaces), 0, "The refused retry must not reach the board")
    }

    func testEndingUnreadableJournalKeepsEvidenceAndReleasesGate() async throws {
        let (connection, _) = await connected("corrupt-end.local")
        defer { connection.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let corrupt = Data("{unfinished pending operation".utf8)
        try await storage.write(corrupt, name: "multi_board_face_save")
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        await coordinator.restore()
        XCTAssertTrue(coordinator.hasUnreadableJournal)
        XCTAssertTrue(coordinator.hasRetainedResult)
        let ended = await coordinator.endOperation()
        XCTAssertTrue(ended)
        XCTAssertFalse(coordinator.hasUnreadableJournal)
        let evidence = try await storage.read("multi_board_face_save_unreadable")
        XCTAssertEqual(evidence, corrupt)
        let retained = try await MultiBoardFaceSaveCoordinator.hasRetainedOperation(in: storage)
        XCTAssertFalse(retained)
        let destination = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board", connection: connection))
        let prepared = await coordinator.prepare(name: "New", snapshot: .init(frameHex: PackedFrame().hex94, type: "custom"),
                                                  destinations: [destination])
        XCTAssertTrue(prepared)
    }

    func testUnidentifiedSameHostnameReconnectCannotRebindEvenOnExplicitRetry() async throws {
        let (connection, _) = await connected("reused-address.local")
        defer { connection.disconnect() }
        let original = try XCTUnwrap(FrozenFaceSaveDestination(name: "Old board", connection: connection))
        XCTAssertNil(original.physicalID)
        let coordinator = MultiBoardFaceSaveCoordinator(storage: DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let prepared = await coordinator.prepare(name: "Do not redirect", snapshot: .init(frameHex: PackedFrame().hex94, type: "custom"),
                                                  destinations: [original])
        XCTAssertTrue(prepared)
        let id = coordinator.operation?.targets.first?.payload.id
        connection.disconnect()
        let replacement = FakeRinaTransport(kind: .wifi(host: "reused-address.local", port: RinaLinkConstants.tcpPort))
        replacement.commandReply = ["ok": true, "bootId": "otherboot", "caps": ["faces_conditional_v1"]]
        let connected = await connection.connect(using: replacement)
        XCTAssertTrue(connected)
        replacement.resetRecordedFrames()
        let reused = try XCTUnwrap(FrozenFaceSaveDestination(name: "Unidentified replacement", connection: connection))
        XCTAssertEqual(reused.id, original.id, "The ambiguous address deliberately matches")
        await coordinator.retry(using: [reused])
        XCTAssertEqual(coordinator.operation?.targets.first?.status, .unavailable)
        XCTAssertEqual(coordinator.operation?.targets.first?.payload.id, id)
        XCTAssertEqual(replacement.sentCount(type: .getFaces), 0)
        XCTAssertEqual(replacement.sentCount(type: .cmd), 0)
    }

    func testPendingSingleSaveBlocksNewMultiBoardOperationAndPreservesItsID() async throws {
        let (a, ta) = await connected("seam-a.local")
        let (b, _) = await connected("seam-b.local")
        defer { a.disconnect(); b.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let editor = try await createPendingSingle(storage: storage, connection: a, transport: ta)
        let originalID = try XCTUnwrap(try payload(ta)["id"] as? String)
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let destinations = try [XCTUnwrap(FrozenFaceSaveDestination(name: "A", connection: a)),
                                XCTUnwrap(FrozenFaceSaveDestination(name: "B", connection: b))]
        let prepared = await coordinator.prepare(name: "Single pending", snapshot: editor.multiBoardSaveSnapshot(asNew: true, originBoardID: a.boardKey),
                                                  destinations: destinations)
        XCTAssertFalse(prepared)
        XCTAssertNil(coordinator.operation)
        XCTAssertTrue(editor.hasPendingBoardSave)
        XCTAssertEqual(try payload(ta)["id"] as? String, originalID)
        XCTAssertEqual(ta.sentCount(type: .cmd), 1)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testDiscardingPendingSingleSaveReleasesGateWithoutSending() async throws {
        let (a, ta) = await connected("discard-single.local")
        defer { a.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let editor = try await createPendingSingle(storage: storage, connection: a, transport: ta)
        XCTAssertTrue(editor.hasPendingBoardSave)
        let pendingStored = try await ControlViewModel.hasPendingSave(in: storage)
        XCTAssertTrue(pendingStored)
        let drawing = editor.draftFrame
        ta.resetRecordedFrames()

        let discarded = await editor.discardPendingBoardSave()
        XCTAssertTrue(discarded)
        XCTAssertFalse(editor.hasPendingBoardSave)
        XCTAssertEqual(editor.draftFrame, drawing, "Discarding the pending save keeps the drawing")
        let stillStored = try await ControlViewModel.hasPendingSave(in: storage)
        XCTAssertFalse(stillStored, "The persisted draft must drop the pending save too")
        XCTAssertEqual(ta.sentCount(type: .cmd), 0, "Discarding never sends or rolls back")
        XCTAssertEqual(ta.sentCount(type: .getFaces), 0)

        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let destination = try XCTUnwrap(FrozenFaceSaveDestination(name: "A", connection: a))
        let prepared = await coordinator.prepare(name: "After discard",
                                                 snapshot: editor.multiBoardSaveSnapshot(asNew: true, originBoardID: a.boardKey),
                                                 destinations: [destination])
        XCTAssertTrue(prepared, "A new save can start once the pending one is discarded")
    }

    func testPendingMultiBoardOperationBlocksLegacySingleSavePath() async throws {
        let (connection, transport) = await connected("single-after-multi.local")
        defer { connection.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let destination = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board", connection: connection))
        let prepared = await coordinator.prepare(name: "Original multi", snapshot: .init(frameHex: PackedFrame().hex94, type: "custom"),
                                                  destinations: [destination])
        XCTAssertTrue(prepared)
        let stableID = coordinator.operation?.targets.first?.payload.id
        let editor = ControlViewModel(draftStorage: storage)
        editor.livePreview = false
        editor.toggle(led: 7, connection: connection)
        let library = FaceLibraryModel()
        transport.resetRecordedFrames()
        let singleSaved = await editor.saveEditedFace(name: "New single", asNew: true, to: .board,
                                                      library: library, connection: connection)
        XCTAssertFalse(singleSaved)
        XCTAssertFalse(editor.hasPendingBoardSave)
        XCTAssertEqual(coordinator.operation?.targets.first?.payload.id, stableID)
        XCTAssertEqual(transport.sentCount(type: .cmd), 0)
        XCTAssertEqual(transport.sentCount(type: .getFaces), 0)
        XCTAssertNotNil(library.errorMessage)
    }

    func testConfirmedOwnRenameAdvancesOnlySourceSnapshotForMultiBoardSave() async throws {
        let (a, ta) = await connected("rename-a.local")
        let (b, tb) = await connected("rename-b.local")
        defer { a.disconnect(); b.disconnect() }
        let library = FaceLibraryModel()
        let original = face("renamed-face", "Before", led: nil, order: 1)
        ta.automaticallyReplies = false
        ta.resetRecordedFrames()
        let loading = Task { await library.reload(connection: a) }
        try await ta.waitForSent(type: .getFaces, count: 1)
        ta.replyToNext(type: .getFaces, payload: prefix(5) + (try FaceDocument(faces: [original]).encoded()))
        let loaded = await loading.value
        XCTAssertTrue(loaded)
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let editor = ControlViewModel(draftStorage: storage)
        editor.livePreview = false
        editor.connectionChanged(generation: a.connectionGeneration)
        editor.loadForEditing(FaceEditRequest(id: 1, face: original, location: .board, asCopy: false,
                                              boardID: a.boardKey, boardGeneration: a.connectionGeneration,
                                              expectedBootId: a.bootId, expectedGen: 5))
        let renaming = Task { await library.rename(original, to: "Renamed here", in: .board, connection: a) }
        try await ta.waitForSent(type: .cmd, count: 1)
        ta.replyToNext(type: .cmd, json: ["ok": true, "gen": 6])
        let renamed = await renaming.value
        XCTAssertTrue(renamed)
        editor.toggle(led: 7, connection: a)
        let snapshot = editor.multiBoardSaveSnapshot(asNew: false, originBoardID: a.boardKey, using: library)
        XCTAssertEqual(snapshot.expectation?.name, "Renamed here")
        XCTAssertEqual(snapshot.overwriteSource?.expectedGen, 6)
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let da = try XCTUnwrap(FrozenFaceSaveDestination(name: "A", connection: a))
        let db = try XCTUnwrap(FrozenFaceSaveDestination(name: "B", connection: b))
        let prepared = await coordinator.prepare(name: "Final", snapshot: snapshot, destinations: [da, db])
        XCTAssertTrue(prepared)
        ta.resetRecordedFrames(); tb.resetRecordedFrames(); tb.automaticallyReplies = false
        let save = Task { await coordinator.savePrepared() }
        try await ta.waitForSent(type: .getFaces, count: 1)
        var renamedFace = original; renamedFace.name = "Renamed here"
        ta.replyToNext(type: .getFaces, payload: prefix(6) + (try FaceDocument(faces: [renamedFace]).encoded()))
        try await ta.waitForSent(type: .cmd, count: 1)
        XCTAssertEqual(try command(ta)["expectedGen"] as? Int, 6)
        XCTAssertEqual((try payload(ta)["expect"] as? [String: Any])?["name"] as? String, "Renamed here")
        ta.replyToNext(type: .cmd, json: ["ok": true, "gen": 7])
        try await ta.waitForSent(type: .getFaces, count: 2)
        let final = SavedFace(id: original.id, name: "Final", type: .custom,
                              frameBytes: editor.draftFrame.bytes.map(Int.init), order: 1)
        ta.replyToNext(type: .getFaces, payload: prefix(7) + (try FaceDocument(faces: [final]).encoded()))
        try await tb.waitForSent(type: .getFaces, count: 1)
        let read = try XCTUnwrap(tb.lastSent(type: .getFaces))
        tb.emitReply(type: .error, seq: read.seq, payload: try JSONSerialization.data(withJSONObject: ["ok": false, "code": 503, "error": "unavailable"]))
        await save.value
        XCTAssertEqual(coordinator.operation?.targets.first?.status, .confirmed)
    }

    func testCompletedJournalSurvivesUnadoptedEditorRestartAndGatesNewSaveUntilReview() async throws {
        let (connection, transport) = await connected("completed.local")
        defer { connection.disconnect() }
        let storage = DraftStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let editor = ControlViewModel(draftStorage: storage)
        editor.livePreview = false
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.saveName = "Restart"
        editor.toggle(led: 7, connection: connection)
        await editor.persistDraft()
        let snapshot = editor.multiBoardSaveSnapshot(asNew: true, originBoardID: connection.boardKey)
        let target = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board", connection: connection))
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        let prepared = await coordinator.prepare(name: "Restart", snapshot: snapshot, destinations: [target])
        XCTAssertTrue(prepared)
        let stableID = try XCTUnwrap(coordinator.operation?.targets.first?.payload.id)
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let saving = Task { await coordinator.savePrepared() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: prefix(1) + (try FaceDocument().encoded()))
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])
        try await transport.waitForSent(type: .getFaces, count: 2)
        let stored = SavedFace(id: stableID, name: "Restart", type: .custom,
                               frameBytes: editor.draftFrame.bytes.map(Int.init), order: 1)
        transport.replyToNext(type: .getFaces, payload: prefix(2) + (try FaceDocument(faces: [stored]).encoded()))
        await saving.value
        XCTAssertTrue(coordinator.allConfirmed)
        XCTAssertNil(editor.editingFaceId, "Simulate termination before editor adoption")

        connection.disconnect()
        let nextTransport = FakeRinaTransport(kind: .wifi(host: "completed.local", port: RinaLinkConstants.tcpPort))
        nextTransport.commandReply = ["ok": true, "bootId": "1234abcd", "caps": ["faces_conditional_v1"]]
        let reconnected = await connection.connect(using: nextTransport)
        XCTAssertTrue(reconnected)
        nextTransport.resetRecordedFrames()
        let restored = MultiBoardFaceSaveCoordinator(storage: storage)
        await restored.restore()
        let restoredEditor = ControlViewModel(draftStorage: storage)
        await restoredEditor.restoreDraft()
        XCTAssertTrue(restored.allConfirmed)
        XCTAssertNotNil(restored.operation, "Completed results stay visible until explicit review/Finish")
        let adopted = await restoredEditor.adoptMultiBoardSave(try XCTUnwrap(restored.operation), connection: connection)
        XCTAssertFalse(adopted, "An old carrier's confirmation cannot infer a new editor target")
        let library = FaceLibraryModel()
        let single = await restoredEditor.saveEditedFace(name: "Restart", asNew: true, to: .board,
                                                         library: library, connection: connection)
        XCTAssertFalse(single)
        let currentTarget = try XCTUnwrap(FrozenFaceSaveDestination(name: "Board", connection: connection))
        let newPrepared = await restored.prepare(name: "Restart", snapshot: snapshot, destinations: [currentTarget])
        XCTAssertFalse(newPrepared)
        XCTAssertEqual(restored.operation?.targets.first?.payload.id, stableID)
        XCTAssertEqual(nextTransport.sentCount(type: .cmd), 0)
        XCTAssertEqual(nextTransport.sentCount(type: .getFaces), 0)
        // Only the explicit completed-results Finish action releases this gate.
        await restored.finishIfConfirmed()
        let retained = try await MultiBoardFaceSaveCoordinator.hasRetainedOperation(in: storage)
        XCTAssertFalse(retained)
    }

    private func createPendingSingle(storage: DraftStorage, connection: BoardConnection,
                                     transport: FakeRinaTransport) async throws -> ControlViewModel {
        transport.automaticallyReplies = false
        transport.resetRecordedFrames()
        let library = FaceLibraryModel()
        let loading = Task { await library.reload(connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces, payload: prefix(1) + (try FaceDocument().encoded()))
        let loaded = await loading.value
        XCTAssertTrue(loaded)
        let editor = ControlViewModel(draftStorage: storage)
        editor.livePreview = false
        editor.connectionChanged(generation: connection.connectionGeneration)
        editor.toggle(led: 6, connection: connection)
        transport.resetRecordedFrames()
        let saving = Task { await editor.saveEditedFace(name: "Single pending", asNew: true, to: .board,
                                                        library: library, connection: connection) }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": 2])
        try await transport.waitForSent(type: .getFaces, count: 1)
        let read = try XCTUnwrap(transport.lastSent(type: .getFaces))
        transport.emitReply(type: .error, seq: read.seq, payload: try JSONSerialization.data(
            withJSONObject: ["ok": false, "code": 503, "error": "readback lost"]))
        let saved = await saving.value
        XCTAssertFalse(saved)
        return editor
    }

    private func connected(_ host: String, physicalID: String? = nil) async -> (BoardConnection, FakeRinaTransport) {
        let transport = FakeRinaTransport(kind: .wifi(host: host, port: RinaLinkConstants.tcpPort))
        transport.commandReply = ["ok": true, "bootId": "1234abcd", "caps": ["faces_conditional_v1"]]
        if let physicalID { transport.commandReply["defaultName"] = "RinaBoard-" + physicalID }
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }
    private func face(_ id: String, _ name: String, led: Int?, order: Int) -> SavedFace {
        var frame = PackedFrame(); if let led { frame.set(led) }
        return SavedFace(id: id, name: name, type: .custom, frameBytes: frame.bytes.map(Int.init), order: order)
    }
    private func prefix(_ gen: UInt32) -> Data {
        Data([UInt8(gen & 255), UInt8((gen >> 8) & 255), UInt8((gen >> 16) & 255), UInt8((gen >> 24) & 255)])
    }
    private func command(_ transport: FakeRinaTransport) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.lastSent(type: .cmd)).payload) as? [String: Any])
    }
    private func payload(_ transport: FakeRinaTransport) throws -> [String: Any] {
        try XCTUnwrap(command(transport)["face"] as? [String: Any])
    }
}
