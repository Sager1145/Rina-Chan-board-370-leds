import XCTest
@testable import RinaBoard
@testable import RinaCore

/// The phone end of the Apple Watch companion (`WatchLinkService`) and the
/// wire format it shares with the watch. No `WCSession` is involved: the
/// service is driven through `handle(_:)`/`snapshot()` exactly as the
/// WatchConnectivity relay drives it.
@MainActor
final class WatchLinkTests: XCTestCase {
    // MARK: Codec

    func testCommandsRoundTripThroughTheEnvelope() throws {
        let commands: [WatchCommand] = [
            .requestState, .selectTarget(id: "board:x"), .setBrightness(raw: 120), .stepFace(direction: -1),
            .setAutoMode(enabled: true), .setAutoInterval(seconds: 2.5), .setColor(hex: "#112233"),
            .setScrollFps(fps: 24), .lipSyncStart, .lipSyncStop, .setLipSyncSensitivity(db: -35),
        ]
        for command in commands {
            let envelope = WatchLinkCodec.envelope(try WatchLinkCodec.encode(command))
            let payload = try XCTUnwrap(WatchLinkCodec.payload(in: envelope))
            XCTAssertEqual(try WatchLinkCodec.decode(WatchCommand.self, from: payload), command)
        }
        XCTAssertNil(WatchLinkCodec.payload(in: ["v": 99, "rinaWatchLink": Data()]),
                     "a newer envelope version must be ignored, not misread")
        XCTAssertNil(WatchLinkCodec.payload(in: [:]))
    }

    func testSnapshotRoundTrips() async throws {
        let h = await harness(["A", "B"])
        let snapshot = h.service.snapshot()
        let data = try WatchLinkCodec.encode(snapshot)
        XCTAssertEqual(try WatchLinkCodec.decode(WatchBoardSnapshot.self, from: data), snapshot)
    }

    // MARK: Snapshot

    func testSnapshotFollowsThePhoneByDefault() async throws {
        let h = await harness(["A", "B"])
        let snapshot = h.service.snapshot()
        XCTAssertEqual(snapshot.selectedTargetID, WatchTargetChoice.phoneID)
        XCTAssertEqual(snapshot.board.name, "A", "the phone's active board (the first connected)")
        XCTAssertTrue(snapshot.board.isConnected)
        XCTAssertEqual(snapshot.controls.brightnessRaw, 120)
        XCTAssertEqual(snapshot.controls.colorHex, "#112233")
        XCTAssertTrue(snapshot.controls.isAutoMode)
        XCTAssertFalse(snapshot.controls.isScrollActive)
        XCTAssertEqual(snapshot.controls.scrollFpsMax, RinaLinkConstants.scrollFpsMax)
        XCTAssertEqual(snapshot.targets.map(\.kind), [.phone, .board, .board, .group])
        XCTAssertEqual(snapshot.targets.map(\.name), ["A", "A", "B", "测试组"])
        XCTAssertEqual(snapshot.targets[3].connectedCount, 2)
        XCTAssertFalse(snapshot.controls.presets.isEmpty, "the phone's colour presets reach the watch")
        XCTAssertTrue(snapshot.lipSync.isAvailable)
        XCTAssertEqual(snapshot.lipSync.sensitivityMinDb, -70)
    }

    // MARK: Targeting

    func testSelectingAnotherBoardDrivesItWithoutChangingThePhonesSelection() async throws {
        let h = await harness(["A", "B"])
        let activeBefore = h.sessions.active
        let b = h.session("B")

        await h.service.handle(.selectTarget(id: "board:\(b.id.uuidString)"))
        await h.service.handle(.setBrightness(raw: 77))
        await h.service.handle(.setColor(hex: "#abcdef"))
        await h.service.handle(.setAutoInterval(seconds: 1.5))

        XCTAssertTrue(h.sessions.active === activeBefore, "the watch's choice must not move the phone's active session")
        XCTAssertEqual(h.transports["B"]!.lastCmdField("set_brightness", "raw") as? Int, 77)
        XCTAssertEqual(h.transports["B"]!.lastCmdField("set_color", "hex") as? String, "#abcdef")
        XCTAssertEqual(h.transports["B"]!.lastCmdField("set_auto_interval", "ms") as? Int, 1500)
        XCTAssertFalse(h.transports["A"]!.receivedCmdNames.contains("set_brightness"),
                       "the phone's own board must not receive the watch's command")
        XCTAssertEqual(h.controlCenter.draftBrightness, 120,
                       "the phone's Control Center draft belongs to the phone's board and stays put")
        XCTAssertEqual(h.service.snapshot().board.name, "B")
    }

