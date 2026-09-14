import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// P0-0 constants, P0-1 sequence exhaustion, P0-2 late/stale replies.
@MainActor
final class StressSequenceTests: XCTestCase {
    // MARK: P0-0

    func testP0_0_ConstantsMatchBrief() {
        let connection = BoardConnection()
        func pump(_ name: String) -> (interval: Double, depth: Int) {
            guard let pump = Stress.reflect(connection, name) else { return (-1, -1) }
            return (Stress.reflect(pump, "minInterval") as? TimeInterval ?? -1, Stress.reflect(pump, "depth") as? Int ?? -1)
        }
        let frame = pump("framePump"), command = pump("commandPump"), blob = pump("blobPump"), output = pump("outputPump")
        let handshake = Stress.reflect(connection, "handshakeTimeout") as? TimeInterval ?? -1
        let maxReconnect = Stress.reflect(connection, "maxReconnectAttempts") as? Int ?? -1
        let labels = Mirror(reflecting: connection).children.compactMap(\.label)
        let capLike = labels.filter { $0.lowercased().contains("cap") || $0.lowercased().contains("maxaccum") || $0.lowercased().contains("limit") }
        let ok = frame == (0.020, 6) && command == (0.120, 4) && blob == (0, 4) && output == (0, 64) && handshake == 5
        Stress.record(case: "P0-0-constants", layer: "BoardConnection", load: "static", status: ok ? "PASS" : "FAIL",
                      metrics: ["frame_ms": frame.interval * 1000, "frame_depth": frame.depth,
                                "command_ms": command.interval * 1000, "command_depth": command.depth,
                                "blob_ms": blob.interval * 1000, "blob_depth": blob.depth,
                                "output_ms": output.interval * 1000, "output_depth": output.depth,
                                "handshake_timeout_s": handshake, "max_reconnect_attempts": maxReconnect,
                                "more_cap_properties": capLike.isEmpty ? "none" : capLike.joined(separator: "|")],
                      evidence: "StressSequenceTests/testP0_0_ConstantsMatchBrief")
        XCTAssertTrue(ok)
    }

    // MARK: P0-1

    func testP0_1_SequenceExhaustion() async {
        for n in [254, 255, 256, 512] {
            await exhaustion(outstanding: n)
        }
    }

