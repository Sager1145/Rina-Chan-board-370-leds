import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// P2 boundaries: scroll frame counts, UTF-8 text sizes, face counts,
/// malformed raw bytes (built directly, bypassing the encoder precondition).
@MainActor
final class StressBoundaryTests: XCTestCase {
    static func font() throws -> ArkPixelFont {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"))
        return try ArkPixelFont.loadBundled(url: url)
    }

    /// Byte size of the BLOB_BEGIN payload built by BoardConnection.startScrollBitmapUpload
    /// (BoardConnection.swift:933-943 plus uploadBlobSerial:842-845). Derived, not intercepted.
    static func derivedBitmapBeginBytes(_ timeline: ScrollTimeline, fps: Int, sourceText: String) -> Int {
        var meta: [String: Any] = [
            "width": timeline.bitmapWidth, "rows": MatrixGeometry.rows, "fps": fps,
            "timelineId": timeline.timelineId, "fontId": ScrollRasterizer.fontId,
            "generatorVersion": ScrollRasterizer.generatorVersion,
        ]
        if sourceText.utf8.count <= 4096 { meta["sourceText"] = sourceText }
        meta["kind"] = "scroll_bitmap"
        meta["totalBytes"] = timeline.bitmap.packedBytes().count
        return (try? JSONSerialization.data(withJSONObject: meta).count) ?? -1
    }

    static let byteHeavyFillers: [(String, String)] = [
        ("VS16", "\u{FE0F}"), ("ZWJ", "\u{200D}"), ("combining-acute", "\u{0301}"),
        ("tag-a", "\u{E0061}"), ("ZWSP", "\u{200B}"),
    ]

    static func filled(_ filler: String, limit: Int = 4096) -> String {
        var scalars = String.UnicodeScalarView("Rina".unicodeScalars)
        let size = filler.utf8.count
        var bytes = 4
        while bytes + size <= limit {
            scalars.append(contentsOf: filler.unicodeScalars)
            bytes += size
        }
        return String(scalars)
    }

    func testP2_ScrollFrameCountBoundaries() async {
        for count in [0, 1, 3071, 3072, 3073] {
            let t = StressTransport()
            let c = await stressConnected(t)
            var f = PackedFrame()
            f.set(10)
            var outcome = "accepted"
            do {
                _ = try await c.startScrollUpload(frames: Array(repeating: f, count: count), fps: 10, timelineId: "b\(count)",
                                                  fontId: ScrollRasterizer.fontId, generatorVersion: ScrollRasterizer.generatorVersion,
                                                  sourceText: "x")
            } catch {
                outcome = "rejected:\(error)"
            }
            let begin = t.writes(of: .blobBegin).first.map { Stress.json($0.frame) }
            let chunks = t.writes(of: .blobChunk)
            let aligned = chunks.allSatisfy { ($0.frame.payload.count - 4) % PackedFrame.byteCount == 0 }
            let sentBytes = chunks.reduce(0) { $0 + $1.frame.payload.count - 4 }
            let maxPayload = t.writes.map(\.frame.payload.count).max() ?? 0
            let reachedWire = begin != nil
            let expectReject = count > RinaLinkConstants.maxScrollFrames
            let pass = expectReject
                ? !reachedWire
                : (outcome == "accepted" && aligned && sentBytes == count * PackedFrame.byteCount && maxPayload <= 4096)
            Stress.record(case: "P2-scroll-frames-\(count)", layer: "BoardConnection.startScrollUpload",
                          load: "\(count) packed frames via raw-frame blob", status: pass ? "PASS" : "FAIL",
                          metrics: ["outcome": outcome, "reached_wire": reachedWire,
                                    "begin_totalFrames": begin?["totalFrames"] as? Int ?? -1,
                                    "chunks": chunks.count, "chunks_aligned_47": aligned, "bytes_sent": sentBytes,
                                    "max_frame_payload": maxPayload, "client_side_cap_enforced": !reachedWire],
                          evidence: "StressBoundaryTests/testP2_ScrollFrameCountBoundaries")
            c.disconnect()
        }
    }

