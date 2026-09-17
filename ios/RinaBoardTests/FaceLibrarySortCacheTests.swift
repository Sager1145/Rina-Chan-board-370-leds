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

    /// `testCachedSortStaysConsistentAfterBoardDocumentIsReplacedWholesale`
    /// only exercises wholesale document replacement. Rename, reorder,
    /// upsert and delete all mutate `faceDocument` *in place* (e.g.
    /// `faceDocument.faces[index].name = ...`, `faceDocument.faces.removeAll
    /// { ... }`, `assignOrders(..., in: &faceDocument)`) when
    /// `connection.lastFaceOpGenMatchedExpectation` is true, and only fall
    /// back to a wholesale `reload` otherwise. Since the view now renders
    /// `cachedBoardSortedFaces` (not `faceDocument.sortedFaces` directly), a
    /// future refactor of one of those in-place paths that bypassed
    /// `faceDocument`'s `didSet` would silently freeze the board face list
    /// with nothing else failing — this drives each in-place path over a
    /// real (faked) board connection and confirms the cache tracks it.
    func testCachedSortStaysConsistentAcrossBoardInPlaceMutationSequence() async throws {
        let store = PR13TestLocalFaceStore(document: FaceDocument())
        let model = FaceLibraryModel(localStore: store)
        let (connection, transport) = await connectedBoard()

        var frameDefault = PackedFrame()
        frameDefault.set(0)
        var frameU1 = PackedFrame()
        frameU1.set(1)
        var frameU2 = PackedFrame()
        frameU2.set(2)
        let initial = FaceDocument(faces: [
            SavedFace(id: "d1", name: "Default", type: .default,
                     frameBytes: frameDefault.bytes.map(Int.init), order: 1,
                     editable: false, deletable: false, locked: true),
            SavedFace(id: "u1", name: "U1", type: .custom,
                     frameBytes: frameU1.bytes.map(Int.init), order: 3),
            SavedFace(id: "u2", name: "U2", type: .custom,
                     frameBytes: frameU2.bytes.map(Int.init), order: 2)
        ])
        try await reloadBoard(model, connection: connection, transport: transport, document: initial)
        assertCacheMatchesReference(model, in: .board)
        XCTAssertEqual(model.faces(in: .board).map(\.id), ["d1", "u2", "u1"])

        // Rename (in-place: `faceDocument.faces[index].name = ...`).
        guard let u1 = model.face(id: "u1", in: .board) else { return XCTFail("missing u1") }
        let renamed = await model.rename(u1, to: "U1 Renamed", in: .board, connection: connection)
        XCTAssertTrue(renamed)
        XCTAssertTrue(connection.lastFaceOpGenMatchedExpectation,
                      "test setup must exercise the in-place path, not a reload fallback")
        assertCacheMatchesReference(model, in: .board)
        XCTAssertEqual(model.face(id: "u1", in: .board)?.name, "U1 Renamed")

        // Reorder (in-place: `assignOrders(..., in: &faceDocument)`).
        let reordered = await model.reorderUserFaces(
            [model.face(id: "u1", in: .board)!, model.face(id: "u2", in: .board)!],
            in: .board, connection: connection
        )
        XCTAssertTrue(reordered)
        assertCacheMatchesReference(model, in: .board)
        XCTAssertEqual(model.faces(in: .board).map(\.id), ["d1", "u1", "u2"])

        // Upsert an existing id (in-place: `faceDocument.faces[index].name = ...`
        // plus frame/type/updatedAt/call, without a full `reload`).
        var frameU2Updated = PackedFrame()
        frameU2Updated.set(9)
        let saveOutcome = await model.save(
            FaceUpsertPayload(id: "u2", name: "U2 Updated", type: "custom", frameHex: frameU2Updated.hex94),
            connection: connection
        )
        XCTAssertEqual(saveOutcome, .saved(id: "u2"))
        assertCacheMatchesReference(model, in: .board)
        XCTAssertEqual(model.face(id: "u2", in: .board)?.name, "U2 Updated")

        // Delete (in-place: `faceDocument.faces.removeAll { ... }`).
        guard let u1Latest = model.face(id: "u1", in: .board) else { return XCTFail("missing u1") }
        let deleted = await model.delete(u1Latest, from: .board, connection: connection)
        XCTAssertTrue(deleted)
        assertCacheMatchesReference(model, in: .board)
        XCTAssertNil(model.face(id: "u1", in: .board))
        XCTAssertEqual(model.faces(in: .board).map(\.id), ["d1", "u2"])
    }

    // MARK: Board connection test helpers

    private func connectedBoard() async -> (BoardConnection, FakeRinaTransport) {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    /// Drives `model.reload(connection:)` through a single-page `GET_FACES`
    /// round trip against `transport`, replying with `document` under a
    /// fixed generation — mirroring the wire format `BoardConnection.getFaces()`
    /// expects (4-byte little-endian gen prefix + JSON body, no `FLAG_MORE`
    /// on this terminal frame).
    private func reloadBoard(_ model: FaceLibraryModel, connection: BoardConnection,
                             transport: FakeRinaTransport, document: FaceDocument,
                             gen: UInt32 = 1) async throws {
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let reloadTask = Task { await model.reload(connection: connection) }
        try await transport.waitForSent(type: .getFaces, count: 1)
        var genBytes = Data(count: 4)
        genBytes[0] = UInt8(gen & 0xFF)
        genBytes[1] = UInt8((gen >> 8) & 0xFF)
        genBytes[2] = UInt8((gen >> 16) & 0xFF)
        genBytes[3] = UInt8((gen >> 24) & 0xFF)
        transport.replyToNext(type: .getFaces, payload: genBytes + (try document.encoded()))
        let reloaded = await reloadTask.value
        XCTAssertTrue(reloaded, "board reload setup must succeed")
        // Mutations after a read at `gen` reply with gen+1, as the firmware does.
        // Without a `gen` the connection cannot confirm we are still in sync and
        // every op would fall back to a reload, so the in-place paths this suite
        // exercises would never run.
        transport.nextCommandGen = Int(gen) + 1
        transport.automaticallyReplies = true
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
