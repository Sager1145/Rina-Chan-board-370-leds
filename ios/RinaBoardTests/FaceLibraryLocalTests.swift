import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class FaceLibraryLocalTests: XCTestCase {
    func testLocalCreateRenameDeleteAndUndoPersistThroughStore() async throws {
        let store = TestLocalFaceStore(document: FaceDocument())
        let model = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await model.loadLocalIfNeeded()

        let outcome = await model.saveLocal(payload(name: "UITest Alpha", led: 1))
        guard case .saved(let id?) = outcome,
              let created = model.face(id: id, in: .local) else {
            return XCTFail("Expected a locally saved face")
        }
        XCTAssertEqual(created.name, "UITest Alpha")

        let renamedSuccessfully = await model.rename(created,
                                                     to: "UITest Renamed",
                                                     in: .local,
                                                     connection: connection)
        XCTAssertTrue(renamedSuccessfully)
        guard let renamed = model.face(id: id, in: .local) else {
            return XCTFail("Renamed face disappeared")
        }
        XCTAssertEqual(renamed.name, "UITest Renamed")

        let deleted = await model.delete(renamed, from: .local, connection: connection)
        XCTAssertTrue(deleted)
        XCTAssertNil(model.face(id: id, in: .local))
        XCTAssertTrue(model.canUndoLocalDelete)

        let restored = await model.undoLocalDelete()
        XCTAssertTrue(restored)
        XCTAssertEqual(model.face(id: id, in: .local)?.name, "UITest Renamed")
        let storedDocument = await store.currentDocument()
        XCTAssertNotNil(storedDocument?.faces.first { $0.id == id })
    }

    func testLocalReorderValidatesCompleteSetAndFailedPersistenceKeepsPublishedOrder() async throws {
        let store = TestLocalFaceStore(document: FaceDocument())
        let model = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()
        await model.loadLocalIfNeeded()
        _ = await model.saveLocal(payload(name: "UITest First", led: 1))
        _ = await model.saveLocal(payload(name: "UITest Second", led: 2))

        let original = model.userFaces(in: .local)
        XCTAssertGreaterThanOrEqual(original.count, 2)
        let reversed = Array(original.reversed())
        let reordered = await model.reorderUserFaces(reversed, in: .local, connection: connection)
        XCTAssertTrue(reordered)
        XCTAssertEqual(model.userFaces(in: .local).map(\.id), reversed.map(\.id))

        let confirmed = model.userFaces(in: .local)
        let rejectedIncompleteOrder = await model.reorderUserFaces(Array(confirmed.dropLast()),
                                                                  in: .local,
                                                                  connection: connection)
        XCTAssertFalse(rejectedIncompleteOrder)
        XCTAssertEqual(model.userFaces(in: .local).map(\.id), confirmed.map(\.id))

        await store.setFailSaves(true)
        guard let first = model.userFaces(in: .local).first else {
            return XCTFail("Expected a local user face")
        }
        let renamedDespiteFailure = await model.rename(first,
                                                       to: "Should Not Publish",
                                                       in: .local,
                                                       connection: connection)
        XCTAssertFalse(renamedDespiteFailure)
        XCTAssertEqual(model.face(id: first.id, in: .local)?.name, first.name)
    }

    private func payload(name: String, led: Int) -> FaceUpsertPayload {
        var frame = PackedFrame()
        frame.set(led)
        return FaceUpsertPayload(name: name,
                                 type: SavedFace.Kind.custom.rawValue,
                                 frameHex: frame.hex94)
    }
}

private actor TestLocalFaceStore: LocalFaceStoring {
    private var document: FaceDocument?
    private var failSaves = false

    init(document: FaceDocument?) {
        self.document = document
    }

    func load() async throws -> FaceDocument? { document }

    func save(_ document: FaceDocument) async throws {
        if failSaves { throw TestLocalFaceStoreError.saveFailed }
        self.document = document
    }

    func setFailSaves(_ value: Bool) {
        failSaves = value
    }

    func currentDocument() -> FaceDocument? { document }
}

private enum TestLocalFaceStoreError: Error {
    case saveFailed
}
