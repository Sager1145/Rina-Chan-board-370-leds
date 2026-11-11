import XCTest
@testable import RinaBoard
@testable import RinaCore

/// Watch-link fixes: a command naming a target the phone has stopped
/// offering, the reply for a directly-driven board, and where lip sync closes
/// the mouth when the watch started it on a board that is not the phone's.
/// As in `WatchLinkTests`, no `WCSession` is involved.
@MainActor
final class Fix44WatchTests: XCTestCase {
    // MARK: Envelope

    func testEnvelopeCarriesAnOptionalTargetBesideThePayload() throws {
        let data = try WatchLinkCodec.encode(WatchCommand.setBrightness(raw: 60))
        let tagged = WatchLinkCodec.envelope(data, targetID: "board:x")
        XCTAssertEqual(WatchLinkCodec.targetID(in: tagged), "board:x")
        XCTAssertEqual(WatchLinkCodec.payload(in: tagged), data, "the payload is read exactly as before")
        XCTAssertNil(WatchLinkCodec.targetID(in: WatchLinkCodec.envelope(data)),
                     "a build that does not send a target stays valid")
    }

    // MARK: Vanished target

    func testCommandNamingADroppedTargetNeverLandsOnThePhonesBoard() async throws {
        let h = await harness()
        defer { h.a.connection.disconnect() }
        await h.service.handle(.selectTarget(id: h.bID))
        h.b.connection.disconnect()
        await waitUntilTrue("B never dropped") { h.b.connection.connectionState != .connected }

        // Production order: the observation re-reads the snapshot (and so
        // resets the selection) before any watch command arrives.
        XCTAssertEqual(h.service.snapshot().selectedTargetID, WatchTargetChoice.phoneID)
        let before = h.controlCenter.draftBrightness
        XCTAssertNotEqual(before, 33)

        await h.service.handle(.setBrightness(raw: 33), shownTargetID: h.bID)
        XCTAssertEqual(h.controlCenter.draftBrightness, before,
                       "the watch was still showing B: the phone's board was never chosen")
        XCTAssertTrue(commands(h.wireA, "set_brightness").isEmpty)

        // Once the watch shows the phone as its target, commands flow again.
        await h.service.handle(.setBrightness(raw: 33), shownTargetID: WatchTargetChoice.phoneID)
        XCTAssertEqual(h.controlCenter.draftBrightness, 33)
    }

    // MARK: Direct board reply

    func testDirectBoardSnapshotShowsWhatTheCommandJustSet() async throws {
        let h = await harness()
        defer { h.a.connection.disconnect(); h.b.connection.disconnect() }
        await h.service.handle(.selectTarget(id: h.bID))
        // The fake board never reports a renderer, so its status stays as
        // stale as a real board's is between a reply and the status event.
        XCTAssertFalse(h.service.snapshot().controls.isAutoMode)

        await h.service.handle(.setAutoMode(enabled: true))
        XCTAssertEqual(commands(h.wireB, "set_mode").map { $0["mode"] as? String }, ["auto"])
        XCTAssertTrue(h.service.snapshot().controls.isAutoMode,
                      "the reply must confirm the toggle, not revert it")

        await h.service.handle(.setColor(hex: "#abcdef"))
        XCTAssertEqual(h.service.snapshot().controls.colorHex.lowercased(), "#abcdef")

        await h.service.handle(.setAutoMode(enabled: false))
        XCTAssertEqual(commands(h.wireB, "set_mode").map { $0["mode"] as? String }, ["auto", "manual"],
                       "the opposite toggle must not be skipped against the stale status")
        XCTAssertFalse(h.service.snapshot().controls.isAutoMode)
        XCTAssertTrue(commands(h.wireA, "set_mode").isEmpty)
    }

    // MARK: Lip sync on a board that is not the phone's

