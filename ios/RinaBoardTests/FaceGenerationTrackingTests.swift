import XCTest
import RinaCore
@testable import RinaBoard

/// `lastFaceOpGenMatchedExpectation` is what lets `FaceLibraryModel` apply an
/// optimistic in-place mutation instead of re-fetching the whole document. It
/// may only be true when the reply's generation is exactly one past a
/// generation this carrier actually observed; otherwise another client (the
/// WebUI) may have changed `saved_faces.json` underneath us.
@MainActor
final class FaceGenerationTrackingTests: XCTestCase {
    private func connectedBoard() async -> (BoardConnection, FakeRinaTransport) {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func genPrefix(_ gen: UInt32) -> Data {
        var bytes = Data(count: 4)
        bytes[0] = UInt8(gen & 0xFF)
        bytes[1] = UInt8((gen >> 8) & 0xFF)
        bytes[2] = UInt8((gen >> 16) & 0xFF)
        bytes[3] = UInt8((gen >> 24) & 0xFF)
        return bytes
    }

    /// Reads the library at `gen`, so the connection has an observed generation.
    private func readFaces(_ connection: BoardConnection, _ transport: FakeRinaTransport,
                           gen: UInt32) async throws {
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let task = Task { try await connection.getFaces() }
        try await transport.waitForSent(type: .getFaces, count: 1)
        transport.replyToNext(type: .getFaces,
                              payload: genPrefix(gen) + (try FaceDocument().encoded()))
        _ = try await task.value
        transport.automaticallyReplies = true
    }

    /// Runs one face op whose reply carries `gen`.
    private func renameReplying(gen: Int, _ connection: BoardConnection,
                                _ transport: FakeRinaTransport) async throws {
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let task = Task { try await connection.faceRename(id: "u1", name: "renamed") }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "gen": gen])
        _ = try await task.value
        transport.automaticallyReplies = true
    }

    func testReplyOneGenerationPastTheReadGenerationMatches() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)
        try await renameReplying(gen: 6, connection, transport)
        XCTAssertTrue(connection.lastFaceOpGenMatchedExpectation,
                      "gen 6 straight after reading gen 5 is our own mutation")
    }

    /// A concurrent WebUI edit shows up as a generation jump. This is the case
    /// that used to be invisible, because `getFaces()` never recorded a
    /// generation for the reply to be compared against.
    func testGenerationJumpFromAnotherClientDoesNotMatch() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)
        try await renameReplying(gen: 9, connection, transport)
        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
                       "someone else mutated the document; callers must reload")
    }

    func testFaceOpWithNoPriorReadDoesNotMatch() async throws {
        let (connection, transport) = await connectedBoard()
        try await renameReplying(gen: 3, connection, transport)
        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
                       "without an observed generation there is no basis to claim we are in sync")
    }

    /// Firmware that reports no `gen` at all cannot support this check, so the
    /// reply must not be taken as "still in sync" — the caller reloads instead.
    /// The previous behavior left the flag at whatever the last op had set,
    /// which silently reused a stale verdict.
    func testReplyWithoutAGenerationNeverCountsAsInSync() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)
        try await renameReplying(gen: 6, connection, transport)
        XCTAssertTrue(connection.lastFaceOpGenMatchedExpectation)

        // Same connection, next reply carries no `gen`.
        transport.resetRecordedFrames()
        transport.automaticallyReplies = false
        let task = Task { try await connection.faceRename(id: "u1", name: "again") }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true])
        _ = try await task.value
        transport.automaticallyReplies = true

        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
                       "a reply without a generation must not inherit the previous verdict")
    }

    /// A generation only means something inside the carrier that reported it.
    func testGenerationIsForgottenWhenTheCarrierStops() async throws {
        let (connection, transport) = await connectedBoard()
        try await readFaces(connection, transport, gen: 5)

        connection.disconnect()
        let transport2 = FakeRinaTransport()
        let reconnected = await connection.connect(using: transport2)
        XCTAssertTrue(reconnected)

        // Even the arithmetically "correct" next generation must not be trusted:
        // the board may have been edited by another client while we were away.
        try await renameReplying(gen: 6, connection, transport2)
        XCTAssertFalse(connection.lastFaceOpGenMatchedExpectation,
                       "the pre-disconnect generation must not survive the carrier")
    }
}
