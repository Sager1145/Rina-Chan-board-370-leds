import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// P1-b transport faults, P1-d BLOB begin/chunk/end/abort faults.
@MainActor
final class StressFaultBlobTests: XCTestCase {
    private func lit(_ led: Int) -> PackedFrame { var f = PackedFrame(); f.set(led); return f }

    // MARK: P1-b

    func testP1_b1_NotWritableFailsFastAndNextRequestSucceeds() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.pendingFault = (types: [RinaLinkMessageType.setFrame.rawValue], fault: .throwBeforeWrite)
        let token = c.output.begin(.manual)
        let start = Stress.nowNs()
        var error = "none"
        do { _ = try await c.setFrame(lit(1), playback: .idle, reason: "b1", outputSession: token) } catch let e { error = "\(e)" }
        let failMs = Stress.ms(since: start)
        let pendingAfter = Stress.pendingCount(c)
        let nextOK = (try? await c.setFrame(lit(2), playback: .idle, reason: "b1-next", outputSession: token)) != nil
        let wire = t.writes(of: .setFrame).map { Stress.setFrameReason($0.frame) }
        let pass = error.contains("notConnected") && failMs < 500 && pendingAfter == 0 && nextOK && wire == ["b1-next"]
        Stress.record(case: "P1-b1-not-writable", layer: "BoardConnection.sendUnqueued sendTask error path",
                      load: "1 setFrame, transport throws before first byte", status: pass ? "PASS" : "FAIL",
                      metrics: ["error": error, "fail_ms": failMs, "pending_after": pendingAfter, "next_ok": nextOK,
                                "wire": wire.joined(separator: "|")],
                      evidence: "StressFaultBlobTests/testP1_b1_NotWritableFailsFastAndNextRequestSucceeds")
        XCTAssertTrue(pass)
        c.disconnect()
    }

    func testP1_b2_ZeroWriteTimesOutAndNextRequestSucceeds() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.pendingFault = (types: [RinaLinkMessageType.ping.rawValue], fault: .silentDrop)
        let start = Stress.nowNs()
        var error = "none"
        do { _ = try await c.send(type: .ping, payload: Data("b2".utf8), timeout: 0.3) } catch let e { error = "\(e)" }
        let failMs = Stress.ms(since: start)
        let next = try? await c.send(type: .ping, payload: Data("b2-next".utf8), timeout: 1)
        let pass = error.contains("timeout") && failMs < 600 && next?.payload == Data("b2-next".utf8) && Stress.pendingCount(c) == 0
        Stress.record(case: "P1-b2-zero-write", layer: "BoardConnection timeout path",
                      load: "transport reports success, 0 bytes reach board", status: pass ? "PASS" : "FAIL",
                      metrics: ["error": error, "fail_ms": failMs, "next_ok": next != nil],
                      evidence: "StressFaultBlobTests/testP1_b2_ZeroWriteTimesOutAndNextRequestSucceeds")
        XCTAssertTrue(pass)
        c.disconnect()
    }

    /// Transport contract probe: after a transport reports a partial write,
    /// does BoardConnection keep writing into the poisoned byte stream?
    func testP1_b3_ShortWriteLeavesPartialFrameOnSameLink() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.pendingFault = (types: [RinaLinkMessageType.setFrame.rawValue], fault: .shortWrite(10))
        let token = c.output.begin(.manual)
        var firstError = "none"
        do { _ = try await c.setFrame(lit(3), playback: .idle, reason: "b3-partial", outputSession: token) } catch { firstError = "\(error)" }
        let nextStart = Stress.nowNs()
        var nextError = "ok"
        do { _ = try await c.setFrame(lit(4), playback: .idle, reason: "b3-next", outputSession: token) } catch { nextError = "\(error)" }
        let nextMs = Stress.ms(since: nextStart)
        let thirdOK = (try? await c.setFrame(lit(5), playback: .idle, reason: "b3-third", outputSession: token)) != nil
        let reasons = t.writes(of: .setFrame).map { Stress.setFrameReason($0.frame) }
        let parsedTypes = t.writes.map { String(format: "%02x", $0.frame.type) }
        let nextIntact = reasons.contains("b3-next")
        let pass = nextIntact && nextError == "ok"
        Stress.record(case: "P1-b3-short-write", layer: "BoardConnection over RinaTransport contract",
                      load: "setFrame: 10 of 59 bytes written then error; next 2 frames on same link",
                      status: pass ? "PASS" : "FAIL",
                      metrics: ["first_error": firstError, "next_result": nextError, "next_ms": nextMs,
                                "next_frame_intact_on_board": nextIntact, "third_ok": thirdOK,
                                "board_parsed_types": parsedTypes.joined(separator: "|"),
                                "reconnects_after_fault": t.connectCount - 1, "note": "BoardConnection has no resync/reset after a transport write error; real BLETransport disconnects on partial-packet timeout (BLETransport.swift:532), TCP writes are atomic"],
                      evidence: "StressFaultBlobTests/testP1_b3_ShortWriteLeavesPartialFrameOnSameLink")
        c.disconnect()
    }

    func testP1_b4_DisconnectMidFrameResumesAllPendingOnceAndStartsCleanFrame() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        let done = StressBox([Int: [String]]())
        for i in 0..<20 {
            Task { @MainActor in
                do { _ = try await c.send(type: .getStatus, payload: Data(), timeout: 10); done.value[i, default: []].append("ok") }
                catch { done.value[i, default: []].append("\(error)") }
            }
        }
        _ = await Stress.wait(timeout: 2) { t.held.count >= 20 }
        t.autoReply = true
        t.pendingFault = (types: [RinaLinkMessageType.setFrame.rawValue], fault: .disconnectMidFrame(7))
        let token = c.output.begin(.manual)
        let faultAt = Stress.nowNs()
        var frameError = "none"
        do { _ = try await c.setFrame(lit(6), playback: .idle, reason: "b4-cut", outputSession: token) } catch { frameError = "\(error)" }
        let allResumed = await Stress.wait(timeout: 2) { done.value.count >= 20 }
        let resumeMs = Stress.ms(since: faultAt)
        let multi = done.value.values.filter { $0.count > 1 }.count
        let errors = Set(done.value.values.flatMap { $0 })
        let reconnected = await Stress.wait(timeout: 3) { c.connectionState == .connected }
        let firstAfterReconnect = t.connectWriteIndex.last.flatMap { $0 < t.writes.count ? t.writes[$0].frame.type : nil }
        let newToken = c.output.begin(.manual)
        let afterOK = (try? await c.setFrame(lit(7), playback: .idle, reason: "b4-after", outputSession: newToken)) != nil
        let pass = allResumed && multi == 0 && reconnected && firstAfterReconnect == RinaLinkMessageType.ping.rawValue && afterOK
        Stress.record(case: "P1-b4-disconnect-mid-frame", layer: "BoardConnection.handleTransportState/failAllPending",
                      load: "20 outstanding GET_STATUS + setFrame cut after 7 bytes with carrier drop",
                      status: pass ? "PASS" : "FAIL",
                      metrics: ["frame_error": frameError, "all_pending_resumed": allResumed, "resume_ms": resumeMs,
                                "multi_resumed": multi, "pending_errors": errors.sorted().joined(separator: "|"),
                                "reconnected": reconnected,
                                "first_frame_after_reconnect_type": firstAfterReconnect.map { String(format: "%02x", $0) } ?? "none",
                                "set_frame_after_reconnect_ok": afterOK],
                      evidence: "StressFaultBlobTests/testP1_b4_DisconnectMidFrameResumesAllPendingOnceAndStartsCleanFrame")
        XCTAssertTrue(pass)
        c.disconnect()
    }

    func testP1_b5_ConcurrentChunkedWritesNeverInterleave() async {
        var rng = StressRNG(seed: 0xB5)
        for serialize in [true, false] {
            let t = StressTransport()
            let c = await stressConnected(t)
            t.chunkedWriteBytes = 20
            t.serializeWrites = serialize
            // 200 < 255 usable seqs, so P0-1 sequence exhaustion cannot confound this case.
            let n = 200
            let results = StressBox([Int: String]())
            var tags: [Int: Data] = [:]
            for i in 0..<n {
                let size = Int.random(in: 30...300, using: &rng)
                var tag = Data("i\(i):".utf8)
                tag.append(Data(repeating: UInt8(i % 251), count: size))
                tags[i] = tag
                Task { @MainActor in
                    do {
                        let reply = try await c.send(type: .ping, payload: tag, timeout: 1.5)
                        results.value[i] = reply.payload == tag ? "ok" : "mismatch"
                    } catch {
                        results.value[i] = StressOutputQueueTests.classify(error)
                    }
                }
            }
            _ = await Stress.wait(timeout: 5) { results.value.count >= n }
            let valid = t.writes.filter { w in
                let bytes = [UInt8](w.frame.payload)
                guard w.frame.type == RinaLinkMessageType.ping.rawValue, bytes.first == 0x69,
                      let colon = bytes.prefix(8).firstIndex(of: 0x3A),
                      let idx = Int(String(decoding: bytes[1..<colon], as: UTF8.self)) else { return false }
                return tags[idx] == w.frame.payload
            }.count
            let garbage = t.writes.count - valid
            let values = Array(results.value.values)
            func k(_ s: String) -> Int { values.filter { $0 == s }.count }
            let pass: Bool
            let caseID: String
            if serialize {
                caseID = "P1-b5-chunked-writes-serialized"
                pass = garbage == 0 && k("mismatch") == 0 && k("timeout") == 0 && k("ok") + k("dropped") == n
            } else {
                // Control: proves the board-side parser detects interleaving when the
                // transport does not serialize (BoardConnection itself does not).
                caseID = "P1-b5-chunked-writes-unserialized-control"
                pass = garbage > 0 || k("timeout") > 0
            }
            Stress.record(case: caseID, layer: serialize ? "RatePump-serialized transport (BLETransport.writePump model)" : "BoardConnection concurrency contract",
                          load: "\(n) concurrent PING 30-300B, 20B chunks with yields", seed: "0xB5",
                          status: pass ? "PASS" : "FAIL",
                          metrics: ["valid_frames_on_board": valid, "garbage_frames_on_board": garbage,
                                    "ok": k("ok"), "dropped": k("dropped"), "timeout": k("timeout"),
                                    "mismatch": k("mismatch"), "error": k("error"),
                                    "max_concurrent_transport_sends": t.maxConcurrentSends],
                          evidence: "StressFaultBlobTests/testP1_b5_ConcurrentChunkedWritesNeverInterleave")
            XCTAssertTrue(pass, caseID)
            c.disconnect()
        }
    }

    // MARK: P1-d

    enum BlobStage: String, CaseIterable { case begin, chunk, end, abort }
    enum BlobFault: String, CaseIterable { case cancel, disconnect }

    func testP1_d_BlobFaultsReleaseLocksLeasesAndPermits() async {
        let loops = 10
        for stage in BlobStage.allCases {
            for fault in BlobFault.allCases {
                var failures: [String] = []
                var failMs: [Double] = []
                var recoverMs: [Double] = []
                var forcedDisconnects = 0
                var abortsSent = 0
                for loop in 0..<loops {
                    let r = await blobCase(stage: stage, fault: fault)
                    failMs.append(r.failMs)
                    recoverMs.append(r.recoverMs)
                    forcedDisconnects += r.forcedDisconnect ? 1 : 0
                    abortsSent += r.abortSent
                    if let f = r.failure, failures.count < 3 { failures.append("loop\(loop):\(f)") }
                }
                let pass = failures.isEmpty
                Stress.record(case: "P1-d-blob-\(stage.rawValue)-\(fault.rawValue)", layer: "BoardConnection.uploadBlob/blobPump/output lease",
                              load: "\(loops) loops, 1410B scroll blob, fault at \(stage.rawValue)", status: pass ? "PASS" : "FAIL",
                              metrics: ["loops": loops, "failures": failures.joined(separator: " ; "),
                                        "upload_end_ms_p50": Stress.percentile(failMs, 50), "upload_end_ms_max": failMs.max() ?? -1,
                                        "recover_ms_p50": Stress.percentile(recoverMs, 50), "recover_ms_max": recoverMs.max() ?? -1,
                                        "aborts_sent": abortsSent, "carrier_resets": forcedDisconnects],
                              evidence: "StressFaultBlobTests/testP1_d_BlobFaultsReleaseLocksLeasesAndPermits")
                XCTAssertTrue(pass, "\(stage)/\(fault): \(failures)")
            }
        }
    }

    private struct BlobResult {
        var failure: String?
        var failMs: Double = -1
        var recoverMs: Double = -1
        var forcedDisconnect = false
        var abortSent = 0
    }

    private func blobCase(stage: BlobStage, fault: BlobFault) async -> BlobResult {
        var result = BlobResult()
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        t.autoReplyTypes = [RinaLinkMessageType.ping.rawValue, RinaLinkMessageType.cmd.rawValue,
                            RinaLinkMessageType.getStatus.rawValue, RinaLinkMessageType.getFrame.rawValue,
                            RinaLinkMessageType.getPreviewSync.rawValue]
        let session = c.output.begin(.text)
        let outcome = StressBox<String?>(nil)
        let data = Data(repeating: 0, count: 47 * 30)
        let upload = Task { @MainActor in
            do {
                _ = try await BoardOutputContext.$session.withValue(session) {
                    try await c.uploadBlob(kind: .scroll, meta: [:], data: data)
                }
                outcome.value = "completed"
            } catch is CancellationError {
                outcome.value = "cancelled"
            } catch {
                outcome.value = "\(error)"
            }
        }
        func waitHeld(_ type: RinaLinkMessageType) async -> Bool {
            await Stress.wait(timeout: 2) { t.held.contains { $0.type == type.rawValue } }
        }
        var reached = false
        switch stage {
        case .begin:
            reached = await waitHeld(.blobBegin)
        case .chunk:
            if await waitHeld(.blobBegin) { t.replyHeld({ $0.type == RinaLinkMessageType.blobBegin.rawValue }, payload: Data(#"{"ok":true,"offset":0}"#.utf8)) }
            reached = await waitHeld(.blobChunk)
        case .end:
            if await waitHeld(.blobBegin) { t.replyHeld({ $0.type == RinaLinkMessageType.blobBegin.rawValue }, payload: Data(#"{"ok":true,"offset":0}"#.utf8)) }
            reached = await Stress.wait(timeout: 3) {
                if t.held.contains(where: { $0.type == RinaLinkMessageType.blobEnd.rawValue }) { return true }
                t.replyHeld({ $0.type == RinaLinkMessageType.blobChunk.rawValue })
                return false
            }
        case .abort:
            if await waitHeld(.blobBegin) { t.replyHeld({ $0.type == RinaLinkMessageType.blobBegin.rawValue }, payload: Data(#"{"ok":true,"offset":0}"#.utf8)) }
            if await waitHeld(.blobChunk) { _ = c.output.begin(.performance) }
            reached = await waitHeld(.blobAbort)
        }
        guard reached else {
            result.failure = "stage not reached"
            upload.cancel()
            c.disconnect()
            return result
        }
        let faultAt = Stress.nowNs()
        switch fault {
        case .cancel:
            if stage == .abort {
                upload.cancel()
            } else {
                _ = c.output.begin(.performance)
                if await waitHeld(.blobAbort) { t.replyHeld({ $0.type == RinaLinkMessageType.blobAbort.rawValue }) }
            }
        case .disconnect:
            t.emit(.disconnected)
        }
        let finished = await Stress.wait(timeout: 5) { outcome.value != nil }
        result.failMs = Stress.ms(since: faultAt)
        result.abortSent = t.writes(of: .blobAbort).count
        // connectCount includes the harness's initial connect.
        result.forcedDisconnect = t.connectCount > 1
        guard finished else {
            result.failure = "upload did not finish within 5 s"
            c.disconnect()
            return result
        }
        if outcome.value == "completed" { result.failure = "upload reported success after fault" }
        let reconnected = await Stress.wait(timeout: 4) { c.connectionState == .connected }
        guard reconnected else {
            result.failure = "not connected after fault: \(c.connectionState)"
            c.disconnect()
            return result
        }
        t.autoReply = true
        let recoverStart = Stress.nowNs()
        let ping = try? await c.send(type: .ping, payload: Data("after".utf8), timeout: 1)
        let nextSession = c.output.begin(.text)
        let nextOutcome = StressBox<String?>(nil)
        Task { @MainActor in
            do {
                _ = try await BoardOutputContext.$session.withValue(nextSession) {
                    try await c.uploadBlob(kind: .scroll, meta: [:], data: data)
                }
                nextOutcome.value = "completed"
            } catch {
                nextOutcome.value = "\(error)"
            }
        }
        let nextDone = await Stress.wait(timeout: 3) { nextOutcome.value != nil }
        result.recoverMs = Stress.ms(since: recoverStart)
        let operations = Stress.operationsCount(c.output)
        let pending = Stress.pendingCount(c)
        if ping == nil { result.failure = (result.failure ?? "") + " ping failed after fault" }
        if !nextDone || nextOutcome.value != "completed" {
            result.failure = (result.failure ?? "") + " next upload: \(nextOutcome.value ?? "timed out")"
        }
        if operations > 0 { result.failure = (result.failure ?? "") + " leaked output operations=\(operations)" }
        if pending > 0 { result.failure = (result.failure ?? "") + " leaked pending=\(pending)" }
        c.disconnect()
        return result
    }
}