    func testFollowingThePhoneGoesThroughTheControlCenterModel() async throws {
        let h = await harness(["A", "B"])
        await h.service.handle(.setBrightness(raw: 60))
        XCTAssertEqual(h.controlCenter.draftBrightness, 60, "same path as the phone's slider")
        await waitUntil { h.transports["A"]!.lastCmdField("set_brightness", "raw") as? Int == 60 }
        XCTAssertEqual(h.transports["A"]!.lastCmdField("set_brightness", "raw") as? Int, 60)
    }

    func testUnknownTargetFallsBackToThePhone() async throws {
        let h = await harness(["A"])
        await h.service.handle(.selectTarget(id: "board:\(UUID().uuidString)"))
        XCTAssertEqual(h.service.snapshot().selectedTargetID, WatchTargetChoice.phoneID)
    }

    func testGroupTargetFansOutToEveryConnectedMember() async throws {
        let h = await harness(["A", "B"])
        await h.service.handle(.selectTarget(id: "group:\(h.group.id.uuidString)"))
        await h.service.handle(.setBrightness(raw: 90))
        XCTAssertEqual(h.transports["A"]!.lastCmdField("set_brightness", "raw") as? Int, 90)
        XCTAssertEqual(h.transports["B"]!.lastCmdField("set_brightness", "raw") as? Int, 90)
        let snapshot = h.service.snapshot()
        XCTAssertEqual(snapshot.board.memberCount, 2)
        XCTAssertEqual(snapshot.board.connectedCount, 2)
        XCTAssertFalse(snapshot.lipSync.isAvailable, "no single board for the phone's microphone to drive")
    }

    func testUnsyncedGroupRefusesFaceStepAndAutoOnButAllowsAutoOff() async throws {
        let h = await harness(["A", "B"])
        await h.service.handle(.selectTarget(id: "group:\(h.group.id.uuidString)"))

        await h.service.handle(.stepFace(direction: 1))
        XCTAssertEqual(h.service.snapshot().errorMessage, String(localized: "多板组未同步时无法从手表切换表情"))
        XCTAssertFalse(h.transports.values.contains { $0.receivedCmdNames.contains("button") })

        await h.service.handle(.setAutoMode(enabled: true))
        XCTAssertEqual(h.service.snapshot().errorMessage, String(localized: "多板组未同步时无法从手表开启自动播放"))
        XCTAssertFalse(h.transports.values.contains { $0.receivedCmdNames.contains("set_mode") })

        await h.service.handle(.setAutoMode(enabled: false))
        XCTAssertTrue(h.transports.values.allSatisfy {
            $0.lastCmdField("set_mode", "mode") as? String == "manual"
        })
    }

    // MARK: Interrupting vs. retuning actions

    func testStepFaceTakesOverTheOutputAndStopsARunningScroll() async throws {
        let h = await harness(["A", "B"])
        let b = h.session("B")
        h.transports["B"]!.rendererScrollActive = true
        _ = try? await b.connection.getStatus()
        await h.service.handle(.selectTarget(id: "board:\(b.id.uuidString)"))
        let stale = b.connection.output.begin(.text)

        await h.service.handle(.stepFace(direction: 1))

        XCTAssertFalse(b.connection.output.isCurrent(stale), "prev/next interrupts whatever was playing")
        XCTAssertEqual(b.connection.output.source, .manual)
        XCTAssertTrue(h.transports["B"]!.receivedCmdNames.contains("stop_scroll"))
        XCTAssertEqual(h.transports["B"]!.lastCmdField("button", "button") as? String, "B1")
    }

