import XCTest
import RinaCore
@testable import RinaBoard

/// Covers the saved-list rework: `ControlViewModel.saveEditedFace`'s
/// overwrite/save-as-new split, `FaceLibraryModel.reorderFaces(_:in:connection:)`
/// keeping a preset/user interleaving across a fresh load, the local
/// read-modify-write gate not losing an overlapping write, and byte-safe name
/// validation.
@MainActor
final class FaceLibraryOpsTests: XCTestCase {
    func testLocalEditOverwritesSameIdAndKeepsCount() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()

        guard case .saved(let id?) = await library.saveLocal(payload(name: "Alpha", led: 1)),
              let created = library.face(id: id, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }
        let countBefore = library.faces(in: .local).count

        let editor = ControlViewModel()
        editor.loadForEditing(FaceEditRequest(id: 1, face: created, location: .local,
                                              asCopy: false, boardID: nil, boardGeneration: nil))
        XCTAssertTrue(editor.canOverwriteEditingFace,
                      "A local-origin face must be overwritable in its own library (C.1)")

        let success = await editor.saveEditedFace(name: "Alpha Edited", asNew: false, to: .local,
                                                  library: library, connection: connection)
        XCTAssertTrue(success)
        XCTAssertEqual(library.faces(in: .local).count, countBefore, "Overwriting must not add a new entry")
        XCTAssertEqual(library.face(id: id, in: .local)?.name, "Alpha Edited")
        XCTAssertEqual(editor.editingFaceId, id)
    }

    func testSaveAsNewSucceedsWithNewIdAndKeepsOriginal() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()

        guard case .saved(let originalID?) = await library.saveLocal(payload(name: "Original", led: 1)),
              let created = library.face(id: originalID, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }
        let editor = ControlViewModel()
        editor.loadForEditing(FaceEditRequest(id: 1, face: created, location: .local,
                                              asCopy: false, boardID: nil, boardGeneration: nil))

        let success = await editor.saveEditedFace(name: "A Copy", asNew: true, to: .local,
                                                  library: library, connection: connection)
        XCTAssertTrue(success)
        XCTAssertNotEqual(editor.editingFaceId, originalID,
                          "asNew must not replace the id being edited")
        XCTAssertEqual(library.face(id: originalID, in: .local)?.name, "Original",
                       "The face being edited from must survive a save-as-new untouched")
        let newID = try XCTUnwrap(editor.editingFaceId)
        XCTAssertEqual(library.face(id: newID, in: .local)?.name, "A Copy")
    }

    func testSaveAsNewFailureLeavesEditingTargetUntouched() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()

        guard case .saved(let originalID?) = await library.saveLocal(payload(name: "Original", led: 1)),
              let created = library.face(id: originalID, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }
        let editor = ControlViewModel()
        editor.loadForEditing(FaceEditRequest(id: 1, face: created, location: .local,
                                              asCopy: false, boardID: nil, boardGeneration: nil))

        // An empty name fails validation before any store call; the old
        // `startNewFace()`-first flow would have already cleared the editor's
        // overwrite target by this point.
        let success = await editor.saveEditedFace(name: "   ", asNew: true, to: .local,
                                                   library: library, connection: connection)
        XCTAssertFalse(success)
        XCTAssertEqual(editor.editingFaceId, originalID,
                       "A failed save-as-new must not discard the editor's previous overwrite target")
        XCTAssertTrue(editor.canOverwriteEditingFace)
    }

    /// Seeds the store with a *default*-type face whose id is one of the
    /// bundle's real presets, interleaved between two user faces, so the
    /// reorder + fresh-load round trip actually exercises the preset/user
    /// interleaving `mergedWithBundledDefaults` is responsible for
    /// preserving — not just two user faces, which never touch that path.
    func testReorderFacesLocalInterleavedPersistsAcrossFreshLoad() async throws {
        guard let bundledDefault = (try? RinaResources.defaultFaces(bundle: .main))?
            .faces.first(where: { $0.type == .default }) else {
            throw XCTSkip("Bundled default faces are not available in this test host")
        }
        var seeded = FaceDocument()
        seeded.faces = [bundledDefault]
        let store = OpsTestLocalFaceStore(document: seeded)
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()
        _ = await library.saveLocal(payload(name: "User One", led: 1))
        _ = await library.saveLocal(payload(name: "User Two", led: 2))

        let all = library.faces(in: .local)
        XCTAssertGreaterThanOrEqual(all.count, 3, "Expects the seeded default plus the two user faces just saved")
        XCTAssertTrue(all.contains { $0.id == bundledDefault.id && $0.type == .default },
                      "The seeded default must survive the merge with bundled defaults")
        // The merge appends every bundled preset the store has not seen yet,
        // so the permutation is built from the library as loaded.
        let presets = all.filter { $0.type == .default }
        let userFaces = all.filter { $0.type != .default }
        XCTAssertEqual(userFaces.count, 2)
        // Presets must actually sit *between* the two user faces, not merely
        // be reversible as one contiguous block against another.
        let interleaved = [userFaces[1]] + presets + [userFaces[0]]
        XCTAssertEqual(Set(interleaved.map(\.id)), Set(all.map(\.id)))
        let reordered = await library.reorderFaces(interleaved, in: .local, connection: connection)
        XCTAssertTrue(reordered)
        XCTAssertEqual(library.faces(in: .local).map(\.id), interleaved.map(\.id))

        // A brand new model reading the same on-disk store must not reset the
        // interleaving that `mergedWithBundledDefaults` sees on every launch.
        let reloaded = FaceLibraryModel(localStore: store)
        await reloaded.loadLocalIfNeeded()
        XCTAssertEqual(reloaded.faces(in: .local).map(\.id), interleaved.map(\.id),
                       "The exact preset/user order must survive a fresh load")
    }

    func testReorderFacesRejectsPartialList() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()
        _ = await library.saveLocal(payload(name: "User One", led: 1))
        _ = await library.saveLocal(payload(name: "User Two", led: 2))

        let confirmed = library.faces(in: .local)
        let partial = Array(confirmed.dropLast())
        let result = await library.reorderFaces(partial, in: .local, connection: connection)
        XCTAssertFalse(result)
        XCTAssertEqual(library.faces(in: .local).map(\.id), confirmed.map(\.id),
                       "A rejected partial permutation must not change the published order")
    }

    /// The local mutation gate must serialize *reads* of `localDocument`, not
    /// just the final disk write — otherwise one of these two operations
    /// snapshots the document before the other commits, and its own write
    /// silently discards the other's change.
    func testOverlappingLocalMutationsBothSurvive() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()
        guard case .saved(let idA?) = await library.saveLocal(payload(name: "A", led: 1)),
              let faceA = library.face(id: idA, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }

        async let renamed: Bool = library.rename(faceA, to: "A Renamed", in: .local, connection: connection)
        async let savedB: FaceLibraryModel.SaveOutcome = library.saveLocal(payload(name: "B", led: 2))
        let (renameResult, saveResult) = await (renamed, savedB)

        XCTAssertTrue(renameResult)
        guard case .saved(let idB?) = saveResult else { return XCTFail("Expected the overlapping save to succeed") }
        XCTAssertEqual(library.face(id: idA, in: .local)?.name, "A Renamed")
        XCTAssertNotNil(library.face(id: idB, in: .local), "The overlapping save must not be lost")
    }

    /// The undo record is transaction state. If delete B is already queued
    /// ahead of an undo for delete A, the undo must consume B's newer record
    /// after it enters the mutation gate instead of restoring A from a stale
    /// pre-gate snapshot and clearing B's undo information (R14).
    func testQueuedUndoConsumesDeletionRecordInsideMutationGate() async throws {
        let store = BlockingLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()

        guard case .saved(let idA?) = await library.saveLocal(payload(name: "A", led: 1)),
              case .saved(let idB?) = await library.saveLocal(payload(name: "B", led: 2)),
              let faceA = library.face(id: idA, in: .local),
              let faceB = library.face(id: idB, in: .local) else {
            return XCTFail("Expected two local faces")
        }
        let deletedA = await library.delete(faceA, from: .local, connection: connection)
        XCTAssertTrue(deletedA)

        await store.holdNextSave()
        let renameTask = Task {
            await library.rename(faceB, to: "B Renamed", in: .local, connection: connection)
        }
        await store.waitForHeldSave()

        let deleteBTask = Task {
            await library.delete(faceB, from: .local, connection: connection)
        }
        // Let delete B enqueue at the model's FIFO mutation gate before undo.
        await Task.yield()
        let undoTask = Task { await library.undoLocalDelete() }
        await store.releaseHeldSave()

        let renamedB = await renameTask.value
        let deletedB = await deleteBTask.value
        let restoredB = await undoTask.value
        XCTAssertTrue(renamedB)
        XCTAssertTrue(deletedB)
        XCTAssertTrue(restoredB)
        XCTAssertNil(library.face(id: idA, in: .local),
                     "the superseded A deletion must remain deleted")
        XCTAssertEqual(library.face(id: idB, in: .local)?.name, "B Renamed",
                       "undo must restore the authoritative object actually deleted by the queued transaction")
        XCTAssertFalse(library.canUndoLocalDelete)
    }

    /// 30 CJK characters is 90 UTF-8 bytes: `cleanName` must truncate on a
    /// `Character` boundary at <=64 bytes, never splitting a multi-byte glyph.
    func testCleanNameTruncatesOnCharacterBoundaryWithoutExceeding64Bytes() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        await library.loadLocalIfNeeded()
        let longName = String(repeating: "汉", count: 30)
        XCTAssertEqual(longName.utf8.count, 90)

        guard case .saved(let id?) = await library.saveLocal(payload(name: longName, led: 1)),
              let face = library.face(id: id, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }
        XCTAssertLessThanOrEqual(face.name.utf8.count, 64)
        XCTAssertTrue(longName.hasPrefix(face.name),
                      "Truncation must land on a character boundary, never split a glyph")
    }

    /// Copy markers are part of the firmware's 64-byte field. The base must
    /// surrender enough bytes for `_copy`, localized copy text, and numeric
    /// disambiguators instead of being truncated to 64 first (R16).
    func testGeneratedCopyNamesReserveSuffixBytesAcrossUnicodeInputs() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        await library.loadLocalIfNeeded()
        let frame = PackedFrame()
        let parts = PartsCall.defaultCall
        let names = [
            String(repeating: "a", count: 64),
            String(repeating: "汉", count: 30),
            String(repeating: "👩🏽‍💻", count: 12),
            "   ",
        ]

        for name in names {
            let payload = library.boardUpsertPayload(editingFaceId: "source", canOverwrite: false,
                                                     name: name, frame: frame,
                                                     fromParts: false, call: parts)
            XCTAssertTrue(payload.name.hasSuffix("_copy"))
            XCTAssertLessThanOrEqual(payload.name.utf8.count, 64,
                                     "generated name exceeds firmware limit: \(payload.name)")
        }
    }

    func testLocalizedAndNumberedCopyNamesStayUniqueAndWithin64Bytes() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()
        let source = SavedFace(id: "source", name: String(repeating: "a", count: 64),
                               type: .custom, frameBytes: PackedFrame().bytes.map(Int.init), order: 1)

        guard case .saved = await library.copy(source, from: .board, to: .local, connection: connection) else {
            return XCTFail("Expected the first copy to save")
        }
        let firstName = try XCTUnwrap(library.userFaces(in: .local).last?.name)
        XCTAssertLessThanOrEqual(firstName.utf8.count, 64)

        guard case .saved = await library.copy(source, from: .board, to: .local, connection: connection) else {
            return XCTFail("Expected the numbered copy to save")
        }
        let lastTwo = Array(library.userFaces(in: .local).suffix(2)).map(\.name)
        XCTAssertEqual(Set(lastTwo).count, 2)
        XCTAssertTrue(lastTwo.allSatisfy { $0.utf8.count <= 64 })
    }

    /// User-entered names over the byte limit are refused outright by the
    /// naming sheet's save path, not silently truncated.
    func testSaveEditedFaceRejectsNameOverByteLimit() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()
        let editor = ControlViewModel()
        let tooLong = String(repeating: "汉", count: 30)

        let userFacesBefore = library.userFaces(in: .local).count
        let success = await editor.saveEditedFace(name: tooLong, asNew: true, to: .local,
                                                   library: library, connection: connection)
        XCTAssertFalse(success)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(library.userFaces(in: .local).count, userFacesBefore,
                       "A rejected name must not create a new local entry")
    }

    /// `reloadLocal()` must never replace a previously loaded `localDocument`
    /// with bundled defaults just because the re-read failed: the in-memory
    /// faces survive, and a following mutation (rename) writes them back —
    /// not a presets-only document.
    func testReloadLocalFailureKeepsFacesAndDoesNotWritePresetsOnlyFile() async throws {
        let store = ThrowOnNthLoadLocalFaceStore(document: FaceDocument(), throwingOnLoad: 2)
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()

        guard case .saved(let id?) = await library.saveLocal(payload(name: "Alpha", led: 1)),
              let created = library.face(id: id, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }
        let beforeReload = library.faces(in: .local)

        // The second `load()` call (inside `reloadLocal`) throws.
        await library.reloadLocal()
        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(library.isLocalLoaded, "A failed re-read must not un-load a library that was already loaded")
        XCTAssertEqual(library.faces(in: .local).map(\.id), beforeReload.map(\.id),
                       "A failed re-read must keep the previously loaded faces, not fall back to bundled defaults")
        XCTAssertEqual(library.face(id: id, in: .local)?.name, created.name)

        // A following mutation must write back the real (in-memory) library,
        // not silently persist a presets-only document to disk.
        let renamed = await library.rename(created, to: "Alpha Renamed", in: .local, connection: connection)
        XCTAssertTrue(renamed)
        let onDisk = await store.currentDocument()
        XCTAssertNotNil(onDisk?.faces.first { $0.id == id && $0.name == "Alpha Renamed" },
                        "The rename must persist the user face, not a presets-only document")
    }

    /// A failed first read may represent recoverable bytes. Defaults can be
    /// shown, but the model must remain unloaded and reject mutations so the
    /// original file is never replaced by a presets-only fallback (R15).
    func testCorruptInitialLocalFileIsPreservedAndBlocksMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceLibraryOpsTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("local_faces.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("{ definitely not valid face json".utf8)
        try original.write(to: fileURL)

        let library = FaceLibraryModel(localStore: LocalFaceStore(fileURL: fileURL))
        await library.loadLocalIfNeeded()
        XCTAssertFalse(library.isLocalLoaded)
        XCTAssertNotNil(library.errorMessage)

        let outcome = await library.saveLocal(payload(name: "Must Not Persist", led: 1))
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(library.isLocalLoaded)
        XCTAssertEqual(try Data(contentsOf: fileURL), original,
                       "a failed read must never authorize overwriting the recoverable source bytes")
    }

    /// An overwrite target that no longer exists in the local library (e.g.
    /// already deleted) must fail loudly instead of silently creating a new
    /// face under a fresh id.
    func testLocalOverwriteMissingTargetFailsInsteadOfCreatingNew() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        await library.loadLocalIfNeeded()
        let countBefore = library.faces(in: .local).count

        let outcome = await library.saveLocal(payload(name: "Ghost", led: 1), replacingID: "does-not-exist")
        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(library.errorMessage, "A missing overwrite target must report a failure message")
        XCTAssertEqual(library.faces(in: .local).count, countBefore,
                       "A missing overwrite target must not silently create a new face")
    }

    /// A stale (mismatching) `expect` must fail the overwrite, leave the
    /// local document unchanged, and surface the "changed elsewhere" message.
    func testLocalOverwriteWithMismatchingExpectFailsAndLeavesLibraryUnchanged() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        await library.loadLocalIfNeeded()
        guard case .saved(let id?) = await library.saveLocal(payload(name: "Alpha", led: 1)) else {
            return XCTFail("Expected a locally saved face")
        }
        let before = library.face(id: id, in: .local)

        var overwrite = payload(name: "Alpha Edited", led: 2)
        overwrite.expect = FaceExpectation(name: "Alpha", frameHex: PackedFrame().hex94) // stale frame
        let outcome = await library.saveLocal(overwrite, replacingID: id)

        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(library.face(id: id, in: .local)?.name, before?.name)
        XCTAssertEqual(library.face(id: id, in: .local)?.frameBytes, before?.frameBytes)
    }

    /// A matching `expect` (the stored face is exactly what the editor
    /// loaded) lets the overwrite through as before.
    func testLocalOverwriteWithMatchingExpectSucceeds() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        await library.loadLocalIfNeeded()
        var seedFrame = PackedFrame()
        seedFrame.set(1)
        guard case .saved(let id?) = await library.saveLocal(
            FaceUpsertPayload(name: "Alpha", type: SavedFace.Kind.custom.rawValue, frameHex: seedFrame.hex94)
        ) else {
            return XCTFail("Expected a locally saved face")
        }

        var overwrite = payload(name: "Alpha Edited", led: 2)
        overwrite.expect = FaceExpectation(name: "Alpha", frameHex: seedFrame.hex94)
        let outcome = await library.saveLocal(overwrite, replacingID: id)

        XCTAssertEqual(outcome, .saved(id: id))
        XCTAssertEqual(library.face(id: id, in: .local)?.name, "Alpha Edited")
    }

    /// `expect == nil` is the legacy path: no optimistic-lock check at all.
    func testLocalOverwriteWithoutExpectSucceedsLegacyBehavior() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        await library.loadLocalIfNeeded()
        guard case .saved(let id?) = await library.saveLocal(payload(name: "Alpha", led: 1)) else {
            return XCTFail("Expected a locally saved face")
        }

        let overwrite = payload(name: "Alpha Edited", led: 2) // expect defaults to nil
        let outcome = await library.saveLocal(overwrite, replacingID: id)

        XCTAssertEqual(outcome, .saved(id: id))
        XCTAssertEqual(library.face(id: id, in: .local)?.name, "Alpha Edited")
    }

    /// A rename made earlier in the *same* session (e.g. via the saved-list
    /// sheet, while this face was already open in the editor) must not trip
    /// the optimistic-lock guard: the editor's baseline only knows the name
    /// as of when it took the face over, but the phone itself already saw
    /// that rename land, so it is not a foreign edit. The overwrite must
    /// still land the new drawing and the name given to this save.
    func testSaveEditedFaceAfterSameSessionRenameSucceedsWithNewDrawingAndName() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()

        guard case .saved(let id?) = await library.saveLocal(payload(name: "Alpha", led: 1)),
              let created = library.face(id: id, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }

        let editor = ControlViewModel()
        editor.loadForEditing(FaceEditRequest(id: 1, face: created, location: .local,
                                              asCopy: false, boardID: nil, boardGeneration: nil))
        XCTAssertTrue(editor.canOverwriteEditingFace)

        // Renamed elsewhere in this same session — the editor's own
        // `editingBaseline` still says "Alpha", untouched by this call.
        let renamed = await library.rename(created, to: "Alpha Renamed", in: .local, connection: connection)
        XCTAssertTrue(renamed)

        // The user then actually draws something new in the editor.
        editor.toggle(led: 5, connection: connection)
        XCTAssertTrue(editor.draftFrame[5])

        let success = await editor.saveEditedFace(name: "Alpha Final", asNew: false, to: .local,
                                                  library: library, connection: connection)
        XCTAssertTrue(success, "A same-session rename must not be treated as a foreign edit")
        let stored = library.face(id: id, in: .local)
        XCTAssertEqual(stored?.name, "Alpha Final", "The stored name must be the one given to this save")
        XCTAssertEqual(stored?.frameBytes, editor.draftFrame.bytes.map(Int.init),
                       "The stored frame must be the new drawing, not the pre-edit one")
    }

    /// The board's reply to a `face_upsert` can be lost after the write
    /// already landed (link hiccup). The 409 that follows must not be a dead
    /// end: `save` reloads, sees the board already holds exactly the name and
    /// frame we tried to write, and reports success instead of an error a
    /// retry could never clear.
    func testBoardSaveLostAckConflictReconcilesAsSavedWhenBoardAlreadyHoldsOurWrite() async throws {
        let (connection, transport) = await connectedBoard()
        let library = FaceLibraryModel()
        var frame = PackedFrame()
        frame.set(9)
        let payload = FaceUpsertPayload(id: "custom1", name: "Beta",
                                        type: SavedFace.Kind.custom.rawValue, frameHex: frame.hex94,
                                        expect: FaceExpectation(name: "Alpha", frameHex: PackedFrame().hex94))
        let source = BoardFaceSaveSource(boardID: connection.boardKey,
                                         generation: connection.connectionGeneration)

        transport.automaticallyReplies = false
        // The handshake already sent `.cmd` frames; wait for ours specifically.
        let cmdsBefore = transport.sentFrames(type: .cmd).count
        let task = Task { await library.save(payload, source: source, connection: connection) }

        try await transport.waitForSent(type: .cmd, count: cmdsBefore + 1)
        let request = try XCTUnwrap(transport.sentFrames(type: .cmd).last)
        transport.emitReply(type: .error, seq: request.seq, payload: Data(
            #"{"ok":false,"error":"face changed since it was loaded; reload before overwriting","code":409}"#.utf8
        ))

        try await transport.waitForSent(type: .getFaces, count: 1)
        let boardFace = SavedFace(id: "custom1", name: "Beta", type: .custom,
                                  frameBytes: frame.bytes.map(Int.init), order: 1)
        transport.replyToNext(type: .getFaces,
                              payload: genPrefix(1) + (try FaceDocument(faces: [boardFace]).encoded()))

        let outcome = await task.value
        XCTAssertEqual(outcome, .saved(id: "custom1"),
                       "The board already holds our write; the lost-ack retry must converge, not fail")
        XCTAssertNil(library.errorMessage)
        connection.disconnect()
    }

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

    private func payload(name: String, led: Int) -> FaceUpsertPayload {
        var frame = PackedFrame()
        frame.set(led)
        return FaceUpsertPayload(name: name, type: SavedFace.Kind.custom.rawValue, frameHex: frame.hex94)
    }
}