    func testLipSyncClosesTheMouthOnTheBoardItWasStartedOn() async throws {
        let h = await harness()
        defer { h.lipSync.stop(); h.a.connection.disconnect(); h.b.connection.disconnect() }
        await h.service.handle(.selectTarget(id: h.bID))
        await h.service.handle(.lipSyncStart)
        XCTAssertTrue(h.lipSync.isRunning)
        try await h.wireB.waitForSent(type: .setFrame, count: 1)
        let sentToB = h.wireB.sentCount(type: .setFrame)

        // The phone leaves the foreground holding its own active board.
        h.lipSync.scenePhaseChanged(.background, connection: h.a.connection)
        XCTAssertFalse(h.lipSync.isRunning)
        try await h.wireB.waitForSent(type: .setFrame, count: sentToB + 1)
        XCTAssertEqual(h.wireA.sentCount(type: .setFrame), 0)

        // Lip sync restarted from the phone on its own board; the watch,
        // still pointing at B, stops it.
        await h.lipSync.start(connection: h.a.connection)
        XCTAssertTrue(h.lipSync.isRunning)
        try await h.wireA.waitForSent(type: .setFrame, count: 1)
        let sentToA = h.wireA.sentCount(type: .setFrame)
        await h.service.handle(.lipSyncStop, shownTargetID: h.bID)
        XCTAssertFalse(h.lipSync.isRunning)
        try await h.wireA.waitForSent(type: .setFrame, count: sentToA + 1)
        XCTAssertEqual(h.wireB.sentCount(type: .setFrame), sentToB + 1)
    }

    // MARK: Harness

    @MainActor private struct Harness {
        let controlCenter: BoardControlCenterModel
        let lipSync: LipSyncModel
        let service: WatchLinkService
        /// The phone's active board.
        let a: BoardSession
        let b: BoardSession
        let wireA: FakeRinaTransport
        let wireB: FakeRinaTransport

        var bID: String { "board:\(b.id.uuidString)" }
    }

    private func harness() async -> Harness {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: makeIsolatedDefaults())
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)
        let controlCenter = BoardControlCenterModel()
        controlCenter.loadDefaultsIfNeeded()
        let cycler = GroupAutoCycler(fanOut: fanOut, faceLibrary: FaceLibraryModel(), intervalProvider: { 3 })
        let lipSync = LipSyncModel(defaults: makeIsolatedDefaults(), capture: SilentMicrophone(),
                                   permissionRequest: { .granted })
        let a = sessions.session(for: "ble:\(UUID().uuidString)", name: "A")
        let b = sessions.session(for: "ble:\(UUID().uuidString)", name: "B")
        let wireA = FakeRinaTransport(), wireB = FakeRinaTransport()
        let connectedA = await a.connection.connect(using: wireA)
        let connectedB = await b.connection.connect(using: wireB)
        XCTAssertTrue(connectedA && connectedB)
        sessions.select(a)
        let service = WatchLinkService(deps: .init(
            sessions: sessions, controlCenter: controlCenter, lipSync: lipSync, text: TextViewModel(),
            groupStore: store, fanOut: fanOut, groupAutoCycler: cycler, groupCoordinator: coordinator,
            controlTargetStorage: { "" }
        ))
        return Harness(controlCenter: controlCenter, lipSync: lipSync, service: service,
                       a: a, b: b, wireA: wireA, wireB: wireB)
    }

    /// The CMD requests named `name` that reached the board, oldest first.
    private func commands(_ wire: FakeRinaTransport, _ name: String) -> [[String: Any]] {
        wire.sentFrames(type: .cmd).compactMap { frame -> [String: Any]? in
            guard let object = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any],
                  object["cmd"] as? String == name else { return nil }
            return object
        }
    }
}

/// Runs the real `LipSyncModel` lifecycle without microphone hardware.
/// Silence classifies as a closed mouth, which is sent once.
private final class SilentMicrophone: LipSyncCapturing {
    private(set) var isRunning = false
    var currentSampleRate: Double { 16_000 }
    @MainActor func start() async throws { isRunning = true }
    func stop() { isRunning = false }
    func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double) {
        (Array(repeating: 0, count: count), currentSampleRate)
    }
}