    func testP2_TextUtf8Boundaries() throws {
        let font = try Self.font()
        var rows: [String] = []
        var wrong = 0
        for (name, unit) in [("ascii", "a"), ("cjk", "璃"), ("emoji", "😀"), ("combining", "e\u{0301}")] {
            for target in [4095, 4096, 4097] {
                var scalars = String.UnicodeScalarView()
                var bytes = 0
                while bytes + unit.utf8.count <= target {
                    scalars.append(contentsOf: unit.unicodeScalars)
                    bytes += unit.utf8.count
                }
                while bytes < target { scalars.append("a"); bytes += 1 }
                let s = String(scalars)
                let exceeds = ScrollText.exceedsByteLimit(s)
                var raster: String
                do {
                    let tl = try ScrollRasterizer.makeTimeline(text: s, font: font, fps: 10)
                    raster = "frames=\(tl.frameCount)/textBytes=\(tl.text.utf8.count)"
                } catch {
                    raster = "\(error)"
                }
                let startScrollBytes = (try? RinaCommand.startScroll(intervalMs: nil, fps: 10, sourceText: s).encode().count) ?? -1
                if s.utf8.count != target || exceeds != (target > 4096) { wrong += 1 }
                rows.append("\(name)/\(target):bytes=\(s.utf8.count),exceeds=\(exceeds),raster=\(raster),start_scroll_cmd_bytes=\(startScrollBytes)")
            }
        }
        Stress.record(case: "P2-text-utf8-4095-4096-4097", layer: "ScrollText.exceedsByteLimit / ScrollRasterizer",
                      load: "ascii/cjk/emoji/combining x 4095/4096/4097 bytes", status: wrong == 0 ? "PASS" : "FAIL",
                      metrics: ["wrong_limit_decisions": wrong, "rows": rows.joined(separator: " ; ")],
                      evidence: "StressBoundaryTests/testP2_TextUtf8Boundaries")
        XCTAssertEqual(wrong, 0)

        var reachable: [String] = []
        var candidates: [String] = []
        for (name, filler) in Self.byteHeavyFillers {
            let s = Self.filled(filler)
            do {
                let tl = try ScrollRasterizer.makeTimeline(text: s, font: font, fps: 10)
                let beginBytes = Self.derivedBitmapBeginBytes(tl, fps: 10, sourceText: tl.text)
                candidates.append("\(name):inputBytes=\(s.utf8.count),frames=\(tl.frameCount),textBytes=\(tl.text.utf8.count),derivedBeginBytes=\(beginBytes)")
                if beginBytes > RinaLinkFrameConstants.maxPayloadBytes { reachable.append(name) }
            } catch {
                candidates.append("\(name):inputBytes=\(s.utf8.count),raster=\(error)")
            }
        }
        Stress.record(case: "P2-text-bitmap-begin-overflow-reachability", layer: "TextViewModel.send -> startScrollBitmapUpload meta (BoardConnection.swift:941)",
                      load: "text <=4096 UTF-8 bytes accepted by rasterizer, sourceText embedded in BLOB_BEGIN JSON",
                      status: reachable.isEmpty ? "PASS" : "FAIL",
                      metrics: ["rasterizer_accepted_overflowing_candidates": reachable.joined(separator: "|"),
                                "candidates": candidates.joined(separator: " ; "),
                                "note": "derived size; trap confirmed separately by StressCrashReproTests"],
                      evidence: "StressBoundaryTests/testP2_TextUtf8Boundaries")
    }

    func testP2_FaceCountBoundaries() throws {
        var rows: [String] = []
        var overflowAtOrBelowMax = false
        for n in [127, 128, 129] {
            let boardIds = (0..<n).map { "custom_" + String(1_757_000_000_000 + $0 * 997, radix: 36) }
            let localIds = (0..<n).map { _ in "local_" + UUID().uuidString.lowercased() }
            let boardBytes = try RinaCommand.faceReorder(ids: boardIds).encode().count
            let localBytes = try RinaCommand.faceReorder(ids: localIds).encode().count
            if localBytes > 4096, n <= RinaLinkConstants.maxFaces { overflowAtOrBelowMax = true }
            rows.append("n=\(n):boardStyleIdBytes=\(boardBytes),localStyleIdBytes=\(localBytes)")
        }
        var fit = 0
        var ids: [String] = []
        while true {
            ids.append("local_" + UUID().uuidString.lowercased())
            guard try RinaCommand.faceReorder(ids: ids).encode().count <= 4096 else { break }
            fit = ids.count
        }
        Stress.record(case: "P2-faces-127-128-129-reorder-payload", layer: "BoardConnection.faceReorder -> RinaLinkEncoder precondition",
                      load: "face_reorder with 127/128/129 ids (board-style ~15 chars, local-style 42 chars)",
                      status: overflowAtOrBelowMax ? "FAIL" : "PASS",
                      metrics: ["rows": rows.joined(separator: " ; "), "max_local_style_ids_fitting_4096": fit,
                                "client_face_count_check": "none (RinaLinkConstants.maxFaces unused)",
                                "note": "exact bytes from RinaCommand.encode(), the payload sendFaceOp passes to send()"],
                      evidence: "StressBoundaryTests/testP2_FaceCountBoundaries")
    }

