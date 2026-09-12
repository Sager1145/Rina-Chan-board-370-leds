import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class AcceptanceLibraryTests: XCTestCase {
    func testSavedFaceSurvivesNewStoreAndModelInstances() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        let saved = try await create("Disk recovery", led: 27, model: model)

        let reopened = await fixture.reopenedModel()
        let restored = try XCTUnwrap(reopened.face(id: saved.id, in: .local))
        XCTAssertEqual(restored.name, saved.name)
        XCTAssertEqual(restored.packedFrame, saved.packedFrame)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testSelectedExportImportsIntoAnotherLibraryAndSurvivesRestart() async throws {
        let source = LibraryDiskFixture()
        let target = LibraryDiskFixture()
        defer { source.cleanUp(); target.cleanUp() }
        let model = await source.loadedModel()
        let selected = try await create("Export selected", led: 41, model: model)
        _ = try await create("Not selected", led: 42, model: model)
        let exported = try XCTUnwrap(model.exportData(faces: [selected], from: .local))
        let destination = await target.loadedModel()
        await destination.importDocument(from: exported, to: .local, connection: BoardConnection())

        let reopened = await target.reopenedModel()
        let users = reopened.userFaces(in: .local)
        XCTAssertEqual(users.count, 1)
        let imported = try XCTUnwrap(users.first)
        XCTAssertEqual(imported.name, selected.name)
        XCTAssertEqual(imported.packedFrame, selected.packedFrame)
        XCTAssertNotEqual(imported.id, selected.id, "Import must create independent local identity")
    }

    func testDuplicateNamesRemainIndependentWhenOneIsEditedAndReloaded() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        let first = try await create("Same display name", led: 50, model: model)
        let second = try await create("Same display name", led: 51, model: model)
        XCTAssertNotEqual(first.id, second.id)
        let renamed = await model.rename(first, to: "Only first renamed", in: .local, connection: BoardConnection())
        XCTAssertTrue(renamed)

        let reopened = await fixture.reopenedModel()
        XCTAssertEqual(reopened.face(id: first.id, in: .local)?.name, "Only first renamed")
        XCTAssertEqual(reopened.face(id: second.id, in: .local)?.name, "Same display name")
        XCTAssertEqual(reopened.face(id: second.id, in: .local)?.packedFrame, second.packedFrame)
    }

    func testInvalidFrameInImportRejectsWholeDocumentWithoutChangingDisk() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        let existing = try await create("Keep original", led: 60, model: model)
        let before = try Data(contentsOf: fixture.url)
        var invalid = existing
        invalid.id = "invalid-short-frame"
        invalid.frameBytes = [0]
        let data = try FaceDocument(faces: [existing, invalid]).encoded()
        await model.importDocument(from: data, to: .local, connection: BoardConnection())

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.userFaces(in: .local).map(\.id), [existing.id])
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    func testOutOfRangeImportedByteIsRejectedInsteadOfChangingTheFrame() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        let existing = try await create("Keep valid data", led: 70, model: model)
        let before = try Data(contentsOf: fixture.url)
        var invalid = existing
        invalid.id = "invalid-byte-range"
        invalid.frameBytes[0] = 256
        await model.importDocument(from: try FaceDocument(faces: [invalid]).encoded(),
                                   to: .local, connection: BoardConnection())

        XCTAssertNotNil(model.errorMessage, "An out-of-range byte must not silently become a different LED frame")
        XCTAssertEqual(model.userFaces(in: .local).map(\.id), [existing.id])
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    func testProtectedFaceCannotBeRenamedOrDeletedButCanBeCopied() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let protected = SavedFace(id: "locked-local", name: "Protected", type: .custom,
                                  frameBytes: PackedFrame().bytes.map(Int.init), order: 1,
                                  editable: false, deletable: false, locked: true)
        try await fixture.store.save(FaceDocument(faces: [protected]))
        let model = await fixture.loadedModel()
        let connection = BoardConnection()
        let renamed = await model.rename(protected, to: "Must not replace", in: .local, connection: connection)
        let deleted = await model.delete(protected, from: .local, connection: connection)
        XCTAssertFalse(renamed)
        XCTAssertFalse(deleted)
        let copy = await model.duplicate(protected, from: .local, connection: connection)
        guard case .saved(let copyID?) = copy else { return XCTFail("Protected faces should support editable copies") }

        let reopened = await fixture.reopenedModel()
        XCTAssertEqual(reopened.face(id: protected.id, in: .local)?.name, protected.name)
        let copied = try XCTUnwrap(reopened.face(id: copyID, in: .local))
        XCTAssertFalse(reopened.isProtected(copied))
        XCTAssertEqual(copied.packedFrame, protected.packedFrame)
    }

    func testFailedReorderPreservesPublishedAndPersistedOrder() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        _ = try await create("First", led: 80, model: model)
        _ = try await create("Second", led: 81, model: model)
        let original = model.userFaces(in: .local)
        let before = try Data(contentsOf: fixture.url)
        await fixture.store.setFailWrites(true)
        let changed = await model.reorderUserFaces(Array(original.reversed()), in: .local, connection: BoardConnection())

        XCTAssertFalse(changed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.userFaces(in: .local).map(\.id), original.map(\.id))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        let reopened = await fixture.reopenedModel()
        XCTAssertEqual(reopened.userFaces(in: .local).map(\.id), original.map(\.id))
    }

    func testFailedUndoRetainsRetryAndSuccessfulRetrySurvivesRestart() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        let face = try await create("Undo retry", led: 90, model: model)
        let deleted = await model.delete(face, from: .local, connection: BoardConnection())
        XCTAssertTrue(deleted)
        let afterDelete = try Data(contentsOf: fixture.url)
        await fixture.store.setFailWrites(true)
        let failedUndo = await model.undoLocalDelete()
        XCTAssertFalse(failedUndo)
        XCTAssertTrue(model.canUndoLocalDelete)
        XCTAssertNil(model.face(id: face.id, in: .local))
        XCTAssertEqual(try Data(contentsOf: fixture.url), afterDelete)

        await fixture.store.setFailWrites(false)
        let retried = await model.undoLocalDelete()
        XCTAssertTrue(retried)
        XCTAssertFalse(model.canUndoLocalDelete)
        let reopened = await fixture.reopenedModel()
        XCTAssertEqual(reopened.face(id: face.id, in: .local)?.packedFrame, face.packedFrame)
    }

    func testBatchCopyReportsInvalidItemAndPersistsOnlySuccessfulCopies() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        let valid = SavedFace(id: "source-valid", name: "Valid source", type: .custom,
                              frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        var invalid = valid
        invalid.id = "source-invalid"
        invalid.frameBytes = []
        let result = await model.copy([valid, invalid], from: .board, to: .local, connection: BoardConnection())

        XCTAssertEqual(result.succeededIDs, [valid.id])
        XCTAssertEqual(Set(result.failures.keys), [invalid.id])
        let reopened = await fixture.reopenedModel()
        XCTAssertEqual(reopened.userFaces(in: .local).count, 1)
        XCTAssertEqual(reopened.userFaces(in: .local).first?.packedFrame, valid.packedFrame)
    }

    func testFailedImportLeavesExistingLibraryIntactAfterRestart() async throws {
        let fixture = LibraryDiskFixture()
        defer { fixture.cleanUp() }
        let model = await fixture.loadedModel()
        let face = try await create("Existing", led: 100, model: model)
        let before = try Data(contentsOf: fixture.url)
        let imported = SavedFace(id: "new-import", name: "New import", type: .custom,
                                 frameBytes: PackedFrame().bytes.map(Int.init), order: 1)
        await fixture.store.setFailWrites(true)
        await model.importDocument(from: try FaceDocument(faces: [imported]).encoded(),
                                   to: .local, connection: BoardConnection())

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.userFaces(in: .local).map(\.id), [face.id])
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        let reopened = await fixture.reopenedModel()
        XCTAssertEqual(reopened.userFaces(in: .local).map(\.id), [face.id])
    }

    private func create(_ name: String, led: Int, model: FaceLibraryModel) async throws -> SavedFace {
        var frame = PackedFrame()
        frame.set(led)
        let outcome = await model.saveLocal(FaceUpsertPayload(name: name, type: "custom", frameHex: frame.hex94))
        guard case .saved(let id?) = outcome else {
            XCTFail("Fixture face was not saved: \(model.errorMessage ?? "unknown")")
            throw LibraryWriteFailure.injected
        }
        return try XCTUnwrap(model.face(id: id, in: .local))
    }
}

@MainActor
private final class LibraryDiskFixture {
    let directory: URL
    let url: URL
    let store: FailingDiskFaceStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-AcceptanceLibrary-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("faces.json")
        store = FailingDiskFaceStore(backing: LocalFaceStore(fileURL: url))
    }

    func loadedModel() async -> FaceLibraryModel {
        let model = FaceLibraryModel(localStore: store)
        await model.loadLocalIfNeeded()
        return model
    }

    func reopenedModel() async -> FaceLibraryModel {
        let model = FaceLibraryModel(localStore: LocalFaceStore(fileURL: url))
        await model.loadLocalIfNeeded()
        return model
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private actor FailingDiskFaceStore: LocalFaceStoring {
    private let backing: LocalFaceStore
    private var failWrites = false

    init(backing: LocalFaceStore) { self.backing = backing }
    func setFailWrites(_ value: Bool) { failWrites = value }
    func load() async throws -> FaceDocument? { try await backing.load() }
    func save(_ document: FaceDocument) async throws {
        if failWrites { throw LibraryWriteFailure.injected }
        try await backing.save(document)
    }
}

private enum LibraryWriteFailure: Error { case injected }
