import XCTest
@testable import RinaCore

/// `DeviceInfo.bootId`/`.caps` and `BoardCapability` (BOARD_GROUP_SPEC.md
/// §1.1/§2), plus the group-command reply structs and the `scroll_bitmap`
/// END reply's `virtualWidth`/`viewportX` echoes (§1.4).
final class BoardGroupMessagesTests: XCTestCase {
    // MARK: - DeviceInfo / BoardCapability

    func testDeviceInfoDecodesBootIdAndCaps() throws {
        let json = """
        {"ok":true,"device":"rina","fw":"2.0.0","bootId":"a1b2c3d4",\
        "caps":["identify","clock_sample","scroll_viewport","group_start"]}
        """
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.bootId, "a1b2c3d4")
        XCTAssertEqual(info.caps, ["identify", "clock_sample", "scroll_viewport", "group_start"])
        XCTAssertTrue(info.supports(.identify))
        XCTAssertTrue(info.supports(.clockSample))
        XCTAssertTrue(info.supports(.scrollViewport))
        XCTAssertTrue(info.supports(.groupStart))
    }

    /// Old firmware answers `get_info` without `bootId`/`caps` at all —
    /// decoding must still succeed, and every capability must read as unsupported.
    func testDeviceInfoDecodesWithoutBootIdOrCapsOldFirmware() throws {
        let json = """
        {"ok":true,"device":"rina","fw":"1.9.0","build":"x","ledBackend":"rmt",\
        "ledDma":false,"heapFree":100000,"psramFree":0,"psramSize":0,"uptimeMs":1000,"proto":1}
        """
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertNil(info.bootId)
        XCTAssertNil(info.caps)
        XCTAssertFalse(info.supports(.identify))
        XCTAssertFalse(info.supports(.clockSample))
        XCTAssertFalse(info.supports(.scrollViewport))
        XCTAssertFalse(info.supports(.groupStart))
    }

    /// A board that reports only a subset of caps (e.g. mid-rollout firmware).
    func testDeviceInfoPartialCaps() throws {
        let json = """
        {"ok":true,"bootId":"deadbeef","caps":["identify"]}
        """
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertTrue(info.supports(.identify))
        XCTAssertFalse(info.supports(.groupStart))
    }

    func testBoardCapabilityRawValuesMatchSpec() {
        XCTAssertEqual(BoardCapability.identify.rawValue, "identify")
        XCTAssertEqual(BoardCapability.clockSample.rawValue, "clock_sample")
        XCTAssertEqual(BoardCapability.scrollViewport.rawValue, "scroll_viewport")
        XCTAssertEqual(BoardCapability.groupStart.rawValue, "group_start")
    }

    // MARK: - scroll_bitmap END reply echoes (§1.4)

    func testScrollUploadReplyDecodesViewportEchoes() throws {
        let json = """
        {"ok":true,"frames":150,"width":250,"rotation":0,"virtualWidth":110,"viewportX":22}
        """
        let reply = try JSONDecoder().decode(ScrollUploadReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.rotation, 0)
        XCTAssertEqual(reply.virtualWidth, 110)
        XCTAssertEqual(reply.viewportX, 22)
    }

    /// Single-board (non-group) uploads never send the viewport fields.
    func testScrollUploadReplyDecodesWithoutViewportFields() throws {
        let json = """
        {"ok":true,"frames":150,"width":250,"rotation":4}
        """
        let reply = try JSONDecoder().decode(ScrollUploadReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.rotation, 4)
        XCTAssertNil(reply.virtualWidth)
        XCTAssertNil(reply.viewportX)
    }

    // MARK: - Reply structs (§1.2/§1.3/§1.5)

    func testIdentifyReplyDecodes() throws {
        let json = #"{"ok":true,"shown":true,"number":3,"ttlMs":5000}"#
        let reply = try JSONDecoder().decode(IdentifyReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.ok, true)
        XCTAssertEqual(reply.shown, true)
        XCTAssertEqual(reply.number, 3)
        XCTAssertEqual(reply.ttlMs, 5000)
    }

    func testClockSampleReplyDecodes() throws {
        let json = #"{"ok":true,"rxUs":1234567890123,"txUs":1234567890456,"bootId":"a1b2c3d4"}"#
        let reply = try JSONDecoder().decode(ClockSampleReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.rxUs, 1234567890123)
        XCTAssertEqual(reply.txUs, 1234567890456)
        XCTAssertEqual(reply.bootId, "a1b2c3d4")
    }

    func testGroupStartReplyDecodes() throws {
        let json = #"{"ok":true,"nowUs":9876543210,"frameCount":150}"#
        let reply = try JSONDecoder().decode(GroupStartReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.nowUs, 9876543210)
        XCTAssertEqual(reply.frameCount, 150)
    }

    func testGroupStartReplyBootMismatchIsGenericErrorReply() throws {
        // `ERR 409 boot_mismatch` decodes with the shared ErrorReply, not GroupStartReply.
        let json = #"{"ok":false,"error":"boot_mismatch","code":409}"#
        let reply = try JSONDecoder().decode(ErrorReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.error, "boot_mismatch")
        XCTAssertEqual(reply.code, 409)
    }
}
