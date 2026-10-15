import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Connection-page reads of the setup `get_info` snapshot. A decoded
/// handshake is not asked again; a failed one still is.
@MainActor
final class ConnectionHandshakeInfoTests: XCTestCase {
    func testRefreshBoardNameSendsNoGetInfoWhenHandshakeTagIsPresent() async throws {
        let transport = InfoTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        XCTAssertEqual(connection.handshakeDeviceInfo?.generation, connection.connectionGeneration)
        let sentDuringHandshake = transport.getInfoCount
        XCTAssertEqual(sentDuringHandshake, 1)

        let model = ConnectionViewModel(startBonjourBrowsing: false)
        await model.refreshBoardName(connection: connection)

        XCTAssertEqual(transport.getInfoCount, sentDuringHandshake,
                       "a decoded setup get_info must not be sent again")
        XCTAssertEqual(model.boardNameInput, "Rina")
        XCTAssertEqual(model.boardDefaultName, "RinaBoard-AABBCCDDEEFF")
        XCTAssertTrue(model.boardHasCustomName)

        let key = ConnectionViewModel.BoardDetailsKey(
            connection: ObjectIdentifier(connection), generation: connection.connectionGeneration
        )
        await model.loadBoardDetails(for: key, connection: connection)
        XCTAssertEqual(transport.getInfoCount, sentDuringHandshake,
                       "the first loadBoardDetails for this generation must use the handshake tag")
        XCTAssertEqual(model.boardFirmware, "1.2.3")
        XCTAssertEqual(model.boardBuild, "2026-10-15")
        connection.disconnect()
    }

    func testRefreshBoardNameSendsOneGetInfoWhenSetupGetInfoFailed() async throws {
        let transport = InfoTransport()
        transport.failSetupGetInfo = true
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        XCTAssertNil(connection.handshakeDeviceInfo)
        let sentDuringHandshake = transport.getInfoCount
        XCTAssertEqual(sentDuringHandshake, 1)

        let model = ConnectionViewModel(startBonjourBrowsing: false)
        await model.refreshBoardName(connection: connection)

        XCTAssertEqual(transport.getInfoCount, sentDuringHandshake + 1,
                       "a failed setup get_info must still be sent from the connection page")
        XCTAssertEqual(model.boardNameInput, "Rina")
        XCTAssertEqual(model.boardDefaultName, "RinaBoard-AABBCCDDEEFF")
        XCTAssertTrue(model.boardHasCustomName)
        connection.disconnect()
    }
}

/// Replies to the handshake and counts `get_info`. The first `get_info` can
/// be undecodable so the setup snapshot stays empty.
@MainActor
private final class InfoTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var failSetupGetInfo = false
    private(set) var getInfoCount = 0
    private var didFailSetupGetInfo = false

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            let payload = replyPayload(for: request)
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
            ))
        }
    }

    private func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            let object: [String: Any] = ["ok": true, "renderer": ["mode": "manual", "playback": "idle"]]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        case .getPreviewSync:
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "mode": "manual"])) ?? Data()
        case .getFrame:
            return PackedFrame().data
        case .cmd:
            guard let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
                  object["cmd"] as? String == RinaCommand.getInfo.name else {
                return Data(#"{"ok":true}"#.utf8)
            }
            getInfoCount += 1
            if failSetupGetInfo, !didFailSetupGetInfo {
                didFailSetupGetInfo = true
                return Data("not json".utf8)
            }
            let reply: [String: Any] = [
                "ok": true,
                "name": "Rina",
                "defaultName": "RinaBoard-AABBCCDDEEFF",
                "customName": true,
                "fw": "1.2.3",
                "build": "2026-10-15",
                "proto": 1
            ]
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
