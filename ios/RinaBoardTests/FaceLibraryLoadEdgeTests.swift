import XCTest
import RinaCore
@testable import RinaBoard

/// Covers the local-library load path's handling of a lenient-decoder
/// partial read: `LocalFaceStore.load()` must not let a skipped/malformed
/// entry look like a clean, complete read (which would let a later save
/// silently discard whatever failed to parse).
@MainActor
final class FaceLibraryLoadEdgeTests: XCTestCase {
    private func payload(name: String, led: Int) -> FaceUpsertPayload {
        var frame = PackedFrame()
        frame.set(led)
        return FaceUpsertPayload(name: name,
                                 type: SavedFace.Kind.custom.rawValue,
                                 frameHex: frame.hex94)
    }

    private func face(id: String, name: String, led: Int) -> SavedFace {
        var frame = PackedFrame()
        frame.set(led)
        return SavedFace(id: id, name: name, type: .custom,
                         frameBytes: frame.bytes.map(Int.init), order: 1)
    }

    // MARK: FaceLibraryModel behavior on a partially-unreadable store

    /// A store whose `load()` throws `partiallyUnreadable` must still let the
    /// user see whatever parsed, but must not be treated as a complete,
    /// trustworthy read: persistence stays blocked and the error names the
    /// skipped count.
    func testLoadLocalIfNeededWithPartiallyUnreadableStoreShowsPartialButBlocksSave() async throws {
        let survivor = face(id: "kept", name: "Kept", led: 5)
        let partial = FaceDocument(faces: [survivor])
        let store = PartiallyUnreadableLocalFaceStore(document: partial, skippedCount: 1)
        let model = FaceLibraryModel(localStore: store)

        await model.loadLocalIfNeeded()

        XCTAssertFalse(model.isLocalLoaded)
        XCTAssertTrue(model.userFaces(in: .local).contains { $0.id == "kept" },
                      "The entries that did parse must still be shown")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("1") ?? false,
                      "The error must mention how many entries could not be read")

        let outcome = await model.saveLocal(payload(name: "Should Not Save", led: 9))
        XCTAssertEqual(outcome, .failed, "Saving must stay refused while the on-disk file is known partially unreadable")
    }

    // MARK: reloadLocal must not publish a fallback before it is durably saved

    /// `reloadLocal`'s no-file branch used to assign `localDocument` to the
    /// bundled defaults and only afterwards try to save them; if that save
    /// failed, memory had already been overwritten. It must build the
    /// candidate, persist it, and only then publish — so a failed save here
    /// leaves the previously loaded document untouched.
    func testReloadLocalNoFileBranchDoesNotPublishBeforeSaveSucceeds() async throws {
        let original = FaceDocument(faces: [face(id: "orig", name: "Original", led: 3)])
        let store = NilThenFailSaveLocalFaceStore(firstLoad: original)
        let model = FaceLibraryModel(localStore: store)

        await model.loadLocalIfNeeded()
        XCTAssertTrue(model.isLocalLoaded)
        XCTAssertTrue(model.faces(in: .local).contains { $0.id == "orig" })
        let afterFirstLoad = model.localDocument

        await model.reloadLocal()

        XCTAssertTrue(model.isLocalLoaded,
                      "A reload whose save failed must not un-load a previously trustworthy library")
        XCTAssertEqual(model.localDocument, afterFirstLoad,
                       "A reload whose save failed must not replace the in-memory document with the unsaved fallback")
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: LocalFaceStore itself

    func testLocalFaceStoreThrowsMalformedWhenFacesIsNotAnArray() async throws {
        let fileURL = try makeTempFile()
        defer { cleanUp(fileURL) }
        let json = """
        {"format":"rina_packed_faces_370_v2","version":4,"category":"unified_saved_faces","faces":"nope"}
        """
        try Data(json.utf8).write(to: fileURL)
        let store = LocalFaceStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected LocalFaceStoreError.malformed")
        } catch LocalFaceStoreError.malformed {
            // expected
        } catch {
            XCTFail("Expected LocalFaceStoreError.malformed, got \(error)")
        }
    }

    func testLocalFaceStoreThrowsPartiallyUnreadableWithSkippedCountOne() async throws {
        let fileURL = try makeTempFile()
        defer { cleanUp(fileURL) }
        let goodFrame = String(repeating: "00", count: 47)
        let json = """
        {
          "format": "rina_packed_faces_370_v2",
          "version": 4,
          "category": "unified_saved_faces",
          "faces": [
            {"id": "good1", "name": "Good", "type": "custom", "frameHex": "\(goodFrame)", "order": 1},
            {"name": "Missing id", "type": "custom", "frameHex": "\(goodFrame)", "order": 2}
          ]
        }
        """
        try Data(json.utf8).write(to: fileURL)
        let store = LocalFaceStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected LocalFaceStoreError.partiallyUnreadable")
        } catch LocalFaceStoreError.partiallyUnreadable(let document, let skippedCount) {
            XCTAssertEqual(skippedCount, 1)
            XCTAssertEqual(document.faces.map(\.id), ["good1"])
        } catch {
            XCTFail("Expected LocalFaceStoreError.partiallyUnreadable, got \(error)")
        }
    }

    func testLocalFaceStoreLoadsAValidFile() async throws {
        let fileURL = try makeTempFile()
        defer { cleanUp(fileURL) }
        let document = FaceDocument(faces: [face(id: "a", name: "A", led: 1)])
        try document.encoded().write(to: fileURL)
        let store = LocalFaceStore(fileURL: fileURL)

        let loaded = try await store.load()
        XCTAssertEqual(loaded?.faces.map(\.id), ["a"])
    }

    // MARK: Helpers

    private func makeTempFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceLibraryLoadEdgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("local_faces.json")
    }

    private func cleanUp(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

/// Always throws `LocalFaceStoreError.partiallyUnreadable` from `load()`.
private actor PartiallyUnreadableLocalFaceStore: LocalFaceStoring {
    private let document: FaceDocument
    private let skippedCount: Int
    private(set) var savedDocument: FaceDocument?

    init(document: FaceDocument, skippedCount: Int) {
        self.document = document
        self.skippedCount = skippedCount
    }

    func load() async throws -> FaceDocument? {
        throw LocalFaceStoreError.partiallyUnreadable(document: document, skippedCount: skippedCount)
    }

    func save(_ document: FaceDocument) async throws {
        savedDocument = document
    }
}

/// Returns `firstLoad` on the first `load()` call (so `loadLocalIfNeeded`
/// succeeds), then `nil` on every later call (so `reloadLocal` takes the
/// no-file branch); every `save()` call throws, simulating a disk write
/// failure on the fallback save.
private actor NilThenFailSaveLocalFaceStore: LocalFaceStoring {
    private let firstLoad: FaceDocument
    private var loadCount = 0

    init(firstLoad: FaceDocument) {
        self.firstLoad = firstLoad
    }

    func load() async throws -> FaceDocument? {
        loadCount += 1
        return loadCount == 1 ? firstLoad : nil
    }

    func save(_ document: FaceDocument) async throws {
        throw NilThenFailSaveLocalFaceStoreError.saveFailed
    }
}

private enum NilThenFailSaveLocalFaceStoreError: Error {
    case saveFailed
}
