import XCTest
@testable import RinaBoard

final class DebugCommandCatalogTests: XCTestCase {
    func testNamesAreUniqueAndEveryGroupIsUsed() {
        let names = DebugCommandCatalog.commands.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
        for group in DebugCommandGroup.allCases {
            XCTAssertTrue(DebugCommandCatalog.commands.contains { $0.group == group }, "\(group) is empty")
        }
    }

    func testDestructiveCommands() {
        XCTAssertTrue(DebugCommandCatalog.isDestructive(commandName: "reboot"))
        XCTAssertTrue(DebugCommandCatalog.isDestructive(commandName: "faces_clear_user"))
        XCTAssertFalse(DebugCommandCatalog.isDestructive(commandName: "set_color"))
        XCTAssertFalse(DebugCommandCatalog.isDestructive(commandName: "PING"))
        for template in DebugCommandCatalog.commands {
            XCTAssertEqual(template.isDestructive, DebugCommandCatalog.isDestructive(commandName: template.name))
        }
    }

    func testMonitorRequestNamesItsCommand() throws {
        XCTAssertEqual(try DebugMonitorRequest.parse("reboot").commandName, "reboot")
        XCTAssertEqual(try DebugMonitorRequest.parse(#"{"cmd":"reboot"}"#).commandName, "reboot")
        XCTAssertTrue(try DebugMonitorRequest.parse(#"{"cmd":"reboot"}"#).isDestructive)
        XCTAssertNil(try DebugMonitorRequest.parse("PING").commandName)
        XCTAssertFalse(try DebugMonitorRequest.parse("PING").isDestructive)
    }
}
