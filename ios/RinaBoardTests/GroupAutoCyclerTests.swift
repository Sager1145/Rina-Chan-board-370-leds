import XCTest
@testable import RinaBoard
@testable import RinaCore

@MainActor
final class GroupAutoCyclerTests: XCTestCase {
    private struct Harness {
        let sessions: BoardSessionStore
        let store: BoardGroupStore
        let coordinator: BoardGroupCoordinator
        let fanOut: GroupControlFanOut
        let faceLibrary: FaceLibraryModel
        let transports: [String: AutoCyclerFakeTransport]
        let group: BoardGroup
    }

    /// Three faces, `order` 3/1/2 — auto-cycle order must read back 1, 2, 3
    /// (`FaceDocument.sortedFaces`, matching the firmware's own
    /// `loadSavedFaces` sort), not JSON/array order.
    private func makeFaces() -> [SavedFace] {
        func frame(_ led: Int) -> [Int] {
            var f = PackedFrame()
            f.set(led)
            return f.bytes.map(Int.init)
        }
        return [
            SavedFace(id: "c", name: "C", type: .default, frameBytes: frame(2), order: 3),
            SavedFace(id: "a", name: "A", type: .default, frameBytes: frame(0), order: 1),
            SavedFace(id: "b", name: "B", type: .custom, frameBytes: frame(1), order: 2),
        ]
    }

    private func harness(_ memberIDs: [String], interval: Double = 0.05) async -> (Harness, GroupAutoCycler) {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "gac.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)
        let faceLibrary = FaceLibraryModel()
        faceLibrary.faceDocument = FaceDocument(faces: makeFaces())

        var transports: [String: AutoCyclerFakeTransport] = [:]
        for id in memberIDs {
            let transport = AutoCyclerFakeTransport()
            transport.wifiBoardId = id
            let session = sessions.session(for: "ble:\(UUID().uuidString)", name: id)
            _ = await session.connection.connect(using: transport)
            transports[id] = transport
        }
        let group = store.create(name: "测试组")
        for id in memberIDs {
            try? store.addMember(groupID: group.id, member: .init(physicalBoardID: id, displayName: id))
        }
        fanOut.setTarget(.group(group.id))

        let cycler = GroupAutoCycler(
            fanOut: fanOut,
            faceLibrary: faceLibrary,
            intervalProvider: { interval },
            sleeper: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        )
        let h = Harness(sessions: sessions, store: store, coordinator: coordinator, fanOut: fanOut,
                        faceLibrary: faceLibrary, transports: transports, group: store.groups[0])
        return (h, cycler)
    }

    private func session(_ h: Harness, _ id: String) -> BoardSession {
        h.sessions.sessions.first { $0.connection.boardIdentity == id }!
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 1. Sends frames in library (sortedFaces) order at the interval

    func testCyclesInLibraryOrderAtInterval() async throws {
        let (h, cycler) = await harness(["AAAA"])
        XCTAssertTrue(cycler.start())

        await waitUntil { h.transports["AAAA"]?.receivedFrameBytes.count ?? 0 >= 3 }
        let bytes = h.transports["AAAA"]!.receivedFrameBytes
        XCTAssertGreaterThanOrEqual(bytes.count, 3)

        let faces = h.faceLibrary.faces(in: .board) // sortedFaces: a(1), b(2), c(3)
        let expected = faces.map { PackedFrame(bytes: $0.frameBytes.map(UInt8.init))!.bytes }
        XCTAssertEqual(Array(bytes.prefix(3)), Array(expected.prefix(3)))
        cycler.stop()
    }

    // MARK: 2. Every member receives the identical frame each tick

    func testAllMembersReceiveIdenticalFrames() async throws {
        let (h, cycler) = await harness(["AAAA", "BBBB", "CCCC"])
        XCTAssertTrue(cycler.start())

        await waitUntil { (h.transports["BBBB"]?.receivedFrameBytes.count ?? 0) >= 2
            && (h.transports["CCCC"]?.receivedFrameBytes.count ?? 0) >= 2 }

        let a = h.transports["AAAA"]!.receivedFrameBytes
        let b = h.transports["BBBB"]!.receivedFrameBytes
        let c = h.transports["CCCC"]!.receivedFrameBytes
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(Array(b.prefix(2)), Array(a.prefix(2)))
        XCTAssertEqual(Array(c.prefix(2)), Array(a.prefix(2)))
        cycler.stop()
    }

    // MARK: 3. Stops on target -> single

    func testStopsOnTargetToSingle() async throws {
        let (h, cycler) = await harness(["AAAA", "BBBB"])
        XCTAssertTrue(cycler.start())
        await waitUntil { h.transports["BBBB"]?.receivedFrameBytes.isEmpty == false }

        h.fanOut.setTarget(.single)
        // The loop's own guard notices the primary is gone on its next tick.
        await waitUntil(timeout: 2) { cycler.isRunning == false }
        XCTAssertFalse(cycler.isRunning)

        let countAtStop = h.transports["BBBB"]!.receivedFrameBytes.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.transports["BBBB"]?.receivedFrameBytes.count, countAtStop)
    }

