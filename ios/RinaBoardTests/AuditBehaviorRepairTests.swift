import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class AuditBehaviorRepairTests: XCTestCase {
    func testTerminalReadQueriesAndSettingsPreserveLiveOutput() async throws {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        let connected1 = await connection.connect(using: transport)
        XCTAssertTrue(connected1)
        defer { connection.disconnect() }
        var stopped = 0
        connection.output.register(.lipSync) { stopped += 1 }
        let token = connection.output.begin(.lipSync)
        let model = DebugViewModel()
        for input in ["get_info", #"{"cmd":"get_info"}"#, "wifi_status", #"{"cmd":"set_brightness","raw":67}"#, #"{"cmd":"log_subscribe","on":true}"#] {
            model.monitorInput = input
            await model.sendMonitorCommand(connection: connection)
            XCTAssertTrue(connection.output.isCurrent(token), input)
            XCTAssertEqual(stopped, 0, input)
        }
        model.monitorInput = #"{"cmd":"start_scroll","intervalMs":100}"#
        await model.sendMonitorCommand(connection: connection)
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(connection.output.source, .debug)
    }

    func testOverviewSwitchAllowsNewBoardAndRejectsDelayedOldBoard() async throws {
        let a = BoardConnection(), b = BoardConnection()
        let wireA = AuditBehaviorTransport(identity: "A"), wireB = AuditBehaviorTransport(identity: "B")
        let connected3 = await a.connect(using: wireA)
        XCTAssertTrue(connected3)
        let connected5 = await b.connect(using: wireB)
        XCTAssertTrue(connected5)
        defer { a.disconnect(); b.disconnect() }
        let model = DebugViewModel()
        await model.pageAppeared(sessionKey: "A", connection: a)
        wireA.holdStatus = true
        let oldRefresh = Task { await model.refreshOverview(connection: a) }
        try await waitUntil { wireA.heldStatus != nil }
        await model.pageAppeared(sessionKey: "B", connection: b)
        XCTAssertEqual(model.deviceInfo?.fw, "B")
        XCTAssertEqual(model.powerSnapshot?.batteryPercent, 72)
        wireA.releaseStatus()
        await oldRefresh.value
        XCTAssertEqual(model.deviceInfo?.fw, "B")
        XCTAssertEqual(model.powerSnapshot?.batteryPercent, 72)
        XCTAssertTrue(model.statusRawText.contains("B"))
        XCTAssertFalse(model.isRefreshingOverview)
    }

    func testSteadySilencePublishesChangedCompositionOnce() async throws {
        let suite = "AuditBehavior.lip.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = BoardConnection(), transport = FakeRinaTransport()
        let connected7 = await connection.connect(using: transport)
        XCTAssertTrue(connected7)
        let capture = AuditBehaviorMicrophone()
        let model = LipSyncModel(defaults: defaults, capture: capture, permissionRequest: { .granted })
        defer { model.stop(); connection.disconnect() }
        await model.start(connection: connection)
        try await transport.waitForSent(type: .setFrame, count: 1)
        let previous = try XCTUnwrap(lastPacked(transport))
        let alternative = try XCTUnwrap(model.mouthIds().first { id in
            var call = model.baseCall
            call.mouth = id
            return model.library?.compose(call: call) != previous
        })
        let before = transport.sentCount(type: .setFrame)
        model.setMouthId(alternative, for: nil)
        let expected = model.previewFrame
        XCTAssertNotEqual(previous, expected)
        try await waitUntil { self.lastPacked(transport) == expected }
        XCTAssertEqual(transport.sentCount(type: .setFrame), before + 1)
        // Several analysis windows with unchanged audio/composition must not retransmit.
        let reads = capture.readCount
        try await waitUntil { capture.readCount >= reads + 4 }
        XCTAssertEqual(transport.sentCount(type: .setFrame), before + 1)
    }

    func testCancelledGroupProducerStopsMemberThatAcceptedStart() async throws {
        let suite = "AuditBehavior.group.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: defaults)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let a = sessions.session(for: "ble:A", name: "A")
        let b = sessions.session(for: "ble:B", name: "B")
        let wireA = AuditBehaviorTransport(identity: "A"), wireB = AuditBehaviorTransport(identity: "B")
        let connected9 = await a.connection.connect(using: wireA)
        XCTAssertTrue(connected9)
        let connected11 = await b.connection.connect(using: wireB)
        XCTAssertTrue(connected11)
        defer { a.connection.disconnect(); b.connection.disconnect() }
        let created = store.create(name: "Cancel")
        try store.addMember(groupID: created.id, member: .init(physicalBoardID: "A", displayName: "A"))
        try store.addMember(groupID: created.id, member: .init(physicalBoardID: "B", displayName: "B"))
        wireB.holdGroupStart = true
        let play = Task { try await coordinator.play(group: store.groups[0], text: "A", fps: 10, loop: true) }
        try await waitUntil { wireA.acceptedStarts == 1 && wireB.heldGroupStart != nil }
        try await waitUntil { coordinator.memberStatus["A"] == .playing }
        play.cancel()
        do { try await play.value; XCTFail("Cancelled play committed") }
        catch BoardGroupCoordinator.GroupPlayError.aborted { }
        XCTAssertEqual(wireA.stopCount, 1, "Accepted board must receive stop_scroll despite producer cancellation")
        XCTAssertNotEqual(a.connection.output.source, .group)
        XCTAssertFalse(coordinator.isPlaying)
    }

    func testOffStepPhoneEchoStaysConfirmedUntilUserInput() {
        var brightness = WatchCrownInput(value: 50, range: 10...255, step: 5)
        brightness.synchronize(67)
        XCTAssertEqual(brightness.crownValue, 67)
        XCTAssertEqual(brightness.turn(to: 72, confirmedValue: 67), 70)
        XCTAssertEqual(brightness.adjust(by: 5, confirmedValue: 70), 75)
        brightness.synchronize(83)
        XCTAssertEqual(brightness.crownValue, 83)
        var interval = WatchCrownInput(value: 5, range: 0.5...60, step: 0.5)
        interval.synchronize(5.1)
        XCTAssertEqual(interval.crownValue, 5.1)
        XCTAssertEqual(interval.turn(to: 5.6, confirmedValue: 5.1), 5.5)
        XCTAssertNil(interval.adjust(by: -0.5, confirmedValue: 0.5))
    }

    private func lastPacked(_ transport: FakeRinaTransport) -> PackedFrame? {
        guard let payload = transport.lastSent(type: .setFrame)?.payload, payload.count >= 2 else { return nil }
        let start = 2 + Int(payload[1])
        guard payload.count >= start + 47 else { return nil }
        return PackedFrame(data: Data(payload[start..<start + 47]))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected production behavior did not occur before deadline")
    }
}

