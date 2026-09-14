import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class BoardFaceSaveIdentityTests: XCTestCase {
    func testSameBoardReconnectKeepsUpdateID() async throws {
        let oldGeneration = UUID()
        let newGeneration = UUID()
        let editor = ControlViewModel()
        editor.connectionChanged(generation: oldGeneration)
        editor.boardDidChange(to: "wifi:rina.local")
        editor.loadForEditing(editableFace())

        editor.connectionChanged(generation: newGeneration)
        editor.boardDidChange(to: "wifi:rina.local")

        let library = FaceLibraryModel()
        let payload = editor.upsertPayload(using: library)
        XCTAssertEqual(payload.id, "face-1")
        XCTAssertEqual(editor.boardFaceSaveSource,
                       BoardFaceSaveSource(boardID: "wifi:rina.local", generation: oldGeneration))

        let (connection, transport) = await connectedBoard(host: "rina.local")
        transport.resetRecordedFrames()
        let outcome = await library.save(payload, source: editor.boardFaceSaveSource,
                                         connection: connection)

        XCTAssertEqual(outcome, .saved(id: "face-1"))
        let command = try XCTUnwrap(transport.lastSent(type: .cmd))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: command.payload) as? [String: Any]
        )
        let face = try XCTUnwrap(object["face"] as? [String: Any])
        XCTAssertEqual(face["id"] as? String, "face-1",
                       "A reconnect to the same physical board must remain an update")
        connection.disconnect()
    }

    func testDifferentBoardRejectsStaleUpdateWithoutSending() async {
        let library = FaceLibraryModel()
        let payload = library.boardUpsertPayload(editingFaceId: "face-1", canOverwrite: true,
                                                 name: "Edited", frame: PackedFrame(),
                                                 fromParts: false, call: .defaultCall)
        let source = BoardFaceSaveSource(boardID: "wifi:board-a.local", generation: UUID())
        let (connection, transport) = await connectedBoard(host: "board-b.local")
        transport.resetRecordedFrames()

        let outcome = await library.save(payload, source: source, connection: connection)

        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(transport.sentCount(type: .cmd), 0,
                       "A stale id must not overwrite a coincidentally equal id on another board")
        connection.disconnect()
    }

    func testUnknownBoardIdentityCannotCrossConnectionGeneration() async {
        let library = FaceLibraryModel()
        let payload = library.boardUpsertPayload(editingFaceId: "face-1", canOverwrite: true,
                                                 name: "Edited", frame: PackedFrame(),
                                                 fromParts: false, call: .defaultCall)
        let (connection, transport) = await connectedBoard(kind: .bluetooth)
        XCTAssertNil(connection.boardKey)
        transport.resetRecordedFrames()

        let source = BoardFaceSaveSource(boardID: nil, generation: UUID())
        let outcome = await library.save(payload, source: source, connection: connection)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(transport.sentCount(type: .cmd), 0,
                       "Without a board identity, only the original link generation is safe")
        connection.disconnect()
    }

    func testSuccessfulCopyBecomesAnUpdateTargetOnItsDestinationBoard() {
        let generation = UUID()
        let editor = ControlViewModel()
        editor.connectionChanged(generation: generation)
        editor.boardDidChange(to: "wifi:rina.local")
        editor.loadForEditing(FaceEditRequest(id: 1, face: editableFace(),
                                              location: .local, asCopy: false,
                                              boardID: nil, boardGeneration: nil))
        let library = FaceLibraryModel()

        let copy = editor.upsertPayload(using: library)
        XCTAssertNil(copy.id, "A local face must be created as a board copy")

        let destination = BoardFaceSaveSource(boardID: "wifi:rina.local",
                                              generation: generation)
        editor.didSave(as: "board-copy-1", on: destination)
        let secondSave = editor.upsertPayload(using: library)

        XCTAssertEqual(secondSave.id, "board-copy-1")
        XCTAssertEqual(editor.editingLocation, .board)
        XCTAssertEqual(editor.boardFaceSaveSource, destination)
    }

    // MARK: Identity-reuse must never cross a shared `wifi:` address (fix for board-identity-flip)

    /// `BoardConnection` only ever remembers/reuses an identity for a `ble:`
    /// fallback key (a peripheral UUID is per physical device). A `wifi:`
    /// fallback key — e.g. a SoftAP's shared IP, or a DHCP address a
    /// different board picks up next — must never reuse a remembered
    /// identity: board A identified on `wifi:192.168.4.1`, then a later
    /// reconnect on the same address whose board legitimately answers
    /// without an id (not a read failure — a real "no id" reply, e.g. older
    /// or different firmware) must fall back to the plain transport key, not
    /// silently keep pointing at A.
    func testWifiFallbackKeyNeverReusesARememberedIdentityAcrossBoards() async throws {
        let connection = BoardConnection()
        let host = "192.168.4.1"

        let transport1 = FakeRinaTransport(kind: .wifi(host: host, port: RinaLinkConstants.tcpPort))
        let connected1 = await connectScripted(connection, transport1, wifiBoardId: "AABBCCDDEEFF")
        XCTAssertTrue(connected1)
        XCTAssertEqual(connection.boardKey, "board:AABBCCDDEEFF")

        // A different (or older) board answers on the same shared address,
        // legitimately without an id — not a read failure.
        let transport2 = FakeRinaTransport(kind: .wifi(host: host, port: RinaLinkConstants.tcpPort))
        transport2.commandReply = ["ok": true, "proto": 1]
        let connected2 = await connection.connect(using: transport2)
        XCTAssertTrue(connected2)
        XCTAssertNil(connection.boardIdentity)
        XCTAssertEqual(connection.boardKey, "wifi:\(host)",
                       "a wifi: fallback key must never reuse a remembered identity from a different connect")
    }

    // MARK: Real (wifi.boardId) BLE identity keeps a face save an update

    /// `get_status`'s `wifi.boardId` (not just `get_info`'s `defaultName`
    /// suffix) must drive `boardIdentity`, and the same physical board must
    /// resolve to the same `boardKey` whether reached over BLE or Wi-Fi.
    func testBLEBoardIdentityFromWifiBoardIdKeepsFaceUpdateAcrossReconnectAndTransport() async throws {
        let editor = ControlViewModel()
        editor.connectionChanged(generation: UUID())

        let connection1 = BoardConnection()
        let transport1 = FakeRinaTransport(kind: .bluetooth)
        transport1.commandReply = ["ok": true, "gen": 1]
        let connected1 = await connectScripted(connection1, transport1, wifiBoardId: "80B54EF48E09")
        XCTAssertTrue(connected1)
        let key = try XCTUnwrap(connection1.boardKey)
        XCTAssertEqual(key, "board:80B54EF48E09")

        editor.boardDidChange(to: key)
        editor.loadForEditing(editableFace())
        editor.connectionChanged(generation: connection1.connectionGeneration)
        editor.boardDidChange(to: key)

        let library = FaceLibraryModel()
        let payload1 = editor.upsertPayload(using: library)
        XCTAssertEqual(payload1.id, "face-1")
        transport1.resetRecordedFrames()
        let outcome1 = await library.save(payload1, source: editor.boardFaceSaveSource, connection: connection1)
        XCTAssertEqual(outcome1, .saved(id: "face-1"))
        let command1 = try XCTUnwrap(transport1.lastSent(type: .cmd))
        let face1 = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: command1.payload) as? [String: Any])?["face"] as? [String: Any]
        )
        XCTAssertEqual(face1["id"] as? String, "face-1")
        connection1.disconnect()

        // The same physical board, now reached over Wi-Fi.
        let connection2 = BoardConnection()
        let transport2 = FakeRinaTransport(kind: .wifi(host: "10.0.0.9", port: RinaLinkConstants.tcpPort))
        transport2.commandReply = ["ok": true, "gen": 1]
        let connected2 = await connectScripted(connection2, transport2, wifiBoardId: "80b54ef48e09")
        XCTAssertTrue(connected2)
        XCTAssertEqual(connection2.boardKey, key, "the same board must resolve to the same key over any transport")

        editor.connectionChanged(generation: connection2.connectionGeneration)
        editor.boardDidChange(to: key)
        let payload2 = editor.upsertPayload(using: library)
        XCTAssertEqual(payload2.id, "face-1")
        transport2.resetRecordedFrames()
        let outcome2 = await library.save(payload2, source: editor.boardFaceSaveSource, connection: connection2)
        XCTAssertEqual(outcome2, .saved(id: "face-1"))
        let command2 = try XCTUnwrap(transport2.lastSent(type: .cmd))
        let face2 = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: command2.payload) as? [String: Any])?["face"] as? [String: Any]
        )
        XCTAssertEqual(face2["id"] as? String, "face-1",
                       "the same board over Wi-Fi must still be treated as an update")
        connection2.disconnect()
    }

    /// Drives a `FakeRinaTransport` (with `automaticallyReplies = false`)
    /// through the exact request sequence `BoardConnection.establish()` sends
    /// during setup (`ping`, `cmd` subscribe, `get_status`, `get_frame`,
    /// `get_preview_sync`, `cmd` get_info), answering every step but letting
    /// `wifiBoardId == nil` skip both identity reads (`get_status`'s
    /// `wifi.boardId` and `get_info`'s `defaultName`) so they time out — the
    /// same shape as a flaky same-board reconnect. Restores
    /// `automaticallyReplies = true` before returning so later commands
    /// (e.g. a face save) get the fake's normal auto-reply behavior.
    private func connectScripted(
        _ connection: BoardConnection, _ transport: FakeRinaTransport, wifiBoardId: String?
    ) async -> Bool {
        transport.automaticallyReplies = false
        let script = Task { @MainActor in
            try? await transport.waitForSent(type: .ping, count: 1)
            transport.replyToNext(type: .ping, json: ["ok": true])
            try? await transport.waitForSent(type: .cmd, count: 1)
            transport.replyToNext(type: .cmd, json: ["ok": true])
            try? await transport.waitForSent(type: .getStatus, count: 1)
            if let wifiBoardId {
                let statusJSON: [String: Any] = [
                    "ok": true, "wifi": ["boardId": wifiBoardId],
                    "renderer": ["mode": "manual"], "power": [String: Any](),
                ]
                transport.replyToNext(type: .getStatus, json: statusJSON)
            }
            // wifiBoardId == nil: leave `get_status` unanswered too, so both
            // identity reads (`wifi.boardId` here, `get_info.defaultName`
            // below) time out — a flaky same-board reconnect, not just a
            // reply that happens to omit the field.
            try? await transport.waitForSent(type: .getFrame, count: 1)
            transport.replyToNext(type: .getFrame, payload: PackedFrame().data)
            try? await transport.waitForSent(type: .getPreviewSync, count: 1)
            transport.replyToNext(type: .getPreviewSync, json: ["ok": true, "mode": "manual"])
            try? await transport.waitForSent(type: .cmd, count: 2)
            if wifiBoardId != nil {
                transport.replyToNext(type: .cmd, json: ["ok": true, "proto": 1, "defaultName": "RinaBoard-000000000000"])
            }
            // wifiBoardId == nil: leave the second `.cmd` (get_info) unanswered
            // so its `defaultName` read times out too, simulating a flaky
            // reconnect where neither identity read completes.
        }
        let connected = await connection.connect(using: transport)
        await script.value
        transport.automaticallyReplies = true
        return connected
    }

    private func editableFace() -> SavedFace {
        SavedFace(id: "face-1", name: "Editable", type: .custom,
                  frameBytes: PackedFrame().bytes.map(Int.init), order: 1,
                  editable: true, deletable: true, locked: false)
    }

    private func connectedBoard(host: String) async -> (BoardConnection, FakeRinaTransport) {
        await connectedBoard(kind: .wifi(host: host, port: RinaLinkConstants.tcpPort))
    }

    private func connectedBoard(kind: TransportKind) async -> (BoardConnection, FakeRinaTransport) {
        let connection = BoardConnection()
        let transport = FakeRinaTransport(kind: kind)
        transport.commandReply = ["ok": true, "gen": 1]
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }
}
