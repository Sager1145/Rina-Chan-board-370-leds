import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Measurement-only harness for the `BoardConnection.handleIncoming` /
/// `RinaLinkDecoder.feed` / `route` hot path (PR-15). Drives a real
/// `BoardConnection` through a loopback `RinaTransport` fake with realistic
/// RinaLink wire bytes (built with the real `RinaLinkEncoder`/`Codable`
/// types from `RinaCore`, the same as production) and reports how much
/// main-thread wall-clock time each incoming "wire chunk" costs, both
/// per-chunk and bucketed into 16.7 ms ("one display frame") windows.
///
/// This never asserts on timing — it only prints `[BoardIncomingDecodeStress]`
/// lines with p50/p95/max per scenario, gated behind `RINA_PERF_GATE=1` so it
/// never runs (or affects) ordinary CI/local test runs. Skipped otherwise.
///
/// Caveat (see PR-15 report): the per-chunk timer wraps
/// `transport push -> await Task.yield()`, not the (private, unexported)
/// `handleIncoming` body directly, so each figure also includes one
/// actor-hop's scheduling latency on top of the actual decode+dispatch CPU
/// time measured by the `BoardIncomingDecode`/`BoardIncomingDispatch`
/// signposts added in this PR. Treat these as upper bounds; the signposts are
/// the ground truth for Instruments-based captures.
@MainActor
final class BoardIncomingDecodeStressTests: XCTestCase {

    private func requireGate() throws {
        guard ProcessInfo.processInfo.environment["RINA_PERF_GATE"] == "1" else {
            throw XCTSkip("RINA_PERF_GATE not set; skipping incoming-decode measurement")
        }
    }

    // MARK: a. Firmware trace-level log flood

    func testLogFloodMainThreadCost() async throws {
        try await runScenario(named: "log_flood_trace") { connection, transport in
            let (events, subID) = self.subscribe(connection)
            defer { connection.unsubscribe(subID) }
            let count = 400
            let ratePerSecond = 250.0 // typical firmware trace-level flood
            var samples: [PR15Sample] = []
            let clock = ContinuousClock()
            let start = clock.now
            for i in 0..<count {
                let frame = try Self.encodeEvent(
                    type: .evLog,
                    payload: RinaLogEvent(
                        level: ["T", "D", "I"][i % 3],
                        tag: "wifi_manager",
                        msg: "scan tick #\(i) rssi=-\(40 + i % 30) chan=\(1 + i % 11) state=associated"
                    )
                )
                let before = events.count
                let t0 = clock.now
                transport.pushIncoming(frame)
                await self.waitForCount(events, atLeast: before + 1)
                let t1 = clock.now
                samples.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
                if i < count - 1 {
                    try? await Task.sleep(until: start.advanced(by: .seconds(Double(i + 1) / ratePerSecond)), clock: clock)
                }
            }
            XCTAssertEqual(events.count, count, "every flooded log event must have been routed")
            return samples
        }
    }

    // MARK: b. Large Wi-Fi scan result

    func testLargeWifiScanMainThreadCost() async throws {
        try await runScenario(named: "wifi_scan_large") { connection, transport in
            let (events, subID) = self.subscribe(connection)
            defer { connection.unsubscribe(subID) }
            // 62 networks keeps the JSON payload under the 4096-byte single-frame
            // limit (RinaLinkFrameConstants.maxPayloadBytes); firmware would split
            // a larger scan across multiple EV_WIFI_SCAN pages, out of scope here.
            let networks = (0..<62).map {
                WifiNetwork(ssid: "Network_\($0)_ABCDE", rssi: -40 - ($0 % 55), secure: $0 % 3 != 0)
            }
            let reply = WifiScanReply(ok: true, scanning: false, networks: networks)
            let frame = try Self.encodeEvent(type: .evWifiScan, payload: reply)
            XCTAssertLessThanOrEqual(frame.count, RinaLinkFrameConstants.headerBytes + RinaLinkFrameConstants.maxPayloadBytes)
            var samples: [PR15Sample] = []
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<20 {
                let before = events.count
                let t0 = clock.now
                transport.pushIncoming(frame)
                await self.waitForCount(events, atLeast: before + 1)
                let t1 = clock.now
                samples.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
            }
            XCTAssertEqual(events.count, 20)
            return samples
        }
    }

    // MARK: c. Large BLOB transfer (chunked, MORE-aggregated reply)

