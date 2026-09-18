import XCTest
@testable import RinaCore

/// JSON encoding of the board-group `CMD`s (BOARD_GROUP_SPEC.md §1.2/§1.3/§1.5/§2).
final class BoardGroupCommandTests: XCTestCase {
    func testIdentifyEncodesNumberAndTtlMs() throws {
        let data = try RinaCommand.identify(number: 3, ttlMs: 5000).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "identify")
        XCTAssertEqual(obj?["number"] as? Int, 3)
        XCTAssertEqual(obj?["ttlMs"] as? Int, 5000)
    }

    func testIdentifyOmitsTtlMsWhenNil() throws {
        let data = try RinaCommand.identify(number: 7, ttlMs: nil).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?.count, 2)
        XCTAssertNil(obj?["ttlMs"])
    }

    func testIdentifyZeroTtlMsCancels() throws {
        let data = try RinaCommand.identify(number: 3, ttlMs: 0).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ttlMs"] as? Int, 0)
    }

    func testClockSampleHasOnlyCmdField() throws {
        let data = try RinaCommand.clockSample.encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?.count, 1)
        XCTAssertEqual(obj?["cmd"] as? String, "clock_sample")
    }

    func testGroupStartEncodesRequiredFields() throws {
        let data = try RinaCommand.groupStart(
            atUs: 123_456_789_012, bootId: "a1b2c3d4", intervalMs: 120, startFrame: nil, loop: nil
        ).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["cmd"] as? String, "group_start")
        XCTAssertEqual((obj?["atUs"] as? NSNumber)?.int64Value, 123_456_789_012)
        XCTAssertEqual(obj?["bootId"] as? String, "a1b2c3d4")
        XCTAssertEqual(obj?["intervalMs"] as? Int, 120)
        XCTAssertNil(obj?["startFrame"])
        XCTAssertNil(obj?["loop"])
    }

    func testGroupStartEncodesOptionalFieldsWhenPresent() throws {
        let data = try RinaCommand.groupStart(
            atUs: 1, bootId: "b", intervalMs: 80, startFrame: 12, loop: false
        ).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["startFrame"] as? Int, 12)
        XCTAssertEqual(obj?["loop"] as? Bool, false)
    }
}
