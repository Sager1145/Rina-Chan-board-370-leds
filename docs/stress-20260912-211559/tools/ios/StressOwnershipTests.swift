import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// P1-c playback ownership: every directed source switch (7 x 6 = 42) plus
/// same-source restarts (7), 100 loops per direction per phase, directions
/// run concurrently on independent connections.
@MainActor
final class StressOwnershipTests: XCTestCase {
    static let sources: [BoardOutputSource] = [.manual, .automatic, .text, .lipSync, .performance, .video, .debug]

    /// Fails to compile if a source is added, so the matrix cannot silently miss one.
    static func ordinal(_ source: BoardOutputSource) -> Int {
        switch source {
        case .manual: return 0
        case .automatic: return 1
        case .text: return 2
        case .lipSync: return 3
        case .performance: return 4
        case .video: return 5
        case .debug: return 6
        }
    }

    enum Phase: String, CaseIterable { case queued, writing, awaitingAck, ackQueued, ackRouted }

    struct Tally {
        var iterations = 0
        var failures = 0
        var oldWritesAfterTakeover = 0
        var oldCompletedOK = 0
        var examples: [String] = []
    }

    func testP1_c_TakeoverMatrix() async {
        XCTAssertEqual(Set(Self.sources.map(Self.ordinal)).count, 7)
        let loops = 100
        let start = Stress.nowNs()
        var totals: [Phase: Tally] = [:]
        var directions = 0
        await withTaskGroup(of: [Phase: Tally].self) { group in
            for from in Self.sources {
                for to in Self.sources {
                    directions += 1
                    group.addTask { @MainActor in
                        await self.direction(from: from, to: to, loops: loops)
                    }
                }
            }
            for await result in group {
                for (phase, tally) in result {
                    var total = totals[phase] ?? Tally()
                    total.iterations += tally.iterations
                    total.failures += tally.failures
                    total.oldWritesAfterTakeover += tally.oldWritesAfterTakeover
                    total.oldCompletedOK += tally.oldCompletedOK
                    total.examples.append(contentsOf: tally.examples.prefix(max(0, 5 - total.examples.count)))
                    totals[phase] = total
                }
            }
        }
        let seconds = Stress.ms(since: start) / 1000
        for phase in Phase.allCases {
            let tally = totals[phase] ?? Tally()
            Stress.record(case: "P1-c-takeover-\(phase.rawValue)", layer: "BoardPlaybackCoordinator + BoardConnection.setFrame",
                          load: "\(directions) directions (42 switches + 7 restarts) x \(loops) loops, concurrent connections",
                          status: tally.failures == 0 && tally.iterations == directions * loops ? "PASS" : "FAIL",
                          metrics: ["iterations": tally.iterations, "failures": tally.failures,
                                    "old_writes_after_takeover": tally.oldWritesAfterTakeover,
                                    "old_setFrame_returned_ok": tally.oldCompletedOK,
                                    "examples": tally.examples.joined(separator: " ; "),
                                    "matrix_wall_s": seconds],
                          evidence: "StressOwnershipTests/testP1_c_TakeoverMatrix")
            XCTAssertEqual(tally.failures, 0, "\(phase): \(tally.examples)")
        }
    }

    private func direction(from: BoardOutputSource, to: BoardOutputSource, loops: Int) async -> [Phase: Tally] {
        var tallies: [Phase: Tally] = [:]
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        let stops = StressBox([BoardOutputSource: Int]())
        for source in Self.sources {
            c.output.register(source) { stops.value[source, default: 0] += 1 }
        }
        for phase in Phase.allCases {
            var tally = Tally()
            for k in 0..<loops {
                let result = await iteration(c, t, stops, from, to, phase, k)
                tally.iterations += 1
                tally.oldWritesAfterTakeover += result.oldWritesAfter
                if result.oldOK { tally.oldCompletedOK += 1 }
                if let failure = result.failure {
                    tally.failures += 1
                    if tally.examples.count < 2 { tally.examples.append("\(from.rawValue)>\(to.rawValue) \(phase.rawValue)#\(k): \(failure)") }
                }
            }
            tallies[phase] = tally
            // Let cancelled seqs leave quarantine so phases do not interact.
            _ = await Stress.wait(timeout: 3, poll: 50_000_000) { Stress.quarantined(c).count < 20 }
        }
        c.disconnect()
        return tallies
    }

