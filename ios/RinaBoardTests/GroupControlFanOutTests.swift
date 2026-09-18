import XCTest
@testable import RinaBoard
@testable import RinaCore

@MainActor
final class GroupControlFanOutTests: XCTestCase {
    private struct Harness {
        let sessions: BoardSessionStore
        let store: BoardGroupStore
        let coordinator: BoardGroupCoordinator
        let fanOut: GroupControlFanOut
        let transports: [String: GroupControlFakeTransport]
        let group: BoardGroup
    }

    private func harness(_ memberIDs: [String]) async -> Harness {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "gcf.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)
        var transports: [String: GroupControlFakeTransport] = [:]
        for id in memberIDs {
            let transport = GroupControlFakeTransport()
            transport.wifiBoardId = id
            let session = sessions.session(for: id, name: id)
            _ = await session.connection.connect(using: transport)
            transports[id] = transport
        }
        let group = store.create(name: "测试组")
        for id in memberIDs {
            try? store.addMember(groupID: group.id, member: .init(physicalBoardID: id, displayName: id))
        }
        return Harness(sessions: sessions, store: store, coordinator: coordinator, fanOut: fanOut,
                       transports: transports, group: store.groups[0])
    }

    private func session(_ h: Harness, _ id: String) -> BoardSession {
        h.sessions.session(for: id, name: id)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 1. Unleased coalesced verbatim reaches every sink

    func testBrightnessReachesEverySinkUnleased() async throws {
        let h = await harness(["AAAA", "BBBB", "CCCC"])
        h.fanOut.setTarget(.group(h.group.id))
        XCTAssertEqual(h.fanOut.primaryID, "AAAA")
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.setBrightness(raw: 77))

        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 77 }
        await waitUntil { h.transports["CCCC"]?.lastCmdField("set_brightness", "raw") as? Int == 77 }
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 77)
        XCTAssertEqual(h.transports["CCCC"]?.lastCmdField("set_brightness", "raw") as? Int, 77)
        // Unleased: never claims the sink's output lease.
        XCTAssertNotEqual(session(h, "BBBB").connection.output.source, .groupControl)
        XCTAssertNotEqual(session(h, "CCCC").connection.output.source, .groupControl)
    }

    // MARK: 2. Deny-list commands never fan out

    func testDenyListCommandReachesOnlyPrimary() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.pauseScroll)
        // Give any accidental fan-out time to arrive before asserting absence.
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(h.transports["AAAA"]?.receivedCmdNames.contains("pause_scroll") == true)
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("pause_scroll") == true)
    }

    // MARK: 3. Slow sink doesn't delay the primary; ends with the latest frame

    func testSlowSinkDoesNotDelayPrimaryAndEndsWithLatestFrame() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["BBBB"]?.frameReplyDelay = 2.0
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")

        let start = Date()
        var lastBytes: [UInt8] = []
        for i in 0..<50 {
            var frame = PackedFrame()
            frame.set(i % PackedFrame.ledCount)
            lastBytes = frame.bytes
            _ = try await primary.connection.setFrame(frame, playback: .idle, reason: "t")
        }
        // The primary's own 50 sends must not have waited on the 2s-slow sink.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        await waitUntil(timeout: 6) { h.transports["BBBB"]?.receivedFrameBytes.last == lastBytes }
        XCTAssertEqual(h.transports["BBBB"]?.receivedFrameBytes.last, lastBytes)
    }

    // MARK: 4. Sink failure doesn't affect the primary; sets memberErrors

    func testSinkFailureRecordsMemberErrorWithoutAffectingPrimary() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["BBBB"]?.failCmds.insert("set_color")
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")

        let reply = try await primary.connection.command(.setColor(hex: "#112233"))
        XCTAssertTrue(reply.ok)

        await waitUntil { h.fanOut.memberErrors["BBBB"] != nil }
        XCTAssertNotNil(h.fanOut.memberErrors["BBBB"])
    }

    // MARK: 5. apply_saved_face resolves to a frame on the sink

    func testApplySavedFaceSendsResolvedFrameToSink() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        var resolved = PackedFrame()
        resolved.set(5)
        h.fanOut.faceFrameResolver = { _, _ in resolved }
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.applySavedFace(index: 2, reason: nil, playback: nil))

        await waitUntil { !(h.transports["BBBB"]?.receivedFrameBytes.isEmpty ?? true) }
        XCTAssertEqual(h.transports["BBBB"]?.receivedFrameBytes.last, resolved.bytes)
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("apply_saved_face") == true)
    }

    // MARK: 6. A face during group play supersedes the Text-tab playback

    func testFaceDuringGroupPlaySupersedesPlaybackWithoutReanchor() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["AAAA"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.transports["BBBB"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.fanOut.setTarget(.group(h.group.id))

        try await h.coordinator.play(group: h.group, text: "AB", fps: 10, loop: true)
        XCTAssertTrue(h.coordinator.isPlaying)
        let startCountB = h.transports["BBBB"]?.sentGroupStartAtUs.count ?? 0

        let primary = session(h, "AAAA")
        // Reclaim the primary's own output the way a real face-apply does,
        // then send it — this is what steers the primary board itself away
        // from `.group` before `command(_:)` checks `output.source`.
        let token = primary.connection.output.claim(.manual)
        _ = try await primary.connection.withOutput(token) {
            try await primary.connection.command(.applySavedFace(index: 0, reason: nil, playback: nil))
        }

        await waitUntil { h.coordinator.isPlaying == false }
        XCTAssertFalse(h.coordinator.isPlaying)
        #if DEBUG
        await h.coordinator.debugReanchorNow()
        #endif
        XCTAssertEqual(h.transports["BBBB"]?.sentGroupStartAtUs.count, startCountB)
    }

    // MARK: 7. target -> single invalidates sink leases and clears fanOut

    func testTargetToSingleInvalidatesSinkLeasesAndClearsFanOut() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")
        let sink = session(h, "BBBB")
        _ = try await primary.connection.command(.applySavedFace(index: 0, reason: nil, playback: nil))
        await waitUntil { sink.connection.output.source == .groupControl }
        XCTAssertEqual(sink.connection.output.source, .groupControl)

        h.fanOut.setTarget(.single)

        await waitUntil { sink.connection.output.source != .groupControl }
        XCTAssertNotEqual(sink.connection.output.source, .groupControl)
        XCTAssertNil(primary.connection.fanOut)
    }

    // MARK: 8. Group target with a non-member active selects the first online member

    func testGroupTargetWithNonMemberActiveSelectsFirstOnlineMember() async throws {
        let h = await harness(["AAAA", "BBBB"])
        let outsider = GroupControlFakeTransport()
        outsider.wifiBoardId = "OUTSIDER"
        let outsiderSession = h.sessions.session(for: "OUTSIDER", name: "OUTSIDER")
        _ = await outsiderSession.connection.connect(using: outsider)
        h.sessions.select(outsiderSession)

        h.fanOut.setTarget(.group(h.group.id))

        XCTAssertEqual(h.fanOut.primaryID, "AAAA")
        XCTAssertTrue(h.sessions.active === session(h, "AAAA"))
    }

    // MARK: 9. Sink reconnect gets a fresh channel

    func testSinkReconnectGetsFreshChannel() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let sink = session(h, "BBBB")

        let newTransport = GroupControlFakeTransport()
        newTransport.wifiBoardId = "BBBB"
        sink.connection.disconnect()
        _ = await sink.connection.connect(using: newTransport)
        await waitUntil { sink.connection.connectionState == .connected }

        let primary = session(h, "AAAA")
        _ = try await primary.connection.command(.setBrightness(raw: 55))
        await waitUntil { newTransport.lastCmdField("set_brightness", "raw") as? Int == 55 }
        XCTAssertEqual(newTransport.lastCmdField("set_brightness", "raw") as? Int, 55)
    }

    // MARK: 10. Debug output source is not mirrored

    func testDebugOutputSourceIsNotMirrored() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")
        let token = primary.connection.output.claim(.debug)
        _ = try await primary.connection.withOutput(token) {
            try await primary.connection.command(.setBrightness(raw: 99))
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw"))
    }

    // MARK: 11. Primary disconnect promotes the next online member; draft survives

    func testPrimaryDisconnectPromotesNextMemberAndPreservesDraft() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        XCTAssertEqual(h.fanOut.primaryID, "AAAA")

        var retagged: String?
        h.fanOut.draftPromotionHook = { retagged = $0 }

        let primary = session(h, "AAAA")
        primary.connection.disconnect()

        await waitUntil { h.fanOut.primaryID == "BBBB" }
        XCTAssertEqual(h.fanOut.primaryID, "BBBB")
        XCTAssertEqual(retagged, session(h, "BBBB").connection.boardKey)
    }
}

