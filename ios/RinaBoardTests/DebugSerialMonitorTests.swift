import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class DebugSerialMonitorTests: XCTestCase {
    func testParsesNamesJSONAndQueryMessageTypes() throws {
        let named = try DebugMonitorRequest.parse("  get_info\n")
        XCTAssertEqual(named.type, .cmd)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: named.payload) as? [String: String])
        XCTAssertEqual(object["cmd"], "get_info")
        XCTAssertEqual(try DebugMonitorRequest.parse("GET_STATUS").type, .getStatus)
        XCTAssertEqual(try DebugMonitorRequest.parse("GET_POWER").type, .getPower)
        XCTAssertEqual(try DebugMonitorRequest.parse("ping").type, .ping)
        let json = #"{"cmd":"set_brightness","raw":32}"#
        XCTAssertEqual(try DebugMonitorRequest.parse(json).payload, Data(json.utf8))
        for invalid in ["", "[]", "{}", "{bad}", #"{"cmd":3}"#, "set_brightness 32"] {
            XCTAssertThrowsError(try DebugMonitorRequest.parse(invalid), invalid)
        }
    }

    func testEveryCatalogExampleHasMatchingCommand() throws {
        XCTAssertFalse(DebugCommandCatalog.commands.isEmpty)
        XCTAssertEqual(Set(DebugCommandCatalog.commands.map(\.name)).count, DebugCommandCatalog.commands.count)
        for command in DebugCommandCatalog.commands {
            let request = try DebugMonitorRequest.parse(command.example)
            // PING / GET_STATUS / GET_POWER are frames of their own, not CMDs.
            guard request.commandName != nil else {
                XCTAssertNotEqual(request.type, .cmd, command.name)
                continue
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
            XCTAssertEqual(request.type, .cmd)
            XCTAssertEqual(object["cmd"] as? String, command.name)
        }
    }

    func testSendShowsReplyAndRedactsSecrets() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        let vm = DebugViewModel()
        vm.monitorInput = #"{"cmd":"wifi_connect","password":"secret-value"}"#
        await vm.sendMonitorCommand(connection: connection)
        XCTAssertEqual(vm.commandAttempts, 1)
        XCTAssertEqual(vm.monitorEntries.count, 2)
        XCTAssertTrue(vm.monitorEntries[0].message.hasPrefix("TX"))
        XCTAssertFalse(vm.monitorEntries[0].message.contains("secret-value"))
        XCTAssertTrue(vm.monitorEntries[1].message.contains("true"))
        XCTAssertFalse(vm.isMonitorSending)
    }

    func testRejectedReplyAndInvalidInput() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.commandReply = ["ok": false, "error": "unsupported"]
        let vm = DebugViewModel()
        await vm.sendMonitorCommand(connection: connection)
        XCTAssertEqual(vm.commandRejected, 1)
        XCTAssertEqual(vm.monitorEntries.last?.level, .warn)
        XCTAssertTrue(vm.monitorEntries.last?.message.contains("unsupported") == true)
        vm.monitorInput = "{}"
        await vm.sendMonitorCommand(connection: connection)
        XCTAssertEqual(vm.commandAttempts, 1)
        XCTAssertEqual(vm.monitorEntries.last?.level, .error)
    }

    func testDisconnectedDoesNotSendAndFirmwareLogAppearsInMonitor() async {
        let vm = DebugViewModel()
        await vm.sendMonitorCommand(connection: BoardConnection())
        XCTAssertEqual(vm.commandAttempts, 0)
        vm.log(.info, "board ready", source: .firmware)
        XCTAssertEqual(vm.monitorEntries.last?.message, "EV_LOG · board ready")
    }
}
