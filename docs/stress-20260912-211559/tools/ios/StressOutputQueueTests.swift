import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// P1-a output queue congestion through the app's real queue path
/// (setFrame -> framePump -> withOutput -> outputPump; command -> commandPump).
/// Host-run window: 2 s warmup + 10 s sample (direct) / 2 s + 5 s (ControlViewModel).
/// Fake board ACK latency: 8 ms.
@MainActor
final class StressOutputQueueTests: XCTestCase {
    static let ackDelayMs = 8.0

    nonisolated static func classify(_ error: Error) -> String {
        if (error as? RatePumpError) == .dropped { return "dropped" }
        if error is CancellationError { return "cancelled" }
        if case RinaTransportError.timeout? = error as? RinaTransportError { return "timeout" }
        return "error"
    }

    func testP1_a_DirectOutputQueueCongestion() async {
        let frameRates: [Double] = [10, 25, 50, 75, 100]
        let commandRates: [Double] = [2, 5, 8, 12, 20]
        for i in frameRates.indices {
            await directRun(frameHz: frameRates[i], commandHz: commandRates[i], warmup: 2, sample: 10)
        }
    }

    func testP1_a2_ControlViewModelLiveEditCongestion() async {
        for hz in [10.0, 25, 50, 75, 100] {
            await viewModelRun(hz: hz, warmup: 2, sample: 5)
        }
    }

