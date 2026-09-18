import XCTest
@testable import RinaCore

/// `addPower()` in protocol.cpp is emitted two ways: wrapped as
/// `{"ok":true,"power":{…}}` by EV_POWER / GET_POWER, and bare as
/// `status.power`. Both must yield the battery fields.
final class PowerStatusDecodingTests: XCTestCase {
    private let fields = """
    {"ok":true,"charging":false,"chargeValid":true,"batteryValid":true,"batteryPercent":29,\
    "vbat":3.71,"vcharge":0,"batteryPowered":true,"batteryDisconnected":false,\
    "batteryLowVoltageUnpowered":false}
    """

    func testWrappedEventPayload() throws {
        let data = Data("{\"ok\":true,\"power\":\(fields)}".utf8)
        let power = try JSONDecoder().decode(PowerStatus.self, from: data)
        XCTAssertEqual(power.batteryPercent, 29)
        XCTAssertEqual(power.batteryValid, true)
        XCTAssertEqual(power.batteryDisconnected, false)
        XCTAssertEqual(power.vbat ?? 0, 3.71, accuracy: 0.001)
    }

    func testBareObject() throws {
        let power = try JSONDecoder().decode(PowerStatus.self, from: Data(fields.utf8))
        XCTAssertEqual(power.batteryPercent, 29)
        XCTAssertEqual(power.batteryPowered, true)
    }

    func testNestedInStatus() throws {
        let data = Data("{\"ok\":true,\"v\":3,\"power\":\(fields)}".utf8)
        let status = try JSONDecoder().decode(DeviceStatus.self, from: data)
        XCTAssertEqual(status.power?.batteryPercent, 29)
    }

    /// `FlexibleNumber.int` accepts a JSON float for an integral field. An
    /// out-of-range or non-finite value must decode as `nil` rather than trap,
    /// while in-range floats keep truncating toward zero as before.
    func testFlexibleIntegerRejectsOutOfRangeFloatInsteadOfTrapping() throws {
        func percent(_ literal: String) throws -> Int? {
            let json = "{\"ok\":true,\"batteryPercent\":\(literal)}"
            return try JSONDecoder().decode(PowerStatus.self, from: Data(json.utf8)).batteryPercent
        }
        XCTAssertEqual(try percent("29"), 29)
        XCTAssertEqual(try percent("29.0"), 29)
        XCTAssertEqual(try percent("29.7"), 29)
        XCTAssertEqual(try percent("-29.7"), -29)
        XCTAssertNil(try percent("1e100"))
        XCTAssertNil(try percent("-1e100"))
    }
}
