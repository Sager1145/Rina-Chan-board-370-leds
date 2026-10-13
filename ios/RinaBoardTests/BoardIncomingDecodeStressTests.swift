import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Measurement-only harness for the `BoardConnection.handleIncoming` /
/// `RinaLinkDecoder.feed` / `route` hot path (PR-15). Drives a real
/// `BoardConnection` through a loopback `RinaTransport` fake with realistic
/// RinaLink wire bytes (built with the real `RinaLinkEncoder`/`Codable`
/// types from `RinaCore`, the same as production), paced like a real BLE
/// notification stream or TCP socket read, and reports how much main-thread
/// wall-clock time each incoming wire chunk costs, both per-chunk and
/// bucketed into 16.7 ms ("one display frame") windows.
///
/// This never asserts on timing — it only prints `[BoardIncomingDecodeStress]`
/// lines with p50/p95/max per scenario, gated behind `RINA_PERF_GATE=1` so it
/// never runs (or affects) ordinary CI/local test runs. Skipped otherwise.
///
/// Primary numbers come from `BoardConnection.incomingDecodeProbe`, a
/// test-only hook that times exactly the regions the `BoardIncomingDecode`/
/// `BoardIncomingDispatch` signposts cover (via `ContinuousClock`, read
/// *after* both signposts end, inside `handleIncoming` itself). A secondary
/// "end-to-end" column keeps the coarser `transport push -> await
/// Task.yield()` timing — it also includes one actor-hop's scheduling
/// latency, so it runs a bit higher than the probe numbers.
///
/// IMPORTANT — these numbers are a floor, not a ceiling. `BoardConnection`
/// is `@Observable`; `route()`'s writes to `lastLog`/`preview`/`power`/
/// `status` are what actually trigger SwiftUI re-renders in the app, and
/// that observation/diffing work happens *outside* the probe's measured
/// region (this harness has no view observers at all — `subscribe(_:)` only
/// appends to a plain counter). A real screen with bound views will do
/// strictly more main-thread work per chunk than what's reported here. Also
/// only trust **Release** figures for the "p95 > 4 ms/frame" decision rule —
/// Debug inflates plain-Swift/JSON cost by a large, non-representative
/// factor.
@MainActor
final class BoardIncomingDecodeStressTests: XCTestCase {

    override func tearDown() {
        BoardConnection.incomingDecodeProbe = nil
        super.tearDown()
    }

    private func requireGate() throws {
        guard ProcessInfo.processInfo.environment["RINA_PERF_GATE"] == "1" else {
            throw XCTSkip("RINA_PERF_GATE not set; skipping incoming-decode measurement")
        }
    }

    // MARK: a. Firmware trace-level log flood (BLE)

    func testLogFloodMainThreadCost() async throws {
        try await runScenario(named: "log_flood_trace", transportKind: .bluetooth, transportLabel: "ble") { connection, transport in
            let (events, subID) = self.subscribe(connection)
            defer { connection.unsubscribe(subID) }
            let count = 400
            let ratePerSecond = 250.0 // typical firmware trace-level flood
            var endToEnd: [PR15Sample] = []
            var timeouts = 0
            let clock = ContinuousClock()
            let start = clock.now
            for i in 0..<count {
                // Each log line is well under one BLE MTU notification, so it
                // arrives as a single, unsplit push.
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
                let observed = await self.waitForCount(events, atLeast: before + 1)
                if !observed { timeouts += 1 }
                let t1 = clock.now
                endToEnd.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
                if i < count - 1 {
                    try? await Task.sleep(until: start.advanced(by: .seconds(Double(i + 1) / ratePerSecond)), clock: clock)
                }
            }
            XCTAssertEqual(events.count, count, "every flooded log event must have been routed")
            return PR15EndToEndResult(samples: endToEnd, waitTimeouts: timeouts)
        }
    }

    // MARK: b. Large Wi-Fi scan result — TCP and BLE delivery

