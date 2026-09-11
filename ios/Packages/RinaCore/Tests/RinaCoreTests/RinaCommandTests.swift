import XCTest
@testable import RinaCore

final class RinaCommandTests: XCTestCase {
    func testSetColorEncodesCmdAndHex() throws {
        let data = try RinaCommand.setColor(hex: "#ec3fc7").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "set_color")
        XCTAssertEqual(obj?["hex"] as? String, "#ec3fc7")
    }

    func testApplySavedFaceIncludesOptionalFields() throws {
        let data = try RinaCommand.applySavedFace(index: 3, reason: "manual", playback: "idle").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["index"] as? Int, 3)
        XCTAssertEqual(obj?["reason"] as? String, "manual")
        XCTAssertEqual(obj?["playback"] as? String, "idle")
    }

    func testNoArgCommandOnlyHasCmdField() throws {
        let data = try RinaCommand.pauseScroll.encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?.count, 1)
        XCTAssertEqual(obj?["cmd"] as? String, "pause_scroll")
    }

    func testFaceRenameEncodesIdAndName() throws {
        let data = try RinaCommand.faceRename(id: "custom_1", name: "笑脸").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "face_rename")
        XCTAssertEqual(obj?["id"] as? String, "custom_1")
        XCTAssertEqual(obj?["name"] as? String, "笑脸")
    }

    func testFaceReorderEncodesIdsInOrder() throws {
        let data = try RinaCommand.faceReorder(ids: ["a", "b", "c"]).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "face_reorder")
        XCTAssertEqual(obj?["ids"] as? [String], ["a", "b", "c"])
    }

    func testFaceDeleteEncodesId() throws {
        let data = try RinaCommand.faceDelete(id: "custom_2").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "face_delete")
        XCTAssertEqual(obj?["id"] as? String, "custom_2")
    }

    func testFaceUpsertEncodesFaceUnderFaceKey() throws {
        let payload = FaceUpsertPayload(
            id: "custom_3", name: "新表情", type: "custom",
            frameHex: String(repeating: "00", count: PackedFrame.byteCount),
            call: nil
        )
        let data = try RinaCommand.faceUpsert(face: payload).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "face_upsert")
        let face = obj?["face"] as? [String: Any]
        XCTAssertEqual(face?["id"] as? String, "custom_3")
        XCTAssertEqual(face?["name"] as? String, "新表情")
        XCTAssertEqual(face?["type"] as? String, "custom")
        XCTAssertEqual(face?["frameHex"] as? String, String(repeating: "00", count: PackedFrame.byteCount))
    }

    func testFaceUpsertWithoutIdOmitsIdField() throws {
        let payload = FaceUpsertPayload(name: "新表情", type: "parts", frameHex: String(repeating: "00", count: PackedFrame.byteCount))
        let data = try RinaCommand.faceUpsert(face: payload).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let face = obj?["face"] as? [String: Any]
        XCTAssertNil(face?["id"])
    }

    func testFacesClearUserOnlyHasCmdField() throws {
        let data = try RinaCommand.facesClearUser.encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?.count, 1)
        XCTAssertEqual(obj?["cmd"] as? String, "faces_clear_user")
    }
}

final class FaceDocumentTests: XCTestCase {
    func testDecodeAndSortByOrder() throws {
        let json = """
        {
          "format": "rina_packed_faces_370_v2",
          "version": 4,
          "faces": [
            {"id":"b","name":"B","type":"default","frameBytes":[\(Array(repeating: 0, count: 47).map(String.init).joined(separator: ","))],"order":2},
            {"id":"a","name":"A","type":"default","frameBytes":[\(Array(repeating: 0, count: 47).map(String.init).joined(separator: ","))],"order":1}
          ]
        }
        """.data(using: .utf8)!
        let doc = try FaceDocument(jsonData: json)
        XCTAssertEqual(doc.sortedFaces.map(\.id), ["a", "b"])
    }

    func testPackedFrameAccessor() throws {
        var bytes = [Int](repeating: 0, count: 47)
        bytes[0] = 1
        let face = SavedFace(id: "x", name: "X", type: .custom, frameBytes: bytes, order: 0)
        XCTAssertNotNil(face.packedFrame)
        XCTAssertTrue(face.packedFrame![0])
    }

    func testEncodeRoundTrip() throws {
        var bytes = [Int](repeating: 0, count: 47)
        bytes[0] = 1
        let face = SavedFace(id: "x", name: "X", type: .custom, frameBytes: bytes, order: 0)
        let doc = FaceDocument(faces: [face])
        let data = try doc.encoded()
        let decoded = try FaceDocument(jsonData: data)
        XCTAssertEqual(decoded, doc)
    }
}