    func testP2_MalformedRawBytes() async {
        var rng = StressRNG(seed: 0x2A2A)
        func randomData(_ n: Int) -> Data {
            var d = Data(count: n)
            d.withUnsafeMutableBytes { raw in
                var i = 0
                while i < n {
                    var v = rng.next()
                    for _ in 0..<8 where i < n {
                        raw[i] = UInt8(truncatingIfNeeded: v)
                        v >>= 8
                        i += 1
                    }
                }
            }
            return d
        }

        // 1. Random fuzz in random chunk sizes.
        let decoder = RinaLinkDecoder()
        var parsed = 0
        var maxBuffer = 0
        var remaining = 4 << 20
        let fuzzStart = Stress.nowNs()
        while remaining > 0 {
            let n = min(remaining, Int.random(in: 1...2048, using: &rng))
            parsed += decoder.feed(randomData(n)).count
            maxBuffer = max(maxBuffer, Stress.count(Stress.reflect(decoder, "buffer")))
            remaining -= n
        }
        let fuzzMs = Stress.ms(since: fuzzStart)

        // 2. Non-magic garbage delivered in one feed: resync cost scaling.
        var garbageMs: [String] = []
        for size in [16_384, 65_536, 262_144] {
            let d = RinaLinkDecoder()
            let s = Stress.nowNs()
            _ = d.feed(Data(repeating: 0x00, count: size))
            garbageMs.append("\(size)B=\(Int(Stress.ms(since: s)))ms")
        }

        // 3. Oversized length field then a valid frame.
        let valid = RinaLinkEncoder.encode(RinaLinkFrame(type: 0x86, seq: 9, flags: 0, payload: Data("ok".utf8)))
        let d3 = RinaLinkDecoder()
        let oversized = d3.feed(Data([0xA5, 0x86, 1, 0, 0x01, 0x10]) + valid).count

        // 4. Plausible header (len 4000) swallows the following valid frame.
        let d4 = RinaLinkDecoder()
        let swallowedFirst = d4.feed(Data([0xA5, 0x86, 1, 0, 0xA0, 0x0F]) + valid).count
        let afterFill = d4.feed(Data(repeating: 0, count: 4000)).count
        let afterRetry = d4.feed(valid).count

        // 5. Through BoardConnection.
        let t = StressTransport()
        let c = await stressConnected(t)
        t.autoReply = false
        let errorFrame = Task { @MainActor () -> String in
            do { _ = try await c.send(type: .getStatus, payload: Data(), timeout: 2); return "ok" } catch { return "\(error)" }
        }
        _ = await Stress.wait(timeout: 1) { !t.held.isEmpty }
        if let h = t.takeHeld({ _ in true }) {
            t.inject(RinaLinkFrame(type: 0xFF, seq: h.seq, flags: 0, payload: Data("not json".utf8)))
        }
        let errorResult = await errorFrame.value
        let shortFrame = Task { @MainActor () -> String in
            do { _ = try await c.getFrame(); return "ok" } catch { return "\(error)" }
        }
        _ = await Stress.wait(timeout: 1) { !t.held.isEmpty }
        if let h = t.takeHeld({ _ in true }) { t.reply(to: h, payload: Data(repeating: 1, count: 46)) }
        let shortResult = await shortFrame.value
        t.inject(RinaLinkFrame(type: RinaLinkMessageType.evStatus.rawValue, seq: 0, flags: 0, payload: Data("{{{".utf8)))
        t.inject(RinaLinkFrame(type: RinaLinkMessageType.evLog.rawValue, seq: 0, flags: 0, payload: Data([0xFF, 0xFE])))
        t.inject(RinaLinkFrame(type: 0x7E, seq: 0, flags: 0, payload: Data()))
        t.inject(RinaLinkFrame(type: 0x86, seq: 200, flags: RinaLinkFrameConstants.flagMore, payload: Data("stray".utf8)))
        t.injectRaw(randomData(262_144))
        try? await Task.sleep(nanoseconds: 300_000_000)
        t.autoReply = true
        var pings: [String] = []
        for i in 0..<3 {
            do { _ = try await c.send(type: .ping, payload: Data("alive\(i)".utf8), timeout: 1); pings.append("ok") }
            catch { pings.append("\(error)") }
        }
        let stillConnected = c.connectionState == .connected
        let recovered = pings.contains("ok")
        let pass = maxBuffer <= RinaLinkFrameConstants.headerBytes + RinaLinkFrameConstants.maxPayloadBytes
            && oversized == 1 && errorResult.contains("unknown error") && shortResult.contains("invalidResponse")
            && stillConnected && recovered
        Stress.record(case: "P2-malformed-raw-bytes", layer: "RinaLinkDecoder + BoardConnection.route", load: "4 MiB fuzz + crafted headers + 256 KiB garbage into live connection",
                      seed: "0x2A2A", status: pass ? "PASS" : "FAIL",
                      metrics: ["fuzz_frames_parsed": parsed, "fuzz_ms": fuzzMs, "decoder_max_buffer": maxBuffer,
                                "garbage_single_feed": garbageMs.joined(separator: "|"),
                                "oversized_len_then_valid_parsed": oversized,
                                "plausible_header_swallows_valid_frame": swallowedFirst == 0,
                                "frames_after_4000B_fill": afterFill, "valid_after_resync": afterRetry,
                                "error_frame_bad_json": errorResult, "getFrame_46B": shortResult,
                                "pings_after_garbage": pings.joined(separator: "|"), "still_connected": stillConnected],
                      evidence: "StressBoundaryTests/testP2_MalformedRawBytes")
        XCTAssertTrue(pass)
        c.disconnect()
    }
}

