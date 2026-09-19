import XCTest
@testable import RinaCore

/// `FaceDocument` decodes leniently on purpose: one malformed entry must not
/// cost the whole library when reading data the board or this app already owns.
/// These tests pin where that leniency stops — a user-initiated import, which
/// is uploaded as a whole-document replacement — and the `frameBytes`/`frameHex`
/// precedence.
final class FaceDocumentDecodingTests: XCTestCase {
    private let zerosHex = "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    private let leadingFFHex = "ff00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    private var zerosBytes: [Int] { Array(repeating: 0, count: PackedFrame.byteCount) }

    private func document(_ faces: String) -> Data {
        Data("""
        {"format":"rina_packed_faces_370_v2","version":4,"faces":[\(faces)]}
        """.utf8)
    }

    private func face(id: String, hex: String) -> String {
        "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"frameHex\":\"\(hex)\",\"order\":1}"
    }

    // MARK: Lossy import detection (A22)

    func testCleanDocumentReportsNothingSkipped() throws {
        let data = document([face(id: "a", hex: zerosHex), face(id: "b", hex: zerosHex)].joined(separator: ","))
        let parsed = try FaceDocument.decodedForImport(jsonData: data)
        XCTAssertEqual(parsed.document.faces.count, 2)
        XCTAssertEqual(parsed.skippedFaceCount, 0)
    }

    /// The audit's reproduction: four entries in, two parse. The import path
    /// must be able to see that two were lost rather than upload the subset.
    func testUnparsableEntriesAreCountedNotSilentlyDropped() throws {
        let faces = [
            face(id: "good1", hex: zerosHex),
            "{\"name\":\"no id at all\",\"frameHex\":\"\(zerosHex)\"}",
            "{\"id\":42,\"name\":\"numeric id\",\"frameHex\":\"\(zerosHex)\"}",
            face(id: "good2", hex: zerosHex),
        ].joined(separator: ",")
        let data = document(faces)

        let parsed = try FaceDocument.decodedForImport(jsonData: data)
        XCTAssertEqual(parsed.document.faces.map(\.id), ["good1", "good2"])
        XCTAssertEqual(parsed.skippedFaceCount, 2)
        XCTAssertTrue(parsed.document.faces.allSatisfy { $0.packedFrame != nil },
                      "survivors look valid, which is exactly why the count is needed")

        // The lenient reading path is deliberately unchanged.
        let lenient = try FaceDocument(jsonData: data)
        XCTAssertEqual(lenient.faces.map(\.id), ["good1", "good2"])
    }

    // MARK: frameBytes / frameHex precedence (A62)

    func testMalformedFrameBytesFallsBackToValidFrameHex() throws {
        let data = document("""
        {"id":"f","name":"f","frameBytes":[999],"frameHex":"\(leadingFFHex)","order":1}
        """)
        let face = try FaceDocument(jsonData: data).faces.first
        XCTAssertNotNil(face?.packedFrame, "a valid frameHex must not be blocked by malformed frameBytes")
        XCTAssertEqual(face?.frameBytes.first, 255)
        XCTAssertEqual(face?.frameBytes.count, PackedFrame.byteCount)
    }

    func testUsableFrameBytesStillWinOverFrameHex() throws {
        let data = document("""
        {"id":"f","name":"f","frameBytes":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"frameHex":"\(leadingFFHex)","order":1}
        """)
        let face = try FaceDocument(jsonData: data).faces.first
        XCTAssertEqual(face?.frameBytes, zerosBytes, "frameBytes keeps precedence when it is usable")
    }

    /// With no usable alternative the original array is still kept, so a
    /// document that used to round-trip is not rewritten.
    func testMalformedFrameBytesArePreservedWhenThereIsNoFallback() throws {
        let data = document("""
        {"id":"f","name":"f","frameBytes":[999],"order":1}
        """)
        let face = try FaceDocument(jsonData: data).faces.first
        XCTAssertEqual(face?.frameBytes, [999])
        XCTAssertNil(face?.packedFrame)
    }

    func testMalformedFrameBytesAndMalformedHexYieldNoFrame() throws {
        let data = document("""
        {"id":"f","name":"f","frameBytes":[999],"frameHex":"zz","order":1}
        """)
        let face = try FaceDocument(jsonData: data).faces.first
        XCTAssertEqual(face?.frameBytes, [999])
        XCTAssertNil(face?.packedFrame)
    }

    // MARK: category / startupDefaultId (R01)

    private static var firmwareSavedFacesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FaceDocumentDecodingTests.swift -> RinaCoreTests/
            .deletingLastPathComponent() // RinaCoreTests -> Tests/
            .deletingLastPathComponent() // Tests -> RinaCore/ (package root)
            .deletingLastPathComponent() // RinaCore -> Packages/
            .deletingLastPathComponent() // Packages -> ios/
            .deletingLastPathComponent() // ios -> repo root
            .appendingPathComponent("esp32s3_firmware/data/resources/saved_faces.json")
    }

    /// The firmware's `validateSavedFaces`/`loadSavedFaces` (`storage.cpp`)
    /// reject any whole-library upload missing `category` or read
    /// `startupDefaultId` at the document's top level; both must survive a
    /// decode→encode round trip of the real bundled fixture unchanged.
    func testRealFirmwareFixtureRoundTripsCategoryAndStartupDefaultId() throws {
        let data = try TestResources.data(at: Self.firmwareSavedFacesURL)
        let document = try FaceDocument(jsonData: data)
        XCTAssertEqual(document.category, FaceDocument.expectedCategory)
        XCTAssertEqual(document.startupDefaultId, "face_08_triangle_eyes_frown")

        let reencoded = try FaceDocument(jsonData: document.encoded())
        XCTAssertEqual(reencoded.category, FaceDocument.expectedCategory)
        XCTAssertEqual(reencoded.startupDefaultId, "face_08_triangle_eyes_frown")
    }

    func testMissingCategoryDecodesWithTheExpectedDefault() throws {
        let data = document(face(id: "a", hex: zerosHex))
        let decoded = try FaceDocument(jsonData: data)
        XCTAssertEqual(decoded.category, FaceDocument.expectedCategory)
    }

    /// A category this app doesn't recognize is preserved verbatim on decode
    /// rather than silently rewritten to `expectedCategory` — only an
    /// explicit refusal (the import path) may reject it.
    func testForeignCategoryIsPreservedByDecode() throws {
        let data = Data("""
        {"format":"rina_packed_faces_370_v2","version":4,"category":"something_else","faces":[\(face(id: "a", hex: zerosHex))]}
        """.utf8)
        let decoded = try FaceDocument(jsonData: data)
        XCTAssertEqual(decoded.category, "something_else")
    }

    // MARK: SavedFace.bytes(fromHex:) strict decoding (R22)

    func testFrameHexRejectsSignedPair() throws {
        let signedHex = "+1" + String(zerosHex.dropFirst(2))
        let data = document(face(id: "a", hex: signedHex))
        let face = try FaceDocument(jsonData: data).faces.first
        XCTAssertEqual(face?.frameBytes, [], "an unusable frameHex with no frameBytes fallback decodes to empty")
        XCTAssertNil(face?.packedFrame)
    }
}