    func testScrollSpeedOnlyRetunesARunningScrollAndNeverClaimsOutput() async throws {
        let h = await harness(["A", "B"])
        let b = h.session("B")
        await h.service.handle(.selectTarget(id: "board:\(b.id.uuidString)"))

        await h.service.handle(.setScrollFps(fps: 24))
        XCTAssertFalse(h.transports["B"]!.receivedCmdNames.contains("set_scroll_interval"),
                       "greyed out on the watch, and a no-op on the phone, while nothing scrolls")

        h.transports["B"]!.rendererScrollActive = true
        _ = try? await b.connection.getStatus()
        XCTAssertTrue(h.service.snapshot().controls.isScrollActive)
        let owner = b.connection.output.begin(.text)
        await h.service.handle(.setScrollFps(fps: 24))
        XCTAssertEqual(h.transports["B"]!.lastCmdField("set_scroll_interval", "fps") as? Int, 24)
        XCTAssertTrue(b.connection.output.isCurrent(owner), "retuning never pauses the feature driving the scroll")
    }

    func testAutoModeIsIdempotentPerBoard() async throws {
        let h = await harness(["A", "B"])
        let b = h.session("B")
        await h.service.handle(.selectTarget(id: "board:\(b.id.uuidString)"))
        await h.service.handle(.setAutoMode(enabled: true))
        XCTAssertFalse(h.transports["B"]!.receivedCmdNames.contains("set_mode"), "already auto")
        await h.service.handle(.setAutoMode(enabled: false))
        XCTAssertEqual(h.transports["B"]!.lastCmdField("set_mode", "mode") as? String, "manual")
    }

    func testIdleLipSyncSensitivityIsClamped() async throws {
        let h = await harness(["A"])
        await h.service.handle(.setLipSyncSensitivity(db: -200))
        XCTAssertEqual(h.lipSync.sensitivityDb, -70)
        await h.service.handle(.setLipSyncSensitivity(db: 5))
        XCTAssertEqual(h.lipSync.sensitivityDb, -10)
    }

    func testRunningLipSyncRejectsWatchSensitivityChanges() async throws {
        let h = await harness(["A"])
        h.lipSync.sensitivityDb = -42
        await h.lipSync.start(connection: h.sessions.active.connection)
        defer { h.lipSync.stop(); h.sessions.active.connection.disconnect() }
        XCTAssertTrue(h.lipSync.isRunning, "The lock must be tested against real recognition startup")
        XCTAssertFalse(h.lipSync.canEditOptions)
        await h.service.handle(.setLipSyncSensitivity(db: -20))
        XCTAssertEqual(h.lipSync.sensitivityDb, -42)
        h.lipSync.stop()
        await h.service.handle(.setLipSyncSensitivity(db: -20))
        XCTAssertEqual(h.lipSync.sensitivityDb, -20, "Edits become available after recognition stops")
    }

    func testDisconnectedTargetIgnoresCommands() async throws {
        let h = await harness(["A", "B"])
        let b = h.session("B")
        await h.service.handle(.selectTarget(id: "board:\(b.id.uuidString)"))
        b.connection.disconnect()
        await waitUntil { b.connection.connectionState != .connected }
        await h.service.handle(.setBrightness(raw: 33))
        XCTAssertFalse(h.transports["B"]!.receivedCmdNames.contains("set_brightness"))
        // A board that dropped is no longer offered; the watch falls back —
        // but a command aimed at the vanished board must not land on the
        // phone's own board, which the user never chose.
        XCTAssertEqual(h.service.snapshot().selectedTargetID, WatchTargetChoice.phoneID)
        XCTAssertFalse(h.transports["A"]!.receivedCmdNames.contains("set_brightness"))
        XCTAssertEqual(h.controlCenter.draftBrightness, 120)
        // Once the watch is knowingly following the phone, commands flow again.
        await h.service.handle(.setBrightness(raw: 33))
        XCTAssertEqual(h.controlCenter.draftBrightness, 33)
    }

