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
        let data = try RinaCommand.applySavedFace(index: 3, id: nil, reason: "manual", playback: "idle").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["index"] as? Int, 3)
        XCTAssertEqual(obj?["reason"] as? String, "manual")
        XCTAssertEqual(obj?["playback"] as? String, "idle")
    }

    func testApplySavedFaceEncodesIdWhenSetAndOmitsWhenNil() throws {
        let withId = try JSONSerialization.jsonObject(
            with: RinaCommand.applySavedFace(index: 3, id: "abc123", reason: nil, playback: nil).encode()
        ) as? [String: Any]
        XCTAssertEqual(withId?["index"] as? Int, 3)
        XCTAssertEqual(withId?["id"] as? String, "abc123")

        let withoutId = try JSONSerialization.jsonObject(
            with: RinaCommand.applySavedFace(index: 3, id: nil, reason: nil, playback: nil).encode()
        ) as? [String: Any]
        XCTAssertEqual(withoutId?["index"] as? Int, 3)
        XCTAssertNil(withoutId?["id"])
    }

    func testSetHintLEDEncodesLedAndMinusOneToClear() throws {
        let set = try JSONSerialization.jsonObject(with: RinaCommand.setHintLED(led: 57).encode()) as? [String: Any]
        XCTAssertEqual(set?["cmd"] as? String, "set_hint_led")
        XCTAssertEqual(set?["led"] as? Int, 57)
        let clear = try JSONSerialization.jsonObject(with: RinaCommand.setHintLED(led: nil).encode()) as? [String: Any]
        XCTAssertEqual(clear?["led"] as? Int, -1)
        XCTAssertNil(set?["mirror"])
    }

    func testSetHintLEDEncodesMirrorOnlyWithAnLED() throws {
        let pair = try JSONSerialization.jsonObject(with: RinaCommand.setHintLED(led: 57, mirror: 60).encode()) as? [String: Any]
        XCTAssertEqual(pair?["led"] as? Int, 57)
        XCTAssertEqual(pair?["mirror"] as? Int, 60)
        let clear = try JSONSerialization.jsonObject(with: RinaCommand.setHintLED(led: nil, mirror: 60).encode()) as? [String: Any]
        XCTAssertEqual(clear?["led"] as? Int, -1)
        XCTAssertNil(clear?["mirror"])
    }

    func testScrollSeekEncodesFrameIndex() throws {
        let data = try RinaCommand.scrollSeek(frameIndex: 42).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "scroll_seek")
        XCTAssertEqual(obj?["frameIndex"] as? Int, 42)
    }

    func testSetScrollLoopEncodesBool() throws {
        let data = try RinaCommand.setScrollLoop(loop: false).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "set_scroll_loop")
        XCTAssertEqual(obj?["loop"] as? Bool, false)
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

    func testFaceUpsertEncodesExpectWhenSetAndOmitsWhenNil() throws {
        let withExpect = FaceUpsertPayload(
            id: "custom_3", name: "新表情", type: "custom",
            frameHex: String(repeating: "00", count: PackedFrame.byteCount),
            expect: FaceExpectation(name: "旧表情", frameHex: String(repeating: "11", count: PackedFrame.byteCount))
        )
        let dataWithExpect = try RinaCommand.faceUpsert(face: withExpect).encode()
        let objWithExpect = try JSONSerialization.jsonObject(with: dataWithExpect) as? [String: Any]
        let faceWithExpect = objWithExpect?["face"] as? [String: Any]
        let expect = faceWithExpect?["expect"] as? [String: Any]
        XCTAssertEqual(expect?["name"] as? String, "旧表情")
        XCTAssertEqual(expect?["frameHex"] as? String, String(repeating: "11", count: PackedFrame.byteCount))

        let withoutExpect = FaceUpsertPayload(
            id: "custom_3", name: "新表情", type: "custom",
            frameHex: String(repeating: "00", count: PackedFrame.byteCount)
        )
        let dataWithoutExpect = try RinaCommand.faceUpsert(face: withoutExpect).encode()
        let objWithoutExpect = try JSONSerialization.jsonObject(with: dataWithoutExpect) as? [String: Any]
        let faceWithoutExpect = objWithoutExpect?["face"] as? [String: Any]
        XCTAssertNil(faceWithoutExpect?["expect"])
    }

    func testWifiSetHotspotCredentialsEncodesSsidAndPassword() throws {
        let data = try RinaCommand.wifiSetHotspotCredentials(ssid: "iPhone", password: "hunter2").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "wifi_set_hotspot_credentials")
        XCTAssertEqual(obj?["ssid"] as? String, "iPhone")
        XCTAssertEqual(obj?["password"] as? String, "hunter2")
    }

    func testWifiClearHotspotCredentialsOnlyHasCmdField() throws {
        let data = try RinaCommand.wifiClearHotspotCredentials.encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?.count, 1)
        XCTAssertEqual(obj?["cmd"] as? String, "wifi_clear_hotspot_credentials")
    }

    func testFacesClearUserOnlyHasCmdField() throws {
        let data = try RinaCommand.facesClearUser.encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?.count, 1)
        XCTAssertEqual(obj?["cmd"] as? String, "faces_clear_user")
    }

    func testSetDeviceNameEncodesCmdAndName() throws {
        let data = try RinaCommand.setDeviceName(name: "客厅").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?.count, 2)
        XCTAssertEqual(obj?["cmd"] as? String, "set_device_name")
        XCTAssertEqual(obj?["name"] as? String, "客厅")
    }

    func testSetDeviceNameWithEmptyStringEncodesEmptyName() throws {
        let data = try RinaCommand.setDeviceName(name: "").encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "set_device_name")
        XCTAssertEqual(obj?["name"] as? String, "")
    }
}

final class DeviceNameValidatorTests: XCTestCase {
    func test24ByteAsciiNameIsValid() {
        let name = String(repeating: "a", count: 24)
        XCTAssertEqual(DeviceNameValidator.validateDeviceName(name), .valid)
    }

    func test25ByteAsciiNameIsTooLong() {
        let name = String(repeating: "a", count: 25)
        XCTAssertEqual(DeviceNameValidator.validateDeviceName(name), .tooLong(bytes: 25))
    }

    func testWhitespaceOnlyNameIsEmpty() {
        XCTAssertEqual(DeviceNameValidator.validateDeviceName("  "), .empty)
    }

    func testEightCharacterCJKNameIsValid() {
        // Each CJK character is 3 UTF-8 bytes, so 8 * 3 == 24 bytes.
        let name = String(repeating: "客", count: 8)
        XCTAssertEqual(name.utf8.count, 24)
        XCTAssertEqual(DeviceNameValidator.validateDeviceName(name), .valid)
    }

    func testNineCharacterCJKNameIsTooLong() {
        // 9 * 3 == 27 bytes.
        let name = String(repeating: "客", count: 9)
        XCTAssertEqual(name.utf8.count, 27)
        XCTAssertEqual(DeviceNameValidator.validateDeviceName(name), .tooLong(bytes: 27))
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

    func testPackedFrameAccessorRejectsOutOfRangeBytes() {
        var bytes = [Int](repeating: 0, count: PackedFrame.byteCount)
        bytes[0] = 256
        let tooLarge = SavedFace(id: "large", name: "Large", type: .custom,
                                 frameBytes: bytes, order: 0)
        XCTAssertNil(tooLarge.packedFrame)

        bytes[0] = -1
        let negative = SavedFace(id: "negative", name: "Negative", type: .custom,
                                 frameBytes: bytes, order: 0)
        XCTAssertNil(negative.packedFrame)
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