private final class AuditBehaviorMicrophone: LipSyncCapturing {
    var isRunning = false
    var readCount = 0
    let currentSampleRate = 16_000.0
    @MainActor func start() async throws { isRunning = true }
    func stop() { isRunning = false }
    func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double) {
        readCount += 1
        return ([Float](repeating: 0, count: count), currentSampleRate)
    }
}

/// Replaces only the physical wire; the request broker, ownership, group
/// scheduling, refresh and composition paths remain production code.
@MainActor
private final class AuditBehaviorTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    let identity: String
    var holdStatus = false
    var holdGroupStart = false
    var heldStatus: RinaLinkFrame?
    var heldGroupStart: RinaLinkFrame?
    private(set) var acceptedStarts = 0
    private(set) var stopCount = 0
    private let decoder = RinaLinkDecoder()
    private var incoming: AsyncStream<Data>.Continuation?
    private var states: AsyncStream<TransportState>.Continuation?
    init(identity: String) { self.identity = identity }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { states = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incoming = $0 } }
    func connect() async throws { states?.yield(.connected) }
    func disconnect() { states?.yield(.disconnected) }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        for request in decoder.feed(data) {
            if request.type == RinaLinkMessageType.getStatus.rawValue, holdStatus {
                heldStatus = request
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: request.payload)) as? [String: Any]
            if json?["cmd"] as? String == "group_start" {
                if holdGroupStart { heldGroupStart = request; continue }
                acceptedStarts += 1
            }
            if json?["cmd"] as? String == "stop_scroll" { stopCount += 1 }
            reply(request)
        }
    }
    func releaseStatus() {
        guard let request = heldStatus else { return }
        heldStatus = nil
        holdStatus = false
        reply(request)
    }
    private func reply(_ request: RinaLinkFrame) {
        var json: [String: Any] = ["ok": true]
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            json["wifi"] = ["boardId": identity, "ip": "192.168.4.1"]
            json["renderer"] = ["mode": "manual", "reason": identity]
        case .getPower: json["batteryPercent"] = identity == "A" ? 31 : 72
        case .cmd:
            let command = ((try? JSONSerialization.jsonObject(with: request.payload)) as? [String: Any])?["cmd"] as? String
            if command == "get_info" {
                json["fw"] = identity
                json["bootId"] = "aaaaaaaa"
                json["caps"] = ["identify", "clock_sample", "scroll_viewport", "group_start"]
            } else if command == "clock_sample" {
                json["bootId"] = "aaaaaaaa"
                json["rxUs"] = 1_000
                json["txUs"] = 1_200
            }
        case .blobBegin: json["offset"] = 0; json["chunkMax"] = 512
        case .blobChunk:
            let bytes = Array(request.payload.prefix(4))
            let offset = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
            json["offset"] = offset + request.payload.count - 4
        default: break
        }
        let payload = request.type == RinaLinkMessageType.getFrame.rawValue ? PackedFrame().data : try! JSONSerialization.data(withJSONObject: json)
        incoming?.yield(try! RinaLinkEncoder.encode(RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)))
    }
}