/// `FaceNumberLedger` (independent of Observation/SwiftUI): reorders must not
/// reassign a number, deletions never free one up for reuse, and scopes stay
/// isolated from each other.
final class FaceNumberLedgerTests: XCTestCase {
    func testReorderKeepsAssignedNumbers() throws {
        var ledger = FaceNumberLedger()
        try ledger.ensureNumbers(for: ["a", "b", "c"], scope: "local")
        let numberA = ledger.number(for: "a", scope: "local")
        let numberB = ledger.number(for: "b", scope: "local")

        // Re-request the same ids in a different order (as a reorder draft
        // committing would): numbers must not move.
        try ledger.ensureNumbers(for: ["c", "b", "a"], scope: "local")
        XCTAssertEqual(ledger.number(for: "a", scope: "local"), numberA)
        XCTAssertEqual(ledger.number(for: "b", scope: "local"), numberB)
    }

    func testDeletedIdsAreNotRecycled() throws {
        var ledger = FaceNumberLedger()
        try ledger.ensureNumbers(for: ["a", "b"], scope: "local")
        let numberA = try XCTUnwrap(ledger.number(for: "a", scope: "local"))
        let numberB = try XCTUnwrap(ledger.number(for: "b", scope: "local"))

        // "a" is deleted (never asked for again); a new id "c" is added.
        try ledger.ensureNumbers(for: ["b", "c"], scope: "local")
        let numberC = try XCTUnwrap(ledger.number(for: "c", scope: "local"))
        XCTAssertNotEqual(numberC, numberA)
        XCTAssertNotEqual(numberC, numberB)
        XCTAssertGreaterThan(numberC, max(numberA, numberB), "A new id must never reuse a retired number")
    }