    func testLargeWifiScanTCPMainThreadCost() async throws {
        try await runScenario(named: "wifi_scan_large", transportKind: .wifi(host: "10.0.0.9", port: RinaLinkConstants.tcpPort), transportLabel: "tcp") { connection, transport in
            let (events, subID) = self.subscribe(connection)
            defer { connection.unsubscribe(subID) }
            let frame = try Self.makeWifiScanFrame(networkCount: 62)
            var endToEnd: [PR15Sample] = []
            var timeouts = 0
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<20 {
                let before = events.count
                let t0 = clock.now
                // TCP socket reads at a plausible ~150 KB/s throughput.
                await transport.deliverIncoming(frame, chunkSize: 1400,
                                                interChunkDelay: PR15FakeTransport.tcpChunkDelay(chunkSize: 1400))
                let observed = await self.waitForCount(events, atLeast: before + 1)
                if !observed { timeouts += 1 }
                let t1 = clock.now
                endToEnd.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
            }
            XCTAssertEqual(events.count, 20)
            return PR15EndToEndResult(samples: endToEnd, waitTimeouts: timeouts)
        }
    }

    func testLargeWifiScanBLEMainThreadCost() async throws {
        try await runScenario(named: "wifi_scan_large", transportKind: .bluetooth, transportLabel: "ble") { connection, transport in
            let (events, subID) = self.subscribe(connection)
            defer { connection.unsubscribe(subID) }
            let frame = try Self.makeWifiScanFrame(networkCount: 62)
            var endToEnd: [PR15Sample] = []
            var timeouts = 0
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<20 {
                let before = events.count
                let t0 = clock.now
                // BLE MTU-sized notifications (~200 bytes) at a ~7.5ms
                // connection-interval cadence — this frame needs ~20+
                // notifications, exercising the decoder's partial-buffering
                // (frames split across pushes) path.
                await transport.deliverIncoming(frame, chunkSize: 200, interChunkDelay: .seconds(0.0075))
                let observed = await self.waitForCount(events, atLeast: before + 1)
                if !observed { timeouts += 1 }
                let t1 = clock.now
                endToEnd.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
            }
            XCTAssertEqual(events.count, 20)
            return PR15EndToEndResult(samples: endToEnd, waitTimeouts: timeouts)
        }
    }

    // MARK: c. Large BLOB transfer — real GET_FACES round trips (TCP)

    func testLargeFacesDocumentMainThreadCost() async throws {
        try await runScenario(named: "faces_document_250kb", transportKind: .wifi(host: "10.0.0.9", port: RinaLinkConstants.tcpPort), transportLabel: "tcp") { connection, transport in
            // Production GET_FACES (`BoardConnection.getFaces()`) caps the
            // document at `maxFacesDocumentBytes` (256 KiB) and always uses
            // `aggregateMore: false` — each round trip is its own one-frame
            // reply, not accumulated MORE-chunks on one seq. Reproduce that
            // real flow exactly instead of hand-rolling an aggregate reply
            // that would exceed `maxAggregatedReplyBytes` (256 KiB) and fall
            // into the quarantine path.
            let totalBytes = 250 * 1024
            transport.configureFacesFile(totalBytes: totalBytes)
            let result = try await connection.getFaces()
            XCTAssertEqual(result.count, totalBytes, "the reassembled document must match the synthetic file")
            // No test-side push loop here: every reply frame is generated and
            // TCP-paced by the transport itself in response to each request,
            // so there's no meaningful "push -> yield" end-to-end column.
            return PR15EndToEndResult(samples: [], waitTimeouts: 0)
        }
    }

    // MARK: d. High-frequency events (>=60 Hz, BLE)