    func testLargeBlobTransferMainThreadCost() async throws {
        try await runScenario(named: "blob_transfer_300kb") { connection, transport in
            let totalBytes = 300 * 1024
            let frameMax = 4090
            let sendTask = Task { () -> RinaLinkFrame? in
                try? await connection.send(type: .getFaces, payload: Data(), timeout: 30, aggregateMore: true)
            }
            // Wait for the request to reach the fake transport so we reply with
            // the same seq the real request path assigned.
            try await self.waitUntil { transport.lastRequest?.type == RinaLinkMessageType.getFaces.rawValue }
            let seq = try XCTUnwrap(transport.lastRequest?.seq)

            var remaining = totalBytes
            var replyFrames: [Data] = []
            let payloadByte = Data(repeating: 0x5A, count: frameMax)
            while remaining > 0 {
                let thisSize = min(frameMax, remaining)
                remaining -= thisSize
                let isLast = remaining == 0
                let flags: UInt8 = isLast ? 0 : RinaLinkFrameConstants.flagMore
                let frame = RinaLinkFrame(type: RinaLinkMessageType.getFaces.replyType, seq: seq,
                                          flags: flags, payload: payloadByte.prefix(thisSize))
                replyFrames.append(try RinaLinkEncoder.encode(frame))
            }
            // TCP-sized reads: several ~4KB frames coalesced per recv, unlike the
            // BLE-MTU-sized single-event pushes used by the other scenarios.
            let wireChunks = Self.groupByApproxSize(replyFrames, approxBytes: 8192)

            var samples: [PR15Sample] = []
            let clock = ContinuousClock()
            let start = clock.now
            for chunk in wireChunks {
                let t0 = clock.now
                transport.pushIncoming(chunk)
                for _ in 0..<8 { await Task.yield() }
                let t1 = clock.now
                samples.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
            }
            let result = await sendTask.value
            XCTAssertNotNil(result, "the aggregated blob reply must resolve the pending request")
            XCTAssertEqual(result?.payload.count, totalBytes)
            return samples
        }
    }

    // MARK: d. High-frequency events (>=60 Hz)

    func testHighFrequencyEventsMainThreadCost() async throws {
        try await runScenario(named: "high_frequency_events_90hz") { connection, transport in
            let (events, subID) = self.subscribe(connection)
            defer { connection.unsubscribe(subID) }
            let count = 270 // ~3s at 90Hz
            let ratePerSecond = 90.0
            var samples: [PR15Sample] = []
            let clock = ContinuousClock()
            let start = clock.now
            for i in 0..<count {
                let frame: Data
                switch i % 3 {
                case 0:
                    frame = try Self.encodeEvent(type: .evStatus, payload: DeviceStatus(
                        ok: true, v: 1, uptimeMs: i * 11,
                        power: PowerStatus(ok: true, charging: false, batteryPercent: 80)))
                case 1:
                    frame = try Self.encodeEvent(type: .evPower, payload: PowerStatus(
                        ok: true, charging: i % 2 == 0, batteryPercent: 79 - (i % 20)))
                default:
                    frame = try Self.encodeEvent(type: .evPreviewSync, payload: PreviewSync(
                        ok: true, v: 1, mode: "manual", playback: "idle", presentedSeq: i))
                }
                let before = events.count
                let t0 = clock.now
                transport.pushIncoming(frame)
                await self.waitForCount(events, atLeast: before + 1)
                let t1 = clock.now
                samples.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
                if i < count - 1 {
                    try? await Task.sleep(until: start.advanced(by: .seconds(Double(i + 1) / ratePerSecond)), clock: clock)
                }
            }
            XCTAssertEqual(events.count, count)
            return samples
        }
    }

    // MARK: - Harness

    private func runScenario(
        named name: String,
        _ body: (BoardConnection, PR15FakeTransport) async throws -> [PR15Sample]
    ) async throws {
        try requireGate()
        let connection = BoardConnection()
        let transport = PR15FakeTransport()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected, "\(name): fake transport must complete the handshake")
        defer { connection.disconnect() }

        let samples = try await body(connection, transport)
        XCTAssertGreaterThan(samples.count, 0, "\(name): scenario produced no samples")

        let chunkMs = samples.map { $0.elapsed.milliseconds }
        let windows = PR15Sample.bucketByDisplayFrame(samples)
        let windowMs = windows.map { $0.milliseconds }

