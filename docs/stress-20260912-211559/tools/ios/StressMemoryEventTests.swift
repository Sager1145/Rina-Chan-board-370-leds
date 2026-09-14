import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// P0-3 MORE aggregation / GET_FACES paging, P0-4 slow event subscriber.
@MainActor
final class StressMemoryEventTests: XCTestCase {
    // MARK: P0-3

    func testP0_3_MoreAggregationWithoutTerminalFrame() async {
        for mib in [1, 4, 16] {
            await aggregation(mib: mib)
        }
    }

    private func aggregation(mib: Int) async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        let fragments = (mib << 20) / 4096
        let timeout: TimeInterval = 8
        let outcome = StressBox<String?>(nil)
        let baseFoot = Stress.footprintBytes()
        let baseRSS = Stress.residentBytes()
        let requestStart = Stress.nowNs()
        let request = Task { @MainActor in
            do {
                _ = try await c.send(type: .getStatus, payload: Data(), timeout: timeout)
                outcome.value = "completed"
            } catch RinaTransportError.timeout {
                outcome.value = "timeout"
            } catch {
                outcome.value = "error:\(error)"
            }
        }
        _ = await Stress.wait(timeout: 1) { !t.held.isEmpty }
        guard let r = t.takeHeld({ _ in true }) else { return XCTFail("request not written") }
        let wire = RinaLinkEncoder.encode(RinaLinkFrame(type: r.type | 0x80, seq: r.seq,
                                                        flags: RinaLinkFrameConstants.flagMore,
                                                        payload: Data(repeating: 0x41, count: 4096)))
        var fed = 0
        var peakFoot = baseFoot
        var peakRSS = baseRSS
        var mibMarks: [String] = []
        let ingestStart = Stress.nowNs()
        var lastMark = ingestStart
        while fed < fragments, outcome.value == nil {
            let batch = min(64, fragments - fed)
            var data = Data(capacity: batch * wire.count)
            for _ in 0..<batch { data.append(wire) }
            t.injectRaw(data)
            fed += batch
            let target = fed * 4096
            _ = await Stress.wait(timeout: timeout + 1, poll: 200_000) {
                outcome.value != nil || Stress.accumulatedBytes(c) >= target
            }
            peakFoot = max(peakFoot, Stress.footprintBytes())
            peakRSS = max(peakRSS, Stress.residentBytes())
            if fed % 256 == 0 {
                mibMarks.append(String(format: "%.0f", Stress.ms(since: lastMark)))
                lastMark = Stress.nowNs()
            }
        }
        let accumulatedAtEnd = Stress.accumulatedBytes(c)
        let ingestMs = Stress.ms(since: ingestStart)
        let ingestComplete = accumulatedAtEnd >= fragments * 4096
        _ = await Stress.wait(timeout: timeout + 2) { outcome.value != nil }
        await request.value
        let resolvedAfterS = Stress.ms(since: requestStart) / 1000
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterFoot = Stress.footprintBytes()
        let afterRSS = Stress.residentBytes()
        let pendingAfter = Stress.pendingCount(c)
        let released = Stress.accumulatedBytes(c) <= 0 && pendingAfter == 0
        // Expectation: a bounded aggregation buffer (brief mentions 64 MiB) and
        // linear ingest. Status reflects release-after-timeout + no unbounded growth
        // below the brief's cap; ingest cost is reported as a metric.
        let pass = released && outcome.value == "timeout"
        Stress.record(case: "P0-3-more-aggregation-\(mib)MiB", layer: "BoardConnection.route MORE",
                      load: "\(fragments) x 4096B MORE fragments, no terminal, timeout \(Int(timeout))s",
                      status: pass ? "PASS" : "FAIL",
                      metrics: ["fragments_fed": fed, "ingest_complete_before_timeout": ingestComplete,
                                "accumulated_bytes_peak": accumulatedAtEnd, "ingest_ms": ingestMs,
                                "ingest_ms_per_mib_series": mibMarks.joined(separator: "|"),
                                "outcome": outcome.value ?? "nil", "resolved_after_s": resolvedAfterS,
                                "footprint_base_mib": Stress.mib(baseFoot), "footprint_peak_mib": Stress.mib(peakFoot),
                                "footprint_after_mib": Stress.mib(afterFoot),
                                "rss_base_mib": Stress.mib(baseRSS), "rss_peak_mib": Stress.mib(peakRSS),
                                "rss_after_mib": Stress.mib(afterRSS), "pending_after": pendingAfter,
                                "released": released],
                      evidence: "StressMemoryEventTests/testP0_3_MoreAggregationWithoutTerminalFrame")
        XCTAssertTrue(released, "\(mib) MiB: accumulated buffer not released")
        c.disconnect()
    }

    func testP0_3b_GetFacesPagingWithoutEnd() async {
        for variant in ["advancing", "stalled"] {
            let t = StressTransport()
            let c = await stressConnected(t)
            let trips = StressBox(0)
            t.responder = { frame in
                guard frame.type == RinaLinkMessageType.getFaces.rawValue else { return nil }
                trips.value += 1
                var payload = Data([1, 0, 0, 0])
                if variant == "advancing" { payload.append(Data(repeating: 0x7B, count: 4092)) }
                return [RinaLinkFrame(type: frame.type | 0x80, seq: frame.seq, flags: RinaLinkFrameConstants.flagMore, payload: payload)]
            }
            let baseFoot = Stress.footprintBytes()
            let result = StressBox<String?>(nil)
            let start = Stress.nowNs()
            let task = Task { @MainActor in
                do {
                    let data = try await c.getFaces()
                    result.value = "returned:\(data.count)"
                } catch is CancellationError {
                    result.value = "cancelled"
                } catch {
                    result.value = "error:\(error)"
                }
            }
            let window: TimeInterval = 4
            _ = await Stress.wait(timeout: window, poll: 5_000_000) { result.value != nil || trips.value >= 5000 }
            let tripsAtWatchdog = trips.value
            let secondsAtWatchdog = Stress.ms(since: start) / 1000
            let footAtWatchdog = Stress.footprintBytes()
            let runningAtWatchdog = result.value == nil
            let offsets = t.writes(of: .getFaces).suffix(3).map { Stress.json($0.frame)["offset"] as? Int ?? -1 }
            task.cancel()
            let cancelled = await Stress.wait(timeout: 2) { result.value != nil }
            let pass = !runningAtWatchdog
            Stress.record(case: "P0-3b-getfaces-paging-\(variant)", layer: "BoardConnection.getFaces",
                          load: "board sets MORE on every page (\(variant == "advancing" ? "4092B/page" : "0B/page, offset never advances"))",
                          status: pass ? "PASS" : "FAIL",
                          metrics: ["round_trips": tripsAtWatchdog, "seconds": secondsAtWatchdog,
                                    "still_looping_at_watchdog": runningAtWatchdog,
                                    "last_offsets": offsets.map(String.init).joined(separator: "|"),
                                    "footprint_delta_mib": Stress.mibDelta(baseFoot, footAtWatchdog),
                                    "stopped_by_cancel": cancelled, "final": result.value ?? "nil"],
                          evidence: "StressMemoryEventTests/testP0_3b_GetFacesPagingWithoutEnd")
            XCTAssertFalse(runningAtWatchdog, "getFaces (\(variant)) never terminates on its own: \(tripsAtWatchdog) round trips")
            c.disconnect()
        }
    }

    // MARK: P0-4

    func testP0_4_SlowEventSubscriber() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        let n = 50_000
        let filler = String(repeating: "x", count: 160)

        func pump(_ range: Range<Int>) async -> Bool {
            var i = range.lowerBound
            while i < range.upperBound {
                let end = min(range.upperBound, i + 500)
                var data = Data()
                for k in i..<end {
                    let payload = Data("{\"level\":\"I\",\"tag\":\"s\",\"msg\":\"\(k)-\(filler)\"}".utf8)
                    data.append(RinaLinkEncoder.encode(RinaLinkFrame(type: RinaLinkMessageType.evLog.rawValue, seq: 0, flags: 0, payload: payload)))
                }
                t.injectRaw(data)
                let marker = "\(end - 1)-"
                _ = await Stress.wait(timeout: 10, poll: 200_000) { c.lastLog?.msg?.hasPrefix(marker) == true }
                i = end
            }
            return c.lastLog?.msg?.hasPrefix("\(range.upperBound - 1)-") == true
        }

        // Control: no subscriber.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let f0 = Stress.footprintBytes()
        let controlOK = await pump(0..<n)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let f1 = Stress.footprintBytes()

        // Paused subscriber: holds the stream, never iterates.
        var sub: (id: UUID, stream: AsyncStream<BoardEvent>)? = c.subscribeToEvents()
        let pumpStart = Stress.nowNs()
        let pausedOK = await pump(n..<(2 * n))
        let pumpMs = Stress.ms(since: pumpStart)
        let f2 = Stress.footprintBytes()
        let r2 = Stress.residentBytes()

        // Resume: drain everything that was buffered.
        let drained = StressBox(0)
        if let stream = sub?.stream {
            let drainTask = Task { @MainActor in
                for await _ in stream {
                    drained.value += 1
                    if drained.value >= n { break }
                }
            }
            _ = await Stress.wait(timeout: 15) { drained.value >= n }
            drainTask.cancel()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let f3 = Stress.footprintBytes()
        let subscribersAfterBreak = Stress.eventSubscriberCount(c)
        if let id = sub?.id { c.unsubscribe(id) }
        sub = nil

        // Unsubscribe while buffered, then check iteration terminates and memory is released.
        var sub2: (id: UUID, stream: AsyncStream<BoardEvent>)? = c.subscribeToEvents()
        _ = await pump((2 * n)..<(3 * n))
        let f4 = Stress.footprintBytes()
        if let id = sub2?.id { c.unsubscribe(id) }
        let subscribersAfterUnsubscribe = Stress.eventSubscriberCount(c)
        _ = await pump((3 * n)..<(3 * n + 1000))
        let drained2 = StressBox(0)
        let ended = StressBox(false)
        var iterTask: Task<Void, Never>?
        if let stream = sub2?.stream {
            iterTask = Task { @MainActor in
                for await _ in stream { drained2.value += 1 }
                ended.value = true
            }
        }
        _ = await Stress.wait(timeout: 3) { ended.value }
        let terminatedAfterUnsubscribe = ended.value
        let drainedAfterUnsubscribe = drained2.value
        iterTask?.cancel()
        _ = await Stress.wait(timeout: 1) { ended.value }
        sub2 = nil
        iterTask = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        let f5 = Stress.footprintBytes()

        let perEventBytes = (Double(f2) - Double(f1)) / Double(n)
        let pass = controlOK && pausedOK && drained.value >= n && terminatedAfterUnsubscribe
        Stress.record(case: "P0-4-slow-event-subscriber", layer: "BoardConnection.events AsyncStream",
                      load: "\(n) EV_LOG (~200B) per phase, subscriber paused then resumed; unsubscribe while buffered",
                      status: pass ? "PASS" : "FAIL",
                      metrics: ["control_footprint_delta_mib": Stress.mibDelta(f0, f1),
                                "paused_footprint_delta_mib": Stress.mibDelta(f1, f2),
                                "paused_rss_mib": Stress.mib(r2),
                                "approx_bytes_per_buffered_event": perEventBytes,
                                "pump_ms": pumpMs,
                                "drained_after_resume": drained.value, "dropped": max(0, n - drained.value),
                                "footprint_after_drain_delta_mib": Stress.mibDelta(f1, f3),
                                "subscribers_after_break": subscribersAfterBreak,
                                "footprint_buffered_before_unsubscribe_delta_mib": Stress.mibDelta(f3, f4),
                                "subscribers_after_unsubscribe": subscribersAfterUnsubscribe,
                                "iteration_terminated_after_unsubscribe": terminatedAfterUnsubscribe,
                                "elements_drained_after_unsubscribe": drainedAfterUnsubscribe,
                                "footprint_after_release_delta_mib": Stress.mibDelta(f3, f5)],
                      evidence: "StressMemoryEventTests/testP0_4_SlowEventSubscriber")
        XCTAssertGreaterThanOrEqual(drained.value, n, "events were dropped for a slow subscriber")
        XCTAssertTrue(terminatedAfterUnsubscribe, "stream iteration never finishes after unsubscribe(_:)")
        c.disconnect()
    }
}