    func testFollowingThePhoneInASyncedGroupUsesTheCyclerAndPrimary() async throws {
        let h = await harness(["A", "B"], phoneTargetsGroup: true)
        await waitUntil { h.service.snapshot().targets[0].name == "测试组" }
        let snapshot = h.service.snapshot()
        XCTAssertEqual(snapshot.targets[0].name, "测试组", "following the phone means following its synced group")
        XCTAssertFalse(snapshot.controls.isScrollActive, "a synced group only scrolls through the coordinator")

        await h.service.handle(.setAutoMode(enabled: true))
        XCTAssertTrue(h.cycler.isRunning, "auto on a synced group is the phone-driven cycler, not firmware auto")
        XCTAssertFalse(h.transports["A"]!.receivedCmdNames.contains("set_mode"))
        await h.service.handle(.setAutoMode(enabled: false))
        XCTAssertFalse(h.cycler.isRunning)

        await h.service.handle(.setScrollFps(fps: 30))
        XCTAssertFalse(h.transports["A"]!.receivedCmdNames.contains("set_scroll_interval"),
                       "never retunes the primary alone: that would tear the stitch apart")
    }

    func testDirectGroupScrollSpeedUsesTheActiveCoordinatorPlayback() async throws {
        let h = await harness(["A", "B"])
        try await h.coordinator.play(group: h.group, text: "A", fps: 10, loop: true)
        XCTAssertTrue(h.coordinator.isPlaying)
        await h.service.handle(.selectTarget(id: "group:\(h.group.id.uuidString)"))
        let startsBeforeA = h.transports["A"]?.sentGroupStartIntervalMs.count ?? 0
        let startsBeforeB = h.transports["B"]?.sentGroupStartIntervalMs.count ?? 0

        await h.service.handle(.setScrollFps(fps: 24))

        XCTAssertEqual(h.text.requestedFps, 24)
        XCTAssertTrue(h.coordinator.isPlaying)
        XCTAssertEqual(h.transports["A"]?.sentGroupStartIntervalMs.count, startsBeforeA + 1)
        XCTAssertEqual(h.transports["B"]?.sentGroupStartIntervalMs.count, startsBeforeB + 1)
        XCTAssertEqual(h.transports["A"]?.sentGroupStartIntervalMs.last, 42)
        XCTAssertEqual(h.transports["B"]?.sentGroupStartIntervalMs.last, 42)
        XCTAssertFalse(h.transports.values.contains { $0.receivedCmdNames.contains("set_scroll_interval") })
        await h.coordinator.stop(group: h.group)
    }

    // MARK: Harness

    @MainActor private struct Harness {
        let sessions: BoardSessionStore
        let controlCenter: BoardControlCenterModel
        let lipSync: LipSyncModel
        let service: WatchLinkService
        let cycler: GroupAutoCycler
        let coordinator: BoardGroupCoordinator
        let text: TextViewModel
        let transports: [String: WatchLinkFakeTransport]
        let group: BoardGroup

        func session(_ id: String) -> BoardSession {
            sessions.sessions.first { $0.connection.boardIdentity == id }!
        }
    }