    private func exhaustion(outstanding n: Int) async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        let startSeq = Stress.nextSeq(c)
        let completions = StressBox([Int: Int]())
        let outcomes = StressBox([Int: String]())
        var tasks: [Task<Void, Never>] = []
        for i in 0..<n {
            let tag = Data("req-\(i)".utf8)
            tasks.append(Task { @MainActor in
                do {
                    let reply = try await c.send(type: .ping, payload: tag, timeout: 2.0)
                    outcomes.value[i] = reply.payload == tag ? "match" : "mismatch"
                } catch RinaTransportError.timeout {
                    outcomes.value[i] = "timeout"
                } catch is CancellationError {
                    outcomes.value[i] = "cancelled"
                } catch {
                    outcomes.value[i] = "error"
                }
                completions.value[i, default: 0] += 1
            })
        }
        let allWritten = await Stress.wait(timeout: 3) { t.writes(of: .ping).count >= n }
        let seqs = t.writes(of: .ping).map(\.frame.seq)
        let distinct = Set(seqs).count
        let pendingAfterIssue = Stress.pendingCount(c)
        // The board answers every request it received, in arrival order, echoing the payload.
        t.replyAllHeld()
        _ = await Stress.wait(timeout: 3.5) { completions.value.count >= n }
        let completed = completions.value.count
        let doubleResumes = completions.value.values.filter { $0 > 1 }.count
        let values = Array(outcomes.value.values)
        let mismatched = values.filter { $0 == "mismatch" }.count
        let matched = values.filter { $0 == "match" }.count
        let timeouts = values.filter { $0 == "timeout" }.count
        let hung = n - completed
        if hung > 0 {
            for (i, task) in tasks.enumerated() where completions.value[i] == nil { task.cancel() }
            _ = await Stress.wait(timeout: 1.0) { completions.value.count >= n }
        }
        let hungAfterCancel = n - completions.value.count
        c.disconnect()
        _ = await Stress.wait(timeout: 0.5) { completions.value.count >= n }
        let hungAfterDisconnect = n - completions.value.count
        let pass = allWritten && completed == n && mismatched == 0 && doubleResumes == 0 && distinct == seqs.count
        Stress.record(case: "P0-1-seq-exhaustion-\(n)", layer: "BoardConnection.nextSequenceNumber",
                      load: "\(n) concurrent PING, replies withheld", status: pass ? "PASS" : "FAIL",
                      metrics: ["outstanding": n, "start_seq": Int(startSeq), "written": seqs.count,
                                "distinct_seqs": distinct, "duplicate_seq_writes": seqs.count - distinct,
                                "pending_after_issue": pendingAfterIssue, "completed": completed,
                                "matched": matched, "mismatched_payload": mismatched, "timeouts": timeouts,
                                "double_resumes": doubleResumes, "hung": hung,
                                "hung_after_task_cancel": hungAfterCancel,
                                "hung_after_disconnect": hungAfterDisconnect],
                      evidence: "StressSequenceTests/testP0_1_SequenceExhaustion")
        XCTAssertEqual(completed, n, "n=\(n): every request must complete exactly once")
        XCTAssertEqual(mismatched, 0, "n=\(n): a reply was delivered to a different request")
        XCTAssertEqual(distinct, seqs.count, "n=\(n): an in-flight seq was reused")
    }

    // MARK: P0-2

    /// Moves `nextSeq` so that the next allocated candidate is `target`.
    private func burn(_ c: BoardConnection, _ t: StressTransport, until target: UInt8, limit: Int = 600) async -> Int {
        let wasAuto = t.autoReply
        t.autoReply = true
        defer { t.autoReply = wasAuto }
        var count = 0
        while Stress.nextSeq(c) != target, count < limit {
            _ = try? await c.send(type: .ping, payload: Data(), timeout: 1)
            count += 1
        }
        return count
    }

    func testP0_2_LateRepliesAcrossQuarantineAndWrap() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        let delays: [Double] = [0.1, 0.5, 1.0, 1.5, 1.8, 2.2, 2.6, 3.0]
        var rows: [String] = []
        var deliveredInsideWindow = 0
        var deliveredAfterWindow = 0
        var wraps = 0
        for mode in ["timeout", "cancel"] {
            for delay in delays {
                t.autoReply = false
                let oldTag = Data("OLD-\(mode)-\(delay)".utf8)
                let old = Task { @MainActor () -> String in
                    do {
                        _ = try await c.send(type: .ping, payload: oldTag, timeout: mode == "timeout" ? 0.15 : 30)
                        return "completed"
                    } catch RinaTransportError.timeout {
                        return "timeout"
                    } catch is CancellationError {
                        return "cancelled"
                    } catch {
                        return "error"
                    }
                }
                _ = await Stress.wait(timeout: 1) { t.held.contains { $0.payload == oldTag } }
                guard let oldRequest = t.takeHeld({ $0.payload == oldTag }) else {
                    XCTFail("old request not written")
                    continue
                }
                if mode == "cancel" { old.cancel() }
                _ = await old.value
                let failedAt = Stress.nowNs()
                wraps += await burn(c, t, until: oldRequest.seq) > 0 ? 1 : 0
                let remaining = delay - Stress.ms(since: failedAt) / 1000
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                t.autoReply = false
                let newTag = Data("NEW-\(mode)-\(delay)".utf8)
                let fresh = Task { @MainActor () -> Data? in
                    try? await c.send(type: .ping, payload: newTag, timeout: 1.0).payload
                }
                _ = await Stress.wait(timeout: 1) { t.held.contains { $0.payload == newTag } }
                let newSeq = t.held.first { $0.payload == newTag }?.seq
                let actualDelay = Stress.ms(since: failedAt) / 1000
                let stillQuarantined = Stress.quarantined(c).contains(oldRequest.seq)
                t.reply(to: oldRequest, payload: oldTag) // the stale reply
                try? await Task.sleep(nanoseconds: 30_000_000)
                t.replyHeld({ $0.payload == newTag })
                let got = await fresh.value
                let stale = got == oldTag
                if stale {
                    if actualDelay < 2.0 { deliveredInsideWindow += 1 } else { deliveredAfterWindow += 1 }
                }
                rows.append("\(mode)@\(String(format: "%.2f", actualDelay))s:sameSeq=\(newSeq == oldRequest.seq),q=\(stillQuarantined),stale=\(stale)")
            }
        }
        let pass = deliveredInsideWindow == 0 && deliveredAfterWindow == 0
        Stress.record(case: "P0-2-late-reply-quarantine", layer: "BoardConnection.route/quarantine",
                      load: "2 modes x 8 delays, seq forced to wrap onto stale seq", status: pass ? "PASS" : "FAIL",
                      metrics: ["stale_delivered_inside_2s": deliveredInsideWindow,
                                "stale_delivered_after_2s": deliveredAfterWindow,
                                "cycles_with_wrap": wraps, "rows": rows.joined(separator: " ")],
                      evidence: "StressSequenceTests/testP0_2_LateRepliesAcrossQuarantineAndWrap")
        XCTAssertEqual(deliveredInsideWindow, 0, "stale reply completed a new request inside quarantine")
        XCTAssertEqual(deliveredAfterWindow, 0, "stale reply completed a new request after quarantine expiry: \(rows)")
        c.disconnect()
    }

    func testP0_2b_LateReplyAcrossDisconnectReconnect() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        let oldTag = Data("OLD-LINK".utf8)
        let old = Task { @MainActor () -> String in
            do { _ = try await c.send(type: .ping, payload: oldTag, timeout: 30); return "completed" }
            catch { return "\(error)" }
        }
        _ = await Stress.wait(timeout: 1) { t.held.contains { $0.payload == oldTag } }
        guard let oldRequest = t.takeHeld({ $0.payload == oldTag }) else { return XCTFail("not written") }
        let oldStream = t.currentIncoming
        t.autoReply = true
        let disconnectedAt = Stress.nowNs()
        t.emit(.disconnected)
        let oldResult = await old.value
        let reconnected = await Stress.wait(timeout: 3) { c.connectionState == .connected }
        let quarantinedAfterReconnect = Stress.quarantined(c).contains(oldRequest.seq)
        _ = await burn(c, t, until: oldRequest.seq)
        t.autoReply = false

        // (i) stale reply on the severed link's stream.
        let tagA = Data("NEW-A".utf8)
        let doneA = StressBox<Data?>(nil)
        let a = Task { @MainActor in doneA.value = (try? await c.send(type: .ping, payload: tagA, timeout: 1.5).payload) ?? Data("err".utf8) }
        _ = await Stress.wait(timeout: 1) { t.held.contains { $0.payload == tagA } }
        let seqA = t.held.first { $0.payload == tagA }?.seq
        oldStream?.yield(RinaLinkEncoder.encode(RinaLinkFrame(type: oldRequest.type | 0x80, seq: oldRequest.seq, flags: 0, payload: oldTag)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let oldStreamDelivered = doneA.value == oldTag
        // (ii) stale reply for the same seq/type arriving on the new link.
        t.reply(to: oldRequest, payload: oldTag)
        try? await Task.sleep(nanoseconds: 30_000_000)
        t.replyHeld({ $0.payload == tagA })
        await a.value
        let newLinkDelivered = doneA.value == oldTag
        let elapsed = Stress.ms(since: disconnectedAt) / 1000
        let pass = !oldStreamDelivered && !newLinkDelivered
        Stress.record(case: "P0-2b-late-reply-across-reconnect", layer: "BoardConnection.failAllPending/route",
                      load: "1 in-flight PING, carrier drop, same transport reconnect, seq wrapped onto old seq",
                      status: pass ? "PASS" : "FAIL",
                      metrics: ["old_result": oldResult, "reconnected": reconnected,
                                "old_seq": Int(oldRequest.seq), "new_seq": Int(seqA ?? 0),
                                "old_seq_quarantined_after_reconnect": quarantinedAfterReconnect,
                                "stale_on_old_stream_delivered": oldStreamDelivered,
                                "stale_on_new_link_delivered": newLinkDelivered,
                                "seconds_since_disconnect": elapsed],
                      evidence: "StressSequenceTests/testP0_2b_LateReplyAcrossDisconnectReconnect")
        XCTAssertFalse(oldStreamDelivered)
        XCTAssertFalse(newLinkDelivered, "reply from the previous link completed a request on the new link")
        c.disconnect()
    }

    func testP0_2c_DefaultRequestTimeoutIsFiveSeconds() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        let start = Stress.nowNs()
        var result = ""
        do { _ = try await c.send(type: .ping, payload: Data()) } catch { result = "\(error)" }
        let elapsed = Stress.ms(since: start) / 1000
        let pass = result.contains("timeout") && elapsed > 4.8 && elapsed < 5.8
        Stress.record(case: "P0-2c-default-timeout", layer: "BoardConnection.send", load: "1 PING withheld",
                      status: pass ? "PASS" : "FAIL", metrics: ["elapsed_s": elapsed, "error": result],
                      evidence: "StressSequenceTests/testP0_2c_DefaultRequestTimeoutIsFiveSeconds")
        XCTAssertTrue(pass)
        c.disconnect()
    }
}