    func testHighFrequencyEventsMainThreadCost() async throws {
        try await runScenario(named: "high_frequency_events_90hz", transportKind: .bluetooth, transportLabel: "ble") { connection, transport in
            let (events, subID) = self.subscribe(connection)
            defer { connection.unsubscribe(subID) }
            let count = 270 // ~3s at 90Hz
            let ratePerSecond = 90.0
            var endToEnd: [PR15Sample] = []
            var timeouts = 0
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
                let observed = await self.waitForCount(events, atLeast: before + 1)
                if !observed { timeouts += 1 }
                let t1 = clock.now
                endToEnd.append(PR15Sample(offset: start.duration(to: t0), elapsed: t0.duration(to: t1)))
                if i < count - 1 {
                    try? await Task.sleep(until: start.advanced(by: .seconds(Double(i + 1) / ratePerSecond)), clock: clock)
                }
            }
            XCTAssertEqual(events.count, count)
            return PR15EndToEndResult(samples: endToEnd, waitTimeouts: timeouts)
        }
    }

    // MARK: - Harness

    private func runScenario(
        named name: String,
        transportKind: TransportKind,
        transportLabel: String,
        _ body: (BoardConnection, PR15FakeTransport) async throws -> PR15EndToEndResult
    ) async throws {
        try requireGate()
        let connection = BoardConnection()
        let transport = PR15FakeTransport(kind: transportKind)

        // Primary timing: installed on the real `handleIncoming` regions via
        // the PR-15 probe hook, so these numbers are the actual main-thread
        // decode+dispatch CPU cost, not a scheduling-latency-inflated proxy.
        let probeBox = PR15ProbeBox()
        BoardConnection.incomingDecodeProbe = { [weak probeBox] decode, dispatch, bytes in
            probeBox?.record(decode: decode, dispatch: dispatch, bytes: bytes)
        }
        defer { BoardConnection.incomingDecodeProbe = nil }

        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected, "\(name): fake transport must complete the handshake")
        defer { connection.disconnect() }
        // The connect handshake itself produces a few probe samples (status/
        // preview/get_info replies); only count scenario-driven chunks below.
        probeBox.reset()

        let endToEndResult = try await body(connection, transport)

        let decodeSamples = probeBox.samples
        XCTAssertGreaterThan(decodeSamples.count, 0, "\(name): probe recorded no chunks")

        let totalMs = decodeSamples.map { $0.decode.milliseconds }
        let dispatchMs = decodeSamples.map { $0.dispatch.milliseconds }
        let feedMs = decodeSamples.map { ($0.decode - $0.dispatch).milliseconds }
        let windowMs = PR15ProbeBox.Sample.bucketByDisplayFrame(decodeSamples).map { $0.milliseconds }
        let endToEndMs = endToEndResult.samples.map { $0.elapsed.milliseconds }

        let build = PR15BuildConfig.current
        let load = PR15LoadAverage.oneMinute()
        let endToEndColumn = endToEndMs.isEmpty
            ? "endToEndMs(n/a)"
            : "endToEndMs(p50=\(fmt(percentile(endToEndMs, 0.50))), p95=\(fmt(percentile(endToEndMs, 0.95))), max=\(fmt(endToEndMs.max() ?? 0)))"
        print("""
        [BoardIncomingDecodeStress] scenario=\(name) transport=\(transportLabel) build=\(build) load1m=\(String(format: "%.1f", load)) \
        chunks=\(decodeSamples.count) waitTimeouts=\(endToEndResult.waitTimeouts) \
        feedMs(p50=\(fmt(percentile(feedMs, 0.50))), p95=\(fmt(percentile(feedMs, 0.95))), max=\(fmt(feedMs.max() ?? 0))) \
        dispatchMs(p50=\(fmt(percentile(dispatchMs, 0.50))), p95=\(fmt(percentile(dispatchMs, 0.95))), max=\(fmt(dispatchMs.max() ?? 0))) \
        totalMs(p50=\(fmt(percentile(totalMs, 0.50))), p95=\(fmt(percentile(totalMs, 0.95))), max=\(fmt(totalMs.max() ?? 0))) \
        windows=\(windowMs.count) perWindowMs(p50=\(fmt(percentile(windowMs, 0.50))), \(windowP95Segment(windowMs)), max=\(fmt(windowMs.max() ?? 0))) \
        \(endToEndColumn)
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

    /// Waits until `box.count >= target` or `deadline` elapses (wall clock,
    /// not an attempt count), returning whether the target was actually
    /// reached — callers count `false` results as `waitTimeouts` in the
    /// printed report line instead of silently under-waiting.
    private func waitForCount(_ box: PR15EventBox, atLeast target: Int, deadline: Duration = .milliseconds(250)) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while box.count < target {
            if start.duration(to: clock.now) >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    private func fmt(_ ms: Double) -> String { String(format: "%.3f", ms) }

    /// The window p95 is unreliable with few samples (small-n percentiles
    /// collapse toward the max); flag that instead of implying precision.
    private func windowP95Segment(_ values: [Double]) -> String {
        let n = values.count
        let value = fmt(percentile(values, 0.95))
        return n < 20 ? "p95(n=\(n))≈max=\(value)" : "p95(n=\(n))=\(value)"
    }

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

    private static func makeWifiScanFrame(networkCount: Int) throws -> Data {
        // Keeps the JSON payload under the 4096-byte single-frame limit
        // (RinaLinkFrameConstants.maxPayloadBytes) at 62 networks; firmware
        // would split a larger scan across multiple EV_WIFI_SCAN pages,
        // out of scope here.
        let networks = (0..<networkCount).map {
            WifiNetwork(ssid: "Network_\($0)_ABCDE", rssi: -40 - ($0 % 55), secure: $0 % 3 != 0)
        }
        let reply = WifiScanReply(ok: true, scanning: false, networks: networks)
        let frame = try encodeEvent(type: .evWifiScan, payload: reply)
        precondition(frame.count <= RinaLinkFrameConstants.headerBytes + RinaLinkFrameConstants.maxPayloadBytes)
        return frame
    }
}

// MARK: - Support types (PR15-prefixed to avoid colliding with other test files)

/// One end-to-end (secondary) sample: `offset` is wall time since the
/// scenario started, `elapsed` is `transport push -> await Task.yield()`,
/// which still includes one actor-hop's scheduling latency on top of the
/// real decode+dispatch cost — see `PR15ProbeBox` for the primary numbers.
private struct PR15Sample {
    let offset: Duration
    let elapsed: Duration
}

/// A scenario body's return value: its own (possibly empty — see the
/// GET_FACES scenario) end-to-end samples, plus how many `waitForCount`
/// calls gave up at the deadline instead of observing the expected event.
private struct PR15EndToEndResult {
    let samples: [PR15Sample]
    let waitTimeouts: Int
}

/// Collects samples from `BoardConnection.incomingDecodeProbe`, timed by the
/// probe callback itself over exactly the `BoardIncomingDecode`/
/// `BoardIncomingDispatch` signpost regions inside `handleIncoming`.
@MainActor
private final class PR15ProbeBox {
    struct Sample {
        /// Wall time since this box was created (or last `reset()`), taken
        /// inside the probe callback — used to bucket into 16.7 ms windows.
        let offset: Duration
        /// `handleIncoming`'s whole per-chunk region: `decoder.feed` + the
        /// route loop (matches the `BoardIncomingDecode` signpost).
        let decode: Duration
        /// Just the route loop (matches the `BoardIncomingDispatch` signpost).
        let dispatch: Duration
        let bytes: Int

        /// Sums `decode` for all samples whose `offset` falls in the same
        /// 16.7 ms ("one 60Hz display frame") window, approximating how much
        /// main-thread decode work would land inside a single render frame.
        static func bucketByDisplayFrame(_ samples: [Sample]) -> [Duration] {
            let frameSeconds = 1.0 / 60.0
            var sums: [Int: Double] = [:]
            for sample in samples {
                let windowIndex = Int(sample.offset.secondsDouble / frameSeconds)
                sums[windowIndex, default: 0] += sample.decode.secondsDouble
            }
            return sums.values.map { Duration.seconds($0) }
        }
    }

    private let clock = ContinuousClock()
    private var start: ContinuousClock.Instant
    private(set) var samples: [Sample] = []

    init() { start = clock.now }

    /// Drops samples accumulated so far and restarts the window-offset clock,
    /// so the connect handshake's own traffic doesn't pollute a scenario's
    /// chunk count / window buckets.
    func reset() {
        samples.removeAll()
        start = clock.now
    }

    func record(decode: Duration, dispatch: Duration, bytes: Int) {
        samples.append(Sample(offset: start.duration(to: clock.now), decode: decode, dispatch: dispatch, bytes: bytes))
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
/// real `BoardConnection.connect()` handshake automatically, paces bytes onto
/// the incoming stream like a real BLE notification/TCP-read cadence via
/// `deliverIncoming`/`pushIncoming`, and (for the GET_FACES scenario)
/// auto-replies to each round trip against a synthetic in-memory "document".
@MainActor
private final class PR15FakeTransport: RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 2048
    /// The most recent request frame the connection sent (diagnostic only).
    private(set) var lastRequest: RinaLinkFrame?

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?
    private var facesTotalBytes: Data?
    private let facesGen: UInt32 = 7
    private static let facesChunkMaxPayload = 4092 // 4096 frame max - 4-byte gen header

    init(kind: TransportKind) {
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
            if request.type == RinaLinkMessageType.getFaces.rawValue {
                await replyToFacesRequest(request)
                continue
            }
            let payload = Self.replyPayload(for: request)
            guard let encoded = try? RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
            ) else { continue }
            incomingContinuation?.yield(encoded)
        }
    }

    /// Pushes bytes to the incoming stream exactly as a live transport would
    /// hand a receive-buffer chunk to `BoardConnection` — unsplit, for
    /// payloads already well under one MTU/socket-read.
    func pushIncoming(_ data: Data) {
        incomingContinuation?.yield(data)
    }

    /// Delivers `data` split into `chunkSize`-byte pieces (frame boundaries
    /// are *not* respected — a real BLE/TCP delivery doesn't know about them
    /// either), waiting `interChunkDelay` between pieces so the decoder's
    /// partial-buffering path and the probe's window bucketing both see a
    /// realistic wire cadence instead of "as fast as the test loop runs".
    func deliverIncoming(_ data: Data, chunkSize: Int, interChunkDelay: Duration) async {
        var idx = data.startIndex
        while idx < data.endIndex {
            let end = data.index(idx, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            incomingContinuation?.yield(data.subdata(in: idx..<end))
            idx = end
            if (idx < data.endIndex) && (interChunkDelay > .zero) {
                try? await Task.sleep(for: interChunkDelay)
            }
        }
    }

    /// Delay for one `chunkSize`-byte TCP socket read at a plausible
    /// throughput (default ~150 KB/s, within the brief's 100-200 KB/s range).
    static func tcpChunkDelay(chunkSize: Int, throughputBytesPerSecond: Double = 150_000) -> Duration {
        .seconds(Double(chunkSize) / throughputBytesPerSecond)
    }

    /// Sets the synthetic "saved faces" document `GET_FACES` round trips will
    /// serve from, for the large-document measurement scenario.
    func configureFacesFile(totalBytes: Int) {
        facesTotalBytes = Data((0..<totalBytes).map { UInt8(truncatingIfNeeded: $0) })
    }

    /// One `GET_FACES` round trip: `[gen: UInt32 LE][file bytes from
    /// offset]`, `FLAG_MORE` while more remain — the same shape
    /// `BoardConnection.getFaces()` (`aggregateMore: false`) expects, so this
    /// exercises the exact production request/reply flow instead of a
    /// synthetic MORE-aggregated single request. The reply frame itself is
    /// then TCP-paced like any other large reply here.
    private func replyToFacesRequest(_ request: RinaLinkFrame) async {
        guard let total = facesTotalBytes else { return }
        var offset = 0
        if let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
           let requestedOffset = object["offset"] as? Int {
            offset = requestedOffset
        }
        let end = min(offset + Self.facesChunkMaxPayload, total.count)
        var payload = Data()
        var genLE = facesGen.littleEndian
        withUnsafeBytes(of: &genLE) { payload.append(contentsOf: $0) }
        if offset < end { payload.append(total.subdata(in: offset..<end)) }
        let isMore = end < total.count
        guard let encoded = try? RinaLinkEncoder.encode(RinaLinkFrame(
            type: RinaLinkMessageType.getFaces.replyType, seq: request.seq,
            flags: isMore ? RinaLinkFrameConstants.flagMore : 0, payload: payload
        )) else { return }
        await deliverIncoming(encoded, chunkSize: 1400, interChunkDelay: Self.tcpChunkDelay(chunkSize: 1400))
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
