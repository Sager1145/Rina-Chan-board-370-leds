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
        guard let defaultFace = all.first(where: { $0.id == bundledDefault.id && $0.type == .default }) else {
            return XCTFail("The seeded default must survive the merge with bundled defaults")
        }
        let userFaces = all.filter { $0.type != .default }
        XCTAssertGreaterThanOrEqual(userFaces.count, 2)
        // The default must actually sit *between* two user faces, not merely
        // be reversible as one contiguous block against another.
        let interleaved = [userFaces[1], defaultFace] + userFaces.dropFirst(2) + [userFaces[0]]
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
