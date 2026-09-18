import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Apple Pencil hover on the face editor: the board mirrors the hovered LED at
/// half brightness (`set_hint_led`) only while 即时预览 is on, and loses it
/// the moment the pencil stops hovering.
@MainActor
final class ControlPencilHoverTests: XCTestCase {
    private func connectedBoard() async -> (BoardConnection, FakeRinaTransport) {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    /// Polls until `condition` holds, against a wall-clock deadline: waiting on
    /// the condition itself, not on a scheduler yield, keeps these stable on a
    /// loaded machine.
    private func waitFor(_ message: String = "Condition never became true",
                         timeout: TimeInterval = 3,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// The `led` of every `set_hint_led` the board received, in order.
    private func hints(_ transport: FakeRinaTransport) -> [Int] {
        transport.sentFrames(type: .cmd).compactMap { frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                  object["cmd"] as? String == "set_hint_led" else { return nil }
            return object["led"] as? Int
        }
    }

    func testHoverLightsTheBoardLEDAndLeavingClearsIt() async {
        let (connection, transport) = await connectedBoard()
        let model = ControlViewModel()
        model.livePreview = true

        model.pencilHover(led: 57, connection: connection)
        await waitFor("hover must reach the board") { hints(transport) == [57] }

        model.pencilHover(led: nil, connection: connection)
        await waitFor("leaving must clear the board") { hints(transport) == [57, -1] }
        connection.disconnect()
    }

    func testSameLEDIsSentOnce() async {
        let (connection, transport) = await connectedBoard()
        let model = ControlViewModel()
        model.livePreview = true

        model.pencilHover(led: 3, connection: connection)
        await waitFor { hints(transport) == [3] }
        model.pencilHover(led: 3, connection: connection)
        model.pencilHover(led: nil, connection: connection)
        await waitFor { hints(transport) == [3, -1] }
        connection.disconnect()
    }

    func testWithoutLivePreviewTheBoardIsLeftAlone() async {
        let (connection, transport) = await connectedBoard()
        let model = ControlViewModel()
        model.livePreview = false

        model.pencilHover(led: 57, connection: connection)
        model.pencilHover(led: 58, connection: connection)
        model.pencilHover(led: nil, connection: connection)
        // Negative assertion: give any stray send a moment to land.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hints(transport), [])
        connection.disconnect()
    }

    func testTurningLivePreviewOffMidHoverClearsTheBoard() async {
        let (connection, transport) = await connectedBoard()
        let model = ControlViewModel()
        model.livePreview = true

        model.pencilHover(led: 10, connection: connection)
        await waitFor { hints(transport) == [10] }
        model.livePreview = false
        model.syncBoardHint(connection: connection)
        await waitFor("switching 即时预览 off must clear the hint") { hints(transport) == [10, -1] }
        connection.disconnect()
    }

    func testFirmwareWithoutHintLEDIsNotAskedAgain() async throws {
        let (connection, transport) = await connectedBoard()
        transport.automaticallyReplies = false
        let model = ControlViewModel()
        model.livePreview = true

        model.pencilHover(led: 1, connection: connection)
        await waitFor { hints(transport) == [1] }
        // What pre-hint firmware answers: an ERR frame, not an `ok:false` reply.
        let request = try XCTUnwrap(transport.sentFrames(type: .cmd).last)
        transport.emitReply(type: .error, seq: request.seq, payload: Data(
            #"{"ok":false,"error":"unknown command: set_hint_led","code":400}"#.utf8))
        try? await Task.sleep(for: .milliseconds(100))

        model.pencilHover(led: 2, connection: connection)
        model.pencilHover(led: nil, connection: connection)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hints(transport), [1])
        XCTAssertNil(model.errorMessage, "an unsupported hover is never worth an alert")
        connection.disconnect()
    }

    /// A send that fails for any reason other than "unknown command" leaves
    /// the board's state unknown: leaving must send the clear anyway rather
    /// than assume nothing is lit. (A failed transport write is not this case —
    /// it drops the whole link, and the board clears the hint on disconnect.)
    func testUnconfirmedSendStillClearsWhenThePencilLeaves() async throws {
        let (connection, transport) = await connectedBoard()
        transport.automaticallyReplies = false
        let model = ControlViewModel()
        model.livePreview = true

        model.pencilHover(led: 57, connection: connection)
        await waitFor { hints(transport) == [57] }
        let request = try XCTUnwrap(transport.sentFrames(type: .cmd).last)
        transport.emitReply(type: .error, seq: request.seq, payload: Data(
            #"{"ok":false,"error":"busy","code":503}"#.utf8))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(connection.connectionState, .connected)

        model.pencilHover(led: nil, connection: connection)
        await waitFor("the clear must go out after an unconfirmed send") { hints(transport) == [57, -1] }
        connection.disconnect()
    }

    /// Switching boards while the pencil is held still over the editor puts
    /// the old board's hint out and shows it on the new one.
    func testSwitchingBoardsMovesTheHint() async {
        let (boardA, transportA) = await connectedBoard()
        let (boardB, transportB) = await connectedBoard()
        let model = ControlViewModel()
        model.livePreview = true

        model.pencilHover(led: 57, connection: boardA)
        await waitFor { hints(transportA) == [57] }

        model.syncBoardHint(connection: boardB)
        await waitFor("the old board must be cleared") { hints(transportA) == [57, -1] }
        await waitFor("the new board must show the hover") { hints(transportB) == [57] }
        boardA.disconnect()
        boardB.disconnect()
    }
}
