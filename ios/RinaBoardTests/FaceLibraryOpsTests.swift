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

    func testReorderFacesLocalInterleavedPersistsAcrossFreshLoad() async throws {
        let store = OpsTestLocalFaceStore(document: FaceDocument())
        let library = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await library.loadLocalIfNeeded()
        _ = await library.saveLocal(payload(name: "User One", led: 1))
        _ = await library.saveLocal(payload(name: "User Two", led: 2))

        let all = library.faces(in: .local)
        XCTAssertGreaterThanOrEqual(all.count, 2, "Expects at least the two user faces just saved")
        let interleaved = Array(all.reversed())
        let reordered = await library.reorderFaces(interleaved, in: .local, connection: connection)
        XCTAssertTrue(reordered)
        XCTAssertEqual(library.faces(in: .local).map(\.id), interleaved.map(\.id))

        // A brand new model reading the same on-disk store must not reset the
        // interleaving that `mergedWithBundledDefaults` sees on every launch.
        let reloaded = FaceLibraryModel(localStore: store)
        await reloaded.loadLocalIfNeeded()
        XCTAssertEqual(reloaded.faces(in: .local).map(\.id), interleaved.map(\.id))
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