        let build = PR15BuildConfig.current
        let load = PR15LoadAverage.oneMinute()
        print("""
        [BoardIncomingDecodeStress] scenario=\(name) build=\(build) load1m=\(String(format: "%.1f", load)) \
        chunks=\(samples.count) perChunkMs(p50=\(fmt(percentile(chunkMs, 0.50))), \
        p95=\(fmt(percentile(chunkMs, 0.95))), max=\(fmt(chunkMs.max() ?? 0))) \
        windows=\(windows.count) perWindowMs(p50=\(fmt(percentile(windowMs, 0.50))), \
        p95=\(fmt(percentile(windowMs, 0.95))), max=\(fmt(windowMs.max() ?? 0)))
        """)
    }

    private func subscribe(_ connection: BoardConnection) -> (PR15EventBox, UUID) {
        let (id, stream) = connection.subscribeToEvents()
        let box = PR15EventBox()
        Task { @MainActor in
            for await event in stream { box.append(event) }
        }
        return (box, id)
    }

    private func waitForCount(_ box: PR15EventBox, atLeast target: Int) async {
        var attempts = 0
        while box.count < target, attempts < 500 {
            await Task.yield()
            attempts += 1
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    private func fmt(_ ms: Double) -> String { String(format: "%.3f", ms) }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[index]
    }

    private static func encodeEvent<T: Encodable>(type: RinaLinkMessageType, payload: T) throws -> Data {
        let json = try JSONEncoder().encode(payload)
        return try RinaLinkEncoder.encode(RinaLinkFrame(type: type, seq: 0, flags: 0, payload: json))
    }

    private static func groupByApproxSize(_ frames: [Data], approxBytes: Int) -> [Data] {
        var chunks: [Data] = []
        var current = Data()
        for frame in frames {
            current.append(frame)
            if current.count >= approxBytes {
                chunks.append(current)
                current = Data()
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

// MARK: - Support types (PR15-prefixed to avoid colliding with other test files)

/// One measured wire-chunk push: `offset` is wall time since the scenario
/// started (used to bucket into 16.7 ms display-frame windows), `elapsed` is
/// the wall-clock cost of that push (see the class-doc caveat on precision).
private struct PR15Sample {
    let offset: Duration
    let elapsed: Duration

    /// Sums `elapsed` for all samples whose `offset` falls in the same
    /// 16.7 ms ("one 60Hz display frame") window, approximating how much
    /// main-thread decode work would land inside a single render frame.
    static func bucketByDisplayFrame(_ samples: [PR15Sample]) -> [Duration] {
        let frameSeconds = 1.0 / 60.0
        var sums: [Int: Double] = [:]
        for sample in samples {
            let windowIndex = Int(sample.offset.secondsDouble / frameSeconds)
            sums[windowIndex, default: 0] += sample.elapsed.secondsDouble
        }
        return sums.values.map { Duration.seconds($0) }
    }
}

private extension Duration {
    var secondsDouble: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
    var milliseconds: Double { secondsDouble * 1000 }
}

/// Plain reference box so an `@MainActor` consumer `Task` can append to a
/// shared array the polling loop above reads (both hop through MainActor).
@MainActor
private final class PR15EventBox {
    private(set) var count = 0
    func append(_: BoardEvent) { count += 1 }
}

private enum PR15BuildConfig {
    static var current: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }
}

private enum PR15LoadAverage {
    /// Best-effort 1-minute load average via `getloadavg(3)`, for the
    /// "only trust timings when load is low" rule in the PR-15 brief.
    static func oneMinute() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        let got = getloadavg(&loads, 3)
        return got > 0 ? loads[0] : -1
    }
}

/// A `RinaTransport` fake dedicated to this measurement suite: it answers the
/// real `BoardConnection.connect()` handshake automatically, and otherwise
/// lets the test push already RinaLinkEncoder-encoded wire bytes directly to
/// the incoming stream via `pushIncoming`, simulating exactly the bytes a
/// real BLE/TCP transport would deliver for a receive event.
@MainActor
private final class PR15FakeTransport: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 2048
    /// The most recent request frame the connection sent, so a scenario that
    /// drives its own reply (the blob transfer) can match the seq the real
    /// request path assigned instead of guessing it.
    private(set) var lastRequest: RinaLinkFrame?

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    init(kind: TransportKind = .wifi(host: "10.0.0.9", port: RinaLinkConstants.tcpPort)) {
        self.kind = kind
    }

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { self.stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { self.incomingContinuation = $0 } }

    func connect() async throws {
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            lastRequest = request
            // The blob scenario drives its own GET_FACES reply frames via
            // `pushIncoming`; every other request gets an immediate synthetic
            // reply so the handshake (and any in-scenario `send()`) completes.
            guard request.type != RinaLinkMessageType.getFaces.rawValue else { continue }
            let payload = Self.replyPayload(for: request)
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)))
        }
    }

    /// Pushes bytes to the incoming stream exactly as a live transport would
    /// hand a receive-buffer chunk to `BoardConnection`.
    func pushIncoming(_ data: Data) {
        incomingContinuation?.yield(data)
    }

    private static func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            let object: [String: Any] = ["ok": true, "renderer": ["mode": "manual"], "power": [:],
                                         "wifi": ["ip": "10.0.0.9"]]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        case .getPreviewSync:
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "mode": "manual"])) ?? Data()
        case .getFrame:
            return PackedFrame().data
        case .cmd:
            return Data(#"{"ok":true,"proto":1}"#.utf8)
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