    func testScopesAreIsolated() throws {
        var ledger = FaceNumberLedger()
        try ledger.ensureNumbers(for: ["x"], scope: "local")
        try ledger.ensureNumbers(for: ["x"], scope: "board:AA")
        XCTAssertEqual(ledger.number(for: "x", scope: "local"), 1)
        XCTAssertEqual(ledger.number(for: "x", scope: "board:AA"), 1,
                       "Independent scopes must allocate independently, not share a counter")

        try ledger.ensureNumbers(for: ["x", "y"], scope: "local")
        XCTAssertEqual(ledger.number(for: "y", scope: "local"), 2)
        XCTAssertNil(ledger.number(for: "y", scope: "board:AA"))
    }
}

private actor OpsTestLocalFaceStore: LocalFaceStoring {
    private var document: FaceDocument?
    init(document: FaceDocument?) { self.document = document }
    func load() async throws -> FaceDocument? { document }
    func save(_ document: FaceDocument) async throws { self.document = document }
}

private actor BlockingLocalFaceStore: LocalFaceStoring {
    private var document: FaceDocument?
    private var shouldHoldNextSave = false
    private var heldSaveContinuation: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    init(document: FaceDocument?) { self.document = document }

    func load() async throws -> FaceDocument? { document }

    func save(_ document: FaceDocument) async throws {
        if shouldHoldNextSave {
            shouldHoldNextSave = false
            let waiters = heldWaiters
            heldWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { heldSaveContinuation = $0 }
        }
        self.document = document
    }

    func holdNextSave() { shouldHoldNextSave = true }

    func waitForHeldSave() async {
        if heldSaveContinuation != nil { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func releaseHeldSave() {
        heldSaveContinuation?.resume()
        heldSaveContinuation = nil
    }
}

private enum OpsTestLocalFaceStoreError: Error {
    case loadFailed
}

/// Throws from `load()` on the Nth call (1-based) and succeeds on every
/// other call — used to make `reloadLocal()`'s second read fail while the
/// first (via `loadLocalIfNeeded`) succeeds.
private actor ThrowOnNthLoadLocalFaceStore: LocalFaceStoring {
    private var document: FaceDocument?
    private let throwingOnLoad: Int
    private var loadCount = 0

    init(document: FaceDocument?, throwingOnLoad: Int) {
        self.document = document
        self.throwingOnLoad = throwingOnLoad
    }

    func load() async throws -> FaceDocument? {
        loadCount += 1
        if loadCount == throwingOnLoad { throw OpsTestLocalFaceStoreError.loadFailed }
        return document
    }

    func save(_ document: FaceDocument) async throws { self.document = document }
    func currentDocument() -> FaceDocument? { document }
}