/// Run each test ALONE (`-only-testing:`): a reproduced defect traps the host app.
@MainActor
final class StressCrashReproTests: XCTestCase {
    func testCrashRepro_TextSendBitmapBeginOverflow() async throws {
        let font = try StressBoundaryTests.font()
        var chosen: (name: String, text: String, frames: Int, bytes: Int)?
        for (name, filler) in StressBoundaryTests.byteHeavyFillers {
            let s = StressBoundaryTests.filled(filler)
            guard let tl = try? ScrollRasterizer.makeTimeline(text: s, font: font, fps: 10),
                  tl.text.utf8.count >= 3900 else { continue }
            chosen = (name, s, tl.frameCount, tl.text.utf8.count)
            break
        }
        guard let chosen else { throw XCTSkip("no rasterizer-accepted byte-heavy candidate") }
        let t = StressTransport()
        let c = await stressConnected(t)
        let model = TextViewModel()
        model.text = chosen.text
        print("CRASHREPRO text filler=\(chosen.name) textBytes=\(chosen.bytes) frames=\(chosen.frames) -> TextViewModel.send")
        await model.send(connection: c)
        print("CRASHREPRO survived: error=\(model.errorMessage ?? "nil") blobBeginWrites=\(t.writes(of: .blobBegin).count)")
        XCTFail("expected RinaLinkEncoder precondition trap did not occur")
    }

    func testCrashRepro_FaceReorderOverflow() async throws {
        let t = StressTransport()
        let c = await stressConnected(t)
        let ids = (0..<128).map { _ in "local_" + UUID().uuidString.lowercased() }
        let bytes = try RinaCommand.faceReorder(ids: ids).encode().count
        print("CRASHREPRO faceReorder ids=\(ids.count) payloadBytes=\(bytes) -> BoardConnection.faceReorder")
        _ = try? await c.faceReorder(ids: ids)
        print("CRASHREPRO survived faceReorder")
        XCTFail("expected RinaLinkEncoder precondition trap did not occur")
    }
}