    private struct IterationResult {
        var failure: String?
        var oldWritesAfter = 0
        var oldOK = false
    }

    private func iteration(_ c: BoardConnection, _ t: StressTransport, _ stops: StressBox<[BoardOutputSource: Int]>,
                           _ from: BoardOutputSource, _ to: BoardOutputSource, _ phase: Phase, _ k: Int) async -> IterationResult {
        var r = IterationResult()
        t.clearHeld()
        t.holdWrites = false
        let tag = "\(k)"
        let oldToken = c.output.begin(from)
        stops.value = [:]
        var oldFrame = PackedFrame(); oldFrame.set(369); oldFrame.set(k % 300)
        var newFrame = PackedFrame(); newFrame.set(368); newFrame.set(k % 300)
        let oldA = StressBox<String?>(nil)
        let oldQ = StressBox<String?>(nil)
        func reason(_ f: RinaLinkFrame) -> String { Stress.setFrameReason(f) }
        func isOld(_ f: RinaLinkFrame, _ name: String? = nil) -> Bool {
            reason(f).hasPrefix("old|\(tag)|" + (name.map { "\($0)|" } ?? ""))
        }
        func producer(_ name: String, _ box: StressBox<String?>) {
            // Deliberately naive: retries once after a failure, ignoring why.
            Task { @MainActor in
                var last = "none"
                for attempt in 0..<2 {
                    do {
                        _ = try await c.setFrame(oldFrame, playback: .idle, reason: "old|\(tag)|\(name)|\(attempt)", outputSession: oldToken)
                        last = "ok"
                        break
                    } catch is CancellationError {
                        last = "cancelled"
                    } catch {
                        last = "error:\(error)"
                    }
                }
                box.value = last
            }
        }
        var inProgress: String?
        switch phase {
        case .queued:
            producer("a", oldA)
            guard await Stress.wait(timeout: 1.5, { t.held.contains { isOld($0, "a") } }) else { r.failure = "setup: old a not written"; return r }
            producer("q", oldQ)
            for _ in 0..<5 { await Task.yield() }
        case .writing:
            t.holdWrites = true
            producer("a", oldA)
            guard await Stress.wait(timeout: 1.5, { t.heldWriteWaiters >= 1 }) else { r.failure = "setup: write not held"; return r }
            inProgress = "a"
        case .awaitingAck, .ackQueued, .ackRouted:
            producer("a", oldA)
            guard await Stress.wait(timeout: 1.5, { t.held.contains { isOld($0, "a") } }) else { r.failure = "setup: old a not written"; return r }
        }

        let writesBefore = t.writes.count
        switch phase {
        case .ackQueued:
            t.replyHeld({ isOld($0, "a") })
        case .ackRouted:
            t.replyHeld({ isOld($0, "a") })
            for _ in 0..<500 {
                if Stress.pendingCount(c) == 0 { break }
                await Task.yield()
            }
        default:
            break
        }
        let newToken = c.output.begin(to)
        let stopCalls = stops.value[from] ?? 0
        if phase == .writing {
            t.holdWrites = false
            t.releaseWrites()
        }

        let newResult = StressBox<String?>(nil)
        let newReason = "new|\(tag)"
        Task { @MainActor in
            do {
                _ = try await c.setFrame(newFrame, playback: .idle, reason: newReason, outputSession: newToken)
                newResult.value = "ok"
            } catch {
                newResult.value = "\(error)"
            }
        }
        let newWritten = await Stress.wait(timeout: 1.5) { t.held.contains { reason($0) == newReason } }
        if newWritten { t.replyHeld({ reason($0) == newReason }) }
        let newDone = await Stress.wait(timeout: 1.5) { newResult.value != nil }
        let oldDone = await Stress.wait(timeout: 1.5) { oldA.value != nil && (phase != .queued || oldQ.value != nil) }
        // Late ACKs for anything the old producer left on the wire.
        t.replyAllHeld()
        for _ in 0..<10 { await Task.yield() }

        let after = t.writes[writesBefore...].map(\.frame).filter { isOld($0) }
        let allowed = inProgress.map { name in min(1, after.filter { isOld($0, name) }.count) } ?? 0
        r.oldWritesAfter = after.count - allowed
        r.oldOK = oldA.value == "ok"
        var problems: [String] = []
        if r.oldWritesAfter > 0 { problems.append("old producer wrote \(r.oldWritesAfter) frame(s) after takeover: \(after.map(reason))") }
        if !newWritten { problems.append("new frame not written") }
        if !newDone || newResult.value != "ok" { problems.append("new result=\(newResult.value ?? "pending")") }
        if !oldDone { problems.append("old producer still running") }
        if c.currentFrame != newFrame { problems.append("currentFrame is not the new frame") }
        if stopCalls != 1 { problems.append("stop handler for \(from.rawValue) called \(stopCalls)x") }
        if phase == .queued, oldQ.value == "ok" { problems.append("queued old frame succeeded") }
        _ = await Stress.wait(timeout: 0.5) { Stress.operationsCount(c.output) == 0 }
        let operations = Stress.operationsCount(c.output)
        if operations > 0 { problems.append("leaked output operations=\(operations)") }
        r.failure = problems.isEmpty ? nil : problems.joined(separator: ", ")
        return r
    }