    private func harness(_ memberIDs: [String], phoneTargetsGroup: Bool = false) async -> Harness {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: makeIsolatedDefaults())
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)
        let controlCenter = BoardControlCenterModel()
        controlCenter.loadDefaultsIfNeeded()
        let faceLibrary = FaceLibraryModel()
        let cycler = GroupAutoCycler(fanOut: fanOut, faceLibrary: faceLibrary, intervalProvider: { 3 })
        let lipSync = LipSyncModel(defaults: makeIsolatedDefaults(), capture: WatchLinkTestCapture(), permissionRequest: { .granted })
        var transports: [String: WatchLinkFakeTransport] = [:]
        var first: BoardSession?
        for id in memberIDs {
            let transport = WatchLinkFakeTransport()
            transport.wifiBoardId = id
            transport.name = id
            let session = sessions.session(for: "ble:\(UUID().uuidString)", name: id)
            _ = await session.connection.connect(using: transport)
            transports[id] = transport
            if first == nil { first = session }
        }
        if let first { sessions.select(first) }
        let group = store.create(name: "测试组")
        for id in memberIDs {
            try? store.addMember(groupID: group.id, member: .init(physicalBoardID: id, displayName: id))
        }
        // The phone's Control Center draft mirrors its own board's status.
        controlCenter.sync(from: sessions.active.connection.status)
        if phoneTargetsGroup { fanOut.setTarget(.group(group.id)) }
        let text = TextViewModel()
        let service = WatchLinkService(deps: .init(
            sessions: sessions, controlCenter: controlCenter, lipSync: lipSync, text: text,
            groupStore: store, fanOut: fanOut, groupAutoCycler: cycler, groupCoordinator: coordinator,
            controlTargetStorage: { phoneTargetsGroup ? group.id.uuidString : "" }
        ))
        return Harness(sessions: sessions, controlCenter: controlCenter, lipSync: lipSync, service: service,
                       cycler: cycler, coordinator: coordinator, text: text,
                       transports: transports, group: store.groups[0])
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// A board that answers every command and reports a fixed renderer state.
@MainActor
private final class WatchLinkFakeTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var wifiBoardId: String?
    var name = "rina"
    var caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
    var rendererScrollActive = false
    private(set) var receivedCmdNames: [String] = []
    private(set) var sentGroupStartIntervalMs: [Int] = []
    private var lastCmdPayloads: [String: [String: Any]] = [:]
    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func lastCmdField(_ cmd: String, _ key: String) -> Any? {
        lastCmdPayloads[cmd]?[key]
    }

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
            var wifi: [String: Any] = ["ip": "192.168.4.1"]
            if let wifiBoardId { wifi["boardId"] = wifiBoardId }
            let renderer: [String: Any] = [
                "mode": "auto", "brightness": 120, "color": "#112233", "autoIntervalMs": 3000,
                "autoFaceCount": 4, "autoFaceIndex": 1,
                "firmwareScrollActive": rendererScrollActive, "scrollIntervalMs": 100, "uiFps": 10,
            ]
            let object: [String: Any] = [
                "ok": true, "power": ["batteryPercent": 80, "batteryValid": true], "wifi": wifi, "renderer": renderer,
            ]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        case .getPreviewSync:
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "mode": "auto"])) ?? Data()
        case .getFrame:
            return PackedFrame().data
        case .blobBegin:
            return Data(#"{"ok":true,"offset":0,"chunkMax":512}"#.utf8)
        case .blobChunk:
            let offset = request.payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            let newOffset = Int(offset) + max(0, request.payload.count - 4)
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "offset": newOffset])) ?? Data()
        case .blobEnd:
            return Data(#"{"ok":true}"#.utf8)
        case .cmd:
            guard let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
                  let cmd = object["cmd"] as? String else {
                return Data(#"{"ok":true}"#.utf8)
            }
            receivedCmdNames.append(cmd)
            lastCmdPayloads[cmd] = object
            switch cmd {
            case "get_info":
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "proto": 1, "name": name, "bootId": "aaaaaaaa", "caps": caps,
                ])) ?? Data()
            case "clock_sample":
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "rxUs": 1_000, "txUs": 1_200, "bootId": "aaaaaaaa",
                ])) ?? Data()
            case "group_start":
                if let intervalMs = object["intervalMs"] as? NSNumber {
                    sentGroupStartIntervalMs.append(intervalMs.intValue)
                }
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "nowUs": 0, "frameCount": 10,
                ])) ?? Data()
            default:
                return Data(#"{"ok":true}"#.utf8)
            }
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}

/// Starts the real LipSyncModel lifecycle without microphone hardware or a
/// permission alert. Silent windows keep recognition active without frames.
private final class WatchLinkTestCapture: LipSyncCapturing {
    private(set) var isRunning = false
    var currentSampleRate: Double { 16_000 }
    @MainActor func start() async throws { isRunning = true }
    func stop() { isRunning = false }
    func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double) {
        (Array(repeating: 0, count: count), currentSampleRate)
    }
}