    private func directRun(frameHz: Double, commandHz: Double, warmup: Double, sample: Double) async {
        let t = StressTransport()
        t.replyDelayMs = Self.ackDelayMs
        let c = await stressConnected(t)
        let token = c.output.begin(.video)
        let stop = StressBox(false)
        let frameOffer = StressBox([Int: UInt64]()), frameResult = StressBox([Int: String]())
        let cmdOffer = StressBox([Int: UInt64]()), cmdResult = StressBox([Int: String]())
        let maxQuarantined = StressBox(0), maxPending = StressBox(0)
        let runStart = Stress.nowNs()
        let sampleStart = runStart + UInt64(warmup * 1e9)
        let sampleEnd = sampleStart + UInt64(sample * 1e9)

        let frames = Task { @MainActor in
            let period = Duration.nanoseconds(Int64(1e9 / frameHz))
            var next = ContinuousClock.now
            var i = 0
            while !stop.value {
                let index = i
                frameOffer.value[index] = Stress.nowNs()
                var frame = PackedFrame()
                frame.set(index % 370)
                Task { @MainActor in
                    do {
                        _ = try await c.setFrame(frame, playback: .idle, reason: "f\(index)", outputSession: token)
                        frameResult.value[index] = "ok"
                    } catch {
                        frameResult.value[index] = Self.classify(error)
                    }
                }
                i += 1
                next = next.advanced(by: period)
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
        let commands = Task { @MainActor in
            let period = Duration.nanoseconds(Int64(1e9 / commandHz))
            var next = ContinuousClock.now
            var i = 0
            while !stop.value {
                let index = i
                cmdOffer.value[index] = Stress.nowNs()
                Task { @MainActor in
                    do {
                        _ = try await c.withOutput(token) { try await c.command(.scrollSeek(frameIndex: index)) }
                        cmdResult.value[index] = "ok"
                    } catch {
                        cmdResult.value[index] = Self.classify(error)
                    }
                }
                i += 1
                next = next.advanced(by: period)
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
        let sampler = Task { @MainActor in
            while !stop.value {
                maxQuarantined.value = max(maxQuarantined.value, Stress.quarantined(c).count)
                maxPending.value = max(maxPending.value, Stress.pendingCount(c))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: UInt64((warmup + sample) * 1e9))
        stop.value = true
        await frames.value
        await commands.value
        await sampler.value

        // Convergence: one uniquely marked final frame must be the last frame on the wire.
        var finalFrame = PackedFrame()
        finalFrame.set(369); finalFrame.set(0); finalFrame.set(123)
        let finalResult = StressBox<String?>(nil)
        let finalOffered = Stress.nowNs()
        Task { @MainActor in
            do {
                _ = try await c.setFrame(finalFrame, playback: .idle, reason: "FINAL", outputSession: token)
                finalResult.value = "ok"
            } catch {
                finalResult.value = Self.classify(error)
            }
        }
        _ = await Stress.wait(timeout: 6) { finalResult.value != nil }
        var lastCount = -1
        var quietSince = Stress.nowNs()
        _ = await Stress.wait(timeout: 6, poll: 20_000_000) {
            if t.writes.count != lastCount { lastCount = t.writes.count; quietSince = Stress.nowNs() }
            return Stress.ms(since: quietSince) > 400
        }
        _ = await Stress.wait(timeout: 8) {
            frameResult.value.count >= frameOffer.value.count && cmdResult.value.count >= cmdOffer.value.count
        }
        let finalLatencyMs = t.writes(of: .setFrame).first { Stress.setFrameReason($0.frame) == "FINAL" }
            .map { Double($0.atNs &- finalOffered) / 1e6 } ?? -1
        let lastReason = t.writes(of: .setFrame).last.map { Stress.setFrameReason($0.frame) } ?? "none"
        let converged = lastReason == "FINAL" && finalResult.value == "ok"

        func inSample(_ ns: UInt64) -> Bool { ns >= sampleStart && ns < sampleEnd }
        // Frames
        let frameIdx = frameOffer.value.filter { inSample($0.value) }.map(\.key)
        let frameSet = Set(frameIdx)
        var frameLat: [Double] = []
        var frameSent = 0
        for w in t.writes(of: .setFrame) {
            let reason = Stress.setFrameReason(w.frame)
            guard reason.hasPrefix("f"), let idx = Int(reason.dropFirst()), frameSet.contains(idx),
                  let offered = frameOffer.value[idx] else { continue }
            frameSent += 1
            frameLat.append(Double(w.atNs &- offered) / 1e6)
        }
        let fr = frameIdx.compactMap { frameResult.value[$0] }
        // Commands
        let cmdIdx = cmdOffer.value.filter { inSample($0.value) }.map(\.key)
        let cmdSet = Set(cmdIdx)
        var cmdLat: [Double] = []
        var cmdSent = 0
        for w in t.writes(of: .cmd) {
            guard let idx = Stress.json(w.frame)["frameIndex"] as? Int, cmdSet.contains(idx),
                  let offered = cmdOffer.value[idx] else { continue }
            cmdSent += 1
            cmdLat.append(Double(w.atNs &- offered) / 1e6)
        }
        let cr = cmdIdx.compactMap { cmdResult.value[$0] }
        func n(_ list: [String], _ key: String) -> Int { list.filter { $0 == key }.count }
        let frameP99 = Stress.percentile(frameLat, 99)
        let cmdP99 = Stress.percentile(cmdLat, 99)
        let hardErrors = n(fr, "timeout") + n(fr, "error") + n(cr, "timeout") + n(cr, "error")
        let pass = converged && hardErrors == 0 && frameP99 < 500 && cmdP99 < 1500
        Stress.record(case: "P1-a-direct-\(Int(frameHz))Hz-cmd\(Int(commandHz))Hz", layer: "BoardConnection framePump/commandPump/outputPump",
                      load: "frames \(Int(frameHz)) Hz + token commands \(Int(commandHz)) Hz, warmup \(Int(warmup))s sample \(Int(sample))s, ACK \(Int(Self.ackDelayMs)) ms",
                      status: pass ? "PASS" : "FAIL",
                      metrics: ["frame_offered": frameIdx.count, "frame_offered_hz": Double(frameIdx.count) / sample,
                                "frame_sent": frameSent, "frame_ok": n(fr, "ok"), "frame_dropped": n(fr, "dropped"),
                                "frame_cancelled": n(fr, "cancelled"), "frame_timeout": n(fr, "timeout"), "frame_error": n(fr, "error"),
                                "frame_lat_p50_ms": Stress.percentile(frameLat, 50), "frame_lat_p95_ms": Stress.percentile(frameLat, 95),
                                "frame_lat_p99_ms": frameP99, "frame_lat_max_ms": frameLat.max() ?? -1,
                                "cmd_offered": cmdIdx.count, "cmd_sent": cmdSent, "cmd_ok": n(cr, "ok"), "cmd_dropped": n(cr, "dropped"),
                                "cmd_cancelled": n(cr, "cancelled"), "cmd_timeout": n(cr, "timeout"), "cmd_error": n(cr, "error"),
                                "cmd_lat_p50_ms": Stress.percentile(cmdLat, 50), "cmd_lat_p95_ms": Stress.percentile(cmdLat, 95),
                                "cmd_lat_p99_ms": cmdP99, "cmd_lat_max_ms": cmdLat.max() ?? -1,
                                "max_quarantined_seqs": maxQuarantined.value, "max_pending": maxPending.value,
                                "final_frame_last_on_wire": lastReason == "FINAL", "final_result": finalResult.value ?? "nil",
                                "final_offer_to_wire_ms": finalLatencyMs],
                      evidence: "StressOutputQueueTests/testP1_a_DirectOutputQueueCongestion")
        XCTAssertTrue(converged, "\(frameHz) Hz: final frame not last on wire (last=\(lastReason), result=\(finalResult.value ?? "nil"))")
        XCTAssertEqual(hardErrors, 0, "\(frameHz) Hz: timeouts/errors under congestion")
        c.disconnect()
    }

    private func viewModelRun(hz: Double, warmup: Double, sample: Double) async {
        let t = StressTransport()
        t.replyDelayMs = Self.ackDelayMs
        let c = await stressConnected(t)
        let vm = ControlViewModel()
        vm.livePreview = true
        var offers: [String: [UInt64]] = [:]
        var offerTimes: [UInt64] = []
        var maxQuarantined = 0, maxPending = 0
        let runStart = Stress.nowNs()
        let sampleStart = runStart + UInt64(warmup * 1e9)
        let sampleEnd = sampleStart + UInt64(sample * 1e9)
        let period = Duration.nanoseconds(Int64(1e9 / hz))
        var next = ContinuousClock.now
        var i = 0
        var lastSampleNs = runStart
        while Stress.nowNs() < sampleEnd {
            vm.toggle(led: i % 370, connection: c)
            let now = Stress.nowNs()
            offers[vm.draftFrame.hex94, default: []].append(now)
            offerTimes.append(now)
            if Stress.ms(since: lastSampleNs) >= 100 {
                maxQuarantined = max(maxQuarantined, Stress.quarantined(c).count)
                maxPending = max(maxPending, Stress.pendingCount(c))
                lastSampleNs = Stress.nowNs()
            }
            i += 1
            next = next.advanced(by: period)
            try? await Task.sleep(until: next, clock: .continuous)
        }
        vm.toggle(led: 369, connection: c)
        vm.toggle(led: 1, connection: c)
        let finalHex = vm.draftFrame.hex94
        var lastCount = -1
        var quietSince = Stress.nowNs()
        _ = await Stress.wait(timeout: 6, poll: 20_000_000) {
            if t.writes.count != lastCount { lastCount = t.writes.count; quietSince = Stress.nowNs() }
            return Stress.ms(since: quietSince) > 400
        }
        let lastWireHex = t.writes(of: .setFrame).last.flatMap { Stress.setFramePacked($0.frame)?.hex94 } ?? "none"
        let converged = lastWireHex == finalHex
        let offered = offerTimes.filter { $0 >= sampleStart && $0 < sampleEnd }.count
        var latencies: [Double] = []
        for w in t.writes(of: .setFrame) where w.atNs >= sampleStart && w.atNs < sampleEnd {
            guard let hex = Stress.setFramePacked(w.frame)?.hex94,
                  let offer = offers[hex]?.last(where: { $0 <= w.atNs }) else { continue }
            latencies.append(Double(w.atNs &- offer) / 1e6)
        }
        let pass = converged && vm.errorMessage == nil && Stress.percentile(latencies, 99) < 500
        Stress.record(case: "P1-a-controlvm-\(Int(hz))Hz", layer: "ControlViewModel.pushLiveIfNeeded -> BoardConnection.setFrame",
                      load: "toggle(led:) at \(Int(hz)) Hz (cancel-previous producer), warmup \(Int(warmup))s sample \(Int(sample))s, ACK \(Int(Self.ackDelayMs)) ms",
                      status: pass ? "PASS" : "FAIL",
                      metrics: ["offered": offered, "offered_hz": Double(offered) / sample, "sent": latencies.count,
                                "not_sent_dropped_or_cancelled": max(0, offered - latencies.count),
                                "lat_p50_ms": Stress.percentile(latencies, 50), "lat_p95_ms": Stress.percentile(latencies, 95),
                                "lat_p99_ms": Stress.percentile(latencies, 99), "lat_max_ms": latencies.max() ?? -1,
                                "max_quarantined_seqs": maxQuarantined, "max_pending": maxPending,
                                "converged_last_wire_is_final_edit": converged, "error_message": vm.errorMessage ?? "nil"],
                      evidence: "StressOutputQueueTests/testP1_a2_ControlViewModelLiveEditCongestion")
        XCTAssertTrue(converged, "\(hz) Hz: board does not end on the latest edit")
        c.disconnect()
    }
}