    // MARK: Paused text session across reconnects

    func testP1_c2_PausedTextSessionDoesNotAdvanceAcrossReconnects() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"))
        let font = try ArkPixelFont.loadBundled(url: url)
        let text = "Paused reconnect"
        let timeline = try ScrollRasterizer.makeTimeline(text: text, font: font, fps: 60)
        let pausedIndex = min(4, timeline.frameCount - 1)
        let meta = ScrollMeta(ok: true, scrollTimelineId: "board-paused", hasSourceText: true, sourceText: text,
                              sourceTextBytes: text.utf8.count, fontId: ScrollRasterizer.fontId,
                              generatorVersion: ScrollRasterizer.generatorVersion, uiFps: 60, scrollIntervalMs: 17,
                              frameCount: timeline.frameCount, frameIndex: 1, uploadComplete: true,
                              firmwareScrollActive: true, firmwareScrollPaused: true, scrollLoop: false)
        let preview = PreviewSync(ok: true, playback: "scroll", valid: true, presentedSeq: 82, source: "scroll_tick",
                                  scrollTimelineId: "board-paused", presentedFrameIndex: pausedIndex,
                                  presentedFrameCount: timeline.frameCount, scrollIntervalMs: 17, uiFps: 60,
                                  firmwareScrollActive: true, firmwareScrollPaused: true)
        let metaData = try JSONEncoder().encode(meta)
        let previewData = try JSONEncoder().encode(preview)
        let t = StressTransport()
        t.responder = { f in
            switch RinaLinkMessageType(rawValue: f.type) {
            case .getScrollMeta: return [RinaLinkFrame(type: f.type | 0x80, seq: f.seq, flags: 0, payload: metaData)]
            case .getPreviewSync: return [RinaLinkFrame(type: f.type | 0x80, seq: f.seq, flags: 0, payload: previewData)]
            default: return nil
            }
        }
        let c = await stressConnected(t)
        let model = TextViewModel()
        model.loopPlayback = true
        let cycles = 20
        var drift: [String] = []
        for cycle in 0..<cycles {
            if cycle > 0 {
                t.emit(.disconnected)
                guard await Stress.wait(timeout: 3, { c.connectionState != .connected }),
                      await Stress.wait(timeout: 3, { c.connectionState == .connected }) else {
                    drift.append("cycle\(cycle): reconnect failed")
                    continue
                }
            }
            model.suspendPreviewLoop()
            await model.restoreOnConnect(connection: c)
            let restored = model.displayIndex
            try? await Task.sleep(nanoseconds: 250_000_000)
            let later = model.displayIndex
            if restored != pausedIndex || later != pausedIndex || !model.boardPaused {
                drift.append("cycle\(cycle): restored=\(restored) later=\(later) paused=\(model.boardPaused)")
            }
        }
        model.suspendPreviewLoop()
        Stress.record(case: "P1-c2-paused-text-reconnect", layer: "TextViewModel.restoreOnConnect",
                      load: "\(cycles) carrier drop/reconnect cycles, 250 ms observation each, board paused at \(pausedIndex)",
                      status: drift.isEmpty ? "PASS" : "FAIL",
                      metrics: ["cycles": cycles, "drifted_cycles": drift.count, "details": drift.joined(separator: " ; "),
                                "reconnects": t.connectCount],
                      evidence: "StressOwnershipTests/testP1_c2_PausedTextSessionDoesNotAdvanceAcrossReconnects")
        XCTAssertTrue(drift.isEmpty, "\(drift)")
        c.disconnect()
    }
}