// MARK: - Fake transport

/// Minimal copy of `GroupFakeTransport` (private to `BoardGroupTests.swift`)
/// extended with per-command failure/delay and SET_FRAME recording for the
/// fan-out tests above.
private final class GroupControlFakeTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var bootId = "aaaaaaaa"
    var caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
    var wifiBoardId: String?
    var clockRxUs: Int64 = 1_000
    var clockTxUs: Int64 = 1_200
    var cmdReplyDelay: [String: TimeInterval] = [:]
    var frameReplyDelay: TimeInterval = 0
    var failCmds: Set<String> = []
    private(set) var sentGroupStartAtUs: [Int64] = []
    private(set) var receivedCmdNames: [String] = []
    private(set) var receivedFrameBytes: [[UInt8]] = []
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
            let delay = delay(for: request)
            if delay > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self else { return }
                    self.emitReply(request, payload: self.replyPayload(for: request))
                }
            } else {
                emitReply(request, payload: replyPayload(for: request))
            }
        }
    }

    private func delay(for request: RinaLinkFrame) -> TimeInterval {
        if request.type == RinaLinkMessageType.setFrame.rawValue { return frameReplyDelay }
        guard request.type == RinaLinkMessageType.cmd.rawValue,
              let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
              let cmd = object["cmd"] as? String else { return 0 }
        return cmdReplyDelay[cmd] ?? 0
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
            if failCmds.contains(cmd) {
                return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": "denied"])) ?? Data()
            }
            switch cmd {
            case "get_info":
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "proto": 1, "bootId": bootId, "caps": caps])) ?? Data()
            case "clock_sample":
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "rxUs": clockRxUs, "txUs": clockTxUs, "bootId": bootId])) ?? Data()
            case "group_start":
                if let atUs = object["atUs"] as? NSNumber { sentGroupStartAtUs.append(atUs.int64Value) }
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "nowUs": 0, "frameCount": 10])) ?? Data()
            case "identify":
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "shown": true, "number": object["number"] ?? 1, "ttlMs": object["ttlMs"] ?? 5000,
                ])) ?? Data()
            case "stop_scroll":
                return Data(#"{"ok":true}"#.utf8)
            case "apply_saved_face":
                let index = object["index"] as? Int ?? 0
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "autoFaceIndex": index, "autoFaceId": "face-\(index)",
                ])) ?? Data()
            default:
                return Data(#"{"ok":true}"#.utf8)
            }
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