    // MARK: 4. Stops on a manual setFrame from another source

    func testStopsOnManualSetFrameFromAnotherSource() async throws {
        let (h, cycler) = await harness(["AAAA"])
        XCTAssertTrue(cycler.start())
        await waitUntil { h.transports["AAAA"]?.receivedFrameBytes.isEmpty == false }
        XCTAssertTrue(cycler.isRunning)

        let primary = session(h, "AAAA")
        let token = primary.connection.output.claim(.manual)
        var manualFrame = PackedFrame()
        manualFrame.set(9)
        _ = try await primary.connection.withOutput(token) {
            try await primary.connection.setFrame(manualFrame, playback: .idle, reason: "manual", outputSession: token)
        }

        await waitUntil { cycler.isRunning == false }
        XCTAssertFalse(cycler.isRunning)
        XCTAssertFalse(cycler.wantsRunning)
    }

    // MARK: 5. Group-mode auto never sends firmware set_mode auto to any board

    func testGroupModeAutoNeverSendsFirmwareSetModeAuto() async throws {
        let (h, cycler) = await harness(["AAAA", "BBBB"])
        XCTAssertTrue(cycler.start())
        await waitUntil { (h.transports["BBBB"]?.receivedFrameBytes.count ?? 0) >= 2 }

        XCTAssertFalse(h.transports["AAAA"]?.receivedCmdNames.contains("set_mode") == true)
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("set_mode") == true)
        cycler.stop()
    }
}

// MARK: - Fake transport

/// Minimal transport fake for the auto-cycler tests: connect handshake plus
/// SET_FRAME/CMD recording, independent of `GroupControlFanOutTests`'s
/// private `GroupControlFakeTransport`.
private final class AutoCyclerFakeTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var bootId = "aaaaaaaa"
    var caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
    var wifiBoardId: String?
    private(set) var receivedCmdNames: [String] = []
    private(set) var receivedFrameBytes: [[UInt8]] = []

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            emitReply(request, payload: replyPayload(for: request))
        }
    }

    private func emitReply(_ request: RinaLinkFrame, payload: Data) {
        incomingContinuation?.yield(try! RinaLinkEncoder.encode(
            RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
        ))
    }

    private func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            var wifi: [String: Any] = ["ip": "192.168.4.1"]
            if let wifiBoardId { wifi["boardId"] = wifiBoardId }
            let object: [String: Any] = ["ok": true, "renderer": ["mode": "manual"], "power": [:], "wifi": wifi]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        case .getPreviewSync:
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "mode": "manual"])) ?? Data()
        case .getFrame:
            return PackedFrame().data
        case .setFrame:
            let bytes = Array(request.payload.suffix(PackedFrame.byteCount))
            receivedFrameBytes.append(bytes)
            return Data(#"{"ok":true}"#.utf8)
        case .cmd:
            guard let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
                  let cmd = object["cmd"] as? String else {
                return Data(#"{"ok":true}"#.utf8)
            }
            receivedCmdNames.append(cmd)
            switch cmd {
            case "get_info":
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "proto": 1, "bootId": bootId, "caps": caps])) ?? Data()
            default:
                return Data(#"{"ok":true}"#.utf8)
            }
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
