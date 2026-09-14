import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class ExplicitModeCommandTests: XCTestCase {
    func testModeTapsSendDesiredStateEvenWhenPriorCommandWasNotApplied() async throws {
        let wire = ModeCommandTransport()
        let board = BoardConnection()
        let connected = await board.connect(using: wire)
        XCTAssertTrue(connected)
        defer { board.disconnect() }
        let model = BoardControlCenterModel()
        // The fake acknowledges but deliberately does not apply commands, simulating
        // a lost effect. The second tap must still request the user's desired state.
        await model.toggleAutoMode(connection: board)
        await model.toggleAutoMode(connection: board)
        let modeCommands = wire.commands.filter { $0["cmd"] as? String == "set_mode" }
        XCTAssertEqual(modeCommands.compactMap { $0["mode"] as? String }, ["auto", "manual"])
        XCTAssertFalse(wire.commands.contains { $0["button"] as? String == "B3" })
    }

    func testProtocolVersionComesFromInfoAndIsClearedOnDisconnect() async {
        let wire = ModeCommandTransport()
        let board = BoardConnection()
        let connected = await board.connect(using: wire)
        XCTAssertTrue(connected)
        XCTAssertEqual(board.protocolVersion, 1)
        XCTAssertEqual(board.status?.version, 944)
        board.disconnect()
        XCTAssertNil(board.protocolVersion)
    }
}

@MainActor
private final class ModeCommandTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var commands: [[String: Any]] = []
    private let decoder = RinaLinkDecoder()
    private var incoming: AsyncStream<Data>.Continuation?
    private var states: AsyncStream<TransportState>.Continuation?
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { states = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incoming = $0 } }
    func connect() async throws { states?.yield(.connected) }
    func disconnect() { states?.yield(.disconnected) }
    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            var json: [String: Any] = ["ok": true]
            if request.type == RinaLinkMessageType.cmd.rawValue {
                let command = try JSONSerialization.jsonObject(with: request.payload) as! [String: Any]
                commands.append(command)
                if command["cmd"] as? String == "get_info" {
                    json["proto"] = 1
                    json["name"] = "Test Board"
                }
            } else if request.type == RinaLinkMessageType.getStatus.rawValue {
                json["version"] = 944
                json["renderer"] = ["mode": "manual"]
            }
            let payload = request.type == RinaLinkMessageType.getFrame.rawValue
                ? PackedFrame().data : try JSONSerialization.data(withJSONObject: json)
            incoming?.yield(try RinaLinkEncoder.encode(RinaLinkFrame(
                type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)))
        }
    }
}
