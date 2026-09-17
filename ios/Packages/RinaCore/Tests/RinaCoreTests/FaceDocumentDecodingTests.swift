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
}
