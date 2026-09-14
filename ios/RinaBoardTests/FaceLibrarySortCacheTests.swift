import XCTest
import RinaCore
@testable import RinaBoard

/// Confirms `FaceLibraryModel`'s cached `faces(in:)`/`defaultFaces`/
/// `userFaces` stay in sync with a from-scratch reference sort of
/// `FaceDocument.sortedFaces` across every mutation path (add, delete,
/// rename/reorder, replace document, load from disk).
@MainActor
final class FaceLibrarySortCacheTests: XCTestCase {
    private func referenceSorted(_ document: FaceDocument) -> [SavedFace] {
        document.faces.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.order != rhs.element.order {
                    return lhs.element.order < rhs.element.order
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func assertCacheMatchesReference(_ model: FaceLibraryModel,
                                              in location: FaceLibraryLocation,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) {
        let expected = referenceSorted(location == .local ? model.localDocument : model.faceDocument)
        XCTAssertEqual(model.faces(in: location).map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(
            model.defaultFaces(in: location).map(\.id),
            expected.filter { $0.type == .default }.map(\.id),
            file: file, line: line
        )
        XCTAssertEqual(
            model.userFaces(in: location).map(\.id),
            expected.filter { $0.type != .default }.map(\.id),
            file: file, line: line
        )
    }

    func testCachedSortStaysConsistentAcrossLocalMutationSequence() async throws {
        let store = PR13TestLocalFaceStore(document: FaceDocument())
        let model = FaceLibraryModel(localStore: store)
        let connection = BoardConnection()

        // Load from disk.
        await model.loadLocalIfNeeded()
        assertCacheMatchesReference(model, in: .local)

        // Add.
        var frame1 = PackedFrame()
        frame1.set(1)
        let outcome1 = await model.saveLocal(FaceUpsertPayload(
            name: "Alpha", type: SavedFace.Kind.custom.rawValue, frameHex: frame1.hex94))
        guard case .saved(let id1?) = outcome1 else { return XCTFail("expected saved id") }
        assertCacheMatchesReference(model, in: .local)

        var frame2 = PackedFrame()
        frame2.set(2)
        let outcome2 = await model.saveLocal(FaceUpsertPayload(
            name: "Beta", type: SavedFace.Kind.custom.rawValue, frameHex: frame2.hex94))
        guard case .saved(let id2?) = outcome2 else { return XCTFail("expected saved id") }
        assertCacheMatchesReference(model, in: .local)

        // Rename.
        guard let beta = model.face(id: id2, in: .local) else { return XCTFail("missing beta") }
        _ = await model.rename(beta, to: "Beta Renamed", in: .local, connection: connection)
        assertCacheMatchesReference(model, in: .local)

        // Reorder.
        let users = model.userFaces(in: .local)
        _ = await model.reorderUserFaces(Array(users.reversed()), in: .local, connection: connection)
        assertCacheMatchesReference(model, in: .local)

        // Delete.
        guard let alpha = model.face(id: id1, in: .local) else { return XCTFail("missing alpha") }
        _ = await model.delete(alpha, from: .local, connection: connection)
        assertCacheMatchesReference(model, in: .local)

        // Undo delete.
        _ = await model.undoLocalDelete()
        assertCacheMatchesReference(model, in: .local)

        // Replace document (reload from disk again after an external store mutation).
        var replaced = FaceDocument()
        var frame3 = PackedFrame()
        frame3.set(3)
        replaced.faces = [
            SavedFace(id: "z", name: "Z", type: .custom, frameBytes: frame3.bytes.map(Int.init), order: 1),
            SavedFace(id: "a", name: "A", type: .custom, frameBytes: frame3.bytes.map(Int.init), order: 1)
        ]
        await store.replace(replaced)
        let fresh = FaceLibraryModel(localStore: store)
        await fresh.loadLocalIfNeeded()
        assertCacheMatchesReference(fresh, in: .local)
        // Tie-break on array index when order is equal: "z" (index 0) sorts
        // before "a" (index 1) despite the name ordering. Bundled defaults
        // are merged in ahead of the stored user faces on load, so check the
        // trailing pair rather than assuming "z"/"a" are first overall.
        XCTAssertEqual(fresh.userFaces(in: .local).map(\.id).suffix(2), ["z", "a"])
    }

    /// `faceDocument` is replaced wholesale on every board reload (see
    /// `FaceLibraryModel.reload(connection:)`); assigning it directly here
    /// exercises the same cache-invalidation path without needing a live
    /// board connection.
    func testCachedSortStaysConsistentAfterBoardDocumentIsReplacedWholesale() {
        let store = PR13TestLocalFaceStore(document: FaceDocument())
        let model = FaceLibraryModel(localStore: store)
        var doc = FaceDocument()
        doc.faces = [
            SavedFace(id: "b1", name: "First", type: .default, frameBytes: [], order: 2),
            SavedFace(id: "b2", name: "Second", type: .custom, frameBytes: [], order: 1)
        ]
        model.faceDocument = doc
        assertCacheMatchesReference(model, in: .board)
        XCTAssertEqual(model.faces(in: .board).map(\.id), ["b2", "b1"])

        // Replacing again (e.g. a subsequent reload) must refresh the cache,
        // not merely append to it.
        model.faceDocument = FaceDocument()
        assertCacheMatchesReference(model, in: .board)
        XCTAssertTrue(model.faces(in: .board).isEmpty)
    }
}

private actor PR13TestLocalFaceStore: LocalFaceStoring {
    private var document: FaceDocument?

    init(document: FaceDocument?) {
        self.document = document
    }

    func load() async throws -> FaceDocument? { document }

    func save(_ document: FaceDocument) async throws {
        self.document = document
    }

    func replace(_ document: FaceDocument) {
        self.document = document
    }
}
