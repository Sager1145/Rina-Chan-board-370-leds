import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Measures how `ControlViewModel.pushLiveIfNeeded` / `BoardConnection`
/// behave under a rapid stream of local edits against a simulated BLE round
/// trip. For each rate the printed `[ControlLiveStress]` line is compared
/// (not asserted) against the PR-0 baseline, and four invariants are
/// asserted: no in-flight send is ever cancelled (`quarantineEvents == 0`),
/// the last wire frame matches the final draft (`finalMatches == true`), no
/// send surfaces an error (`errorsSeen == 0`), and coalescing never sends
/// more frames than edits (`wire <= edits`).
@MainActor
final class ControlLivePreviewStressTests: XCTestCase {
    /// PR-0 baseline captured against the unoptimized pipeline (30 ms
    /// simulated reply delay, 2 s per rate). PR-5 must not regress
    /// quarantine/finalMatches/errors, but wire counts are reported only —
    /// timing under load is noisy, so they are not asserted against this.
    private static let baselineWire: [Int: Int] = [10: 20, 25: 50, 50: 89, 75: 83, 100: 76]

    func testLiveSendUnderVaryingEditRates() async throws {
        for rate in [10, 25, 50, 75, 100] {
            await runStress(rateHz: rate)
        }
    }

    private func runStress(rateHz: Int) async {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        transport.replyDelay = .milliseconds(30)
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected, "rate \(rateHz): connection must establish")

        let model = ControlViewModel()
        model.livePreview = true

        let clock = ContinuousClock()
        let interval = Duration.seconds(1.0 / Double(rateHz))
        let deadline = clock.now.advanced(by: .seconds(2))
        var edits = 0
        var errorsSeen = 0
        var i = 0
        var next = clock.now
        while clock.now < deadline {
            model.toggle(led: i % 370, connection: connection)
            edits += 1
            if model.errorMessage != nil { errorsSeen += 1 }
            i += 1
            next += interval
            if next > clock.now {
                try? await Task.sleep(until: next, clock: clock)
            }
        }

        await waitForQuiescence(transport: transport, model: model)
        if model.errorMessage != nil { errorsSeen += 1 }

        let wire = transport.sentCount(type: .setFrame)
        let quarantineEvents = connection.quarantineEventCount
        let quarantinedNow = connection.quarantinedSequenceCount
        var finalMatches = false
        if let lastFrame = transport.lastSent(type: .setFrame) {
            finalMatches = decodedFrame(from: lastFrame.payload) == model.draftFrame
        }
        let baselineWire = Self.baselineWire[rateHz] ?? -1
        print("[ControlLiveStress] rate=\(rateHz) edits=\(edits) wire=\(wire) baselineWire=\(baselineWire) quarantineEvents=\(quarantineEvents) quarantinedNow=\(quarantinedNow) finalMatches=\(finalMatches) errorsSeen=\(errorsSeen)")

        XCTAssertGreaterThan(edits, 0)
        XCTAssertEqual(quarantineEvents, 0, "rate \(rateHz): no in-flight send should ever be cancelled")
        XCTAssertTrue(finalMatches, "rate \(rateHz): the last wire frame must match the final draft")
        XCTAssertEqual(errorsSeen, 0, "rate \(rateHz): no send should surface an error")
        XCTAssertLessThanOrEqual(wire, edits, "rate \(rateHz): coalescing must never send more frames than edits")

        connection.disconnect()
    }

    // MARK: Explicit send supersedes pending live edits

    func testExplicitSendAfterLiveEditsWins() async throws {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        transport.replyDelay = .milliseconds(100)
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)

        let model = ControlViewModel()
        model.livePreview = true

        // Get one live frame in flight before queuing more edits behind it.
        model.toggle(led: 0, connection: connection)
        try await waitForWireCount(transport: transport, atLeast: 1)

        // A newer live value becomes pending while the first is still in flight.
        for i in 1..<4 {
            model.toggle(led: i, connection: connection)
        }

        model.livePreview = false
        model.toggle(led: 369, connection: connection)
        let expectedFrame = model.draftFrame

        await model.send(connection: connection)
        await waitForQuiescence(transport: transport, model: model)

        let setFrames = transport.sentFrames(type: .setFrame)
        XCTAssertFalse(setFrames.isEmpty)
        guard let last = setFrames.last else { return }
        XCTAssertEqual(reason(from: last.payload), "custom_face_send")
        XCTAssertEqual(decodedFrame(from: last.payload), expectedFrame)

        // No "custom_live_send" frame appears on or after the explicit send.
        guard let faceSendIndex = setFrames.firstIndex(where: { reason(from: $0.payload) == "custom_face_send" }) else {
            XCTFail("no custom_face_send frame found on the wire")
            return
        }
        for frame in setFrames[(faceSendIndex + 1)...] {
            XCTAssertNotEqual(reason(from: frame.payload), "custom_live_send",
                              "a live frame reached the wire after the explicit send")
        }

        connection.disconnect()
    }

    // MARK: releaseOutput drops a pending live frame

    func testReleaseOutputDropsPendingLiveFrame() async throws {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        transport.replyDelay = .milliseconds(100)
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)

        let model = ControlViewModel()
        model.livePreview = true

        // Get one live frame in flight...
        model.toggle(led: 1, connection: connection)
        try await waitForWireCount(transport: transport, atLeast: 1)

        // ...then queue a second edit behind it, which becomes pending.
        model.toggle(led: 2, connection: connection)

        model.connectionChanged(generation: nil)

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(transport.sentCount(type: .setFrame), 1,
                       "the pending second edit must never reach the wire after releaseOutput")

        // The sender restarts on the next edit: `pushLiveIfNeeded`'s guards
        // (livePreview, connection state, draft ownership) are untouched by
        // `releaseOutput`, so a fresh edit is accepted and reaches the wire.
        model.toggle(led: 3, connection: connection)
        try await waitForWireCount(transport: transport, atLeast: 2)

        guard let last = transport.lastSent(type: .setFrame) else {
            XCTFail("expected a SET_FRAME after the sender restarted")
            return
        }
        XCTAssertEqual(decodedFrame(from: last.payload), model.draftFrame)

        connection.disconnect()
    }

    /// Polls (20 ms, 5 s deadline) until the last wire SET_FRAME decodes to
    /// `model.draftFrame` and the wire's frame count has been stable for
    /// 100 ms — plain "no new frame for N ms" can declare quiescence too
    /// early on a loaded machine if the stall happens to land between two
    /// sends that are still in flight.
    private func waitForQuiescence(transport: FakeRinaTransport, model: ControlViewModel) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var lastCount = transport.sentCount(type: .setFrame)
        var stableSince = clock.now
        while clock.now < deadline {
            try? await Task.sleep(until: clock.now.advanced(by: .milliseconds(20)), clock: clock)
            let current = transport.sentCount(type: .setFrame)
            if current != lastCount {
                lastCount = current
                stableSince = clock.now
            }
            let matches = transport.lastSent(type: .setFrame)
                .flatMap { decodedFrame(from: $0.payload) } == model.draftFrame
            if matches && clock.now - stableSince >= .milliseconds(100) {
                return
            }
        }
    }

    /// Polls (10 ms, 5 s deadline) until at least `target` SET_FRAMEs have
    /// reached the wire.
    private func waitForWireCount(transport: FakeRinaTransport, atLeast target: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if transport.sentCount(type: .setFrame) >= target { return }
            try? await Task.sleep(until: clock.now.advanced(by: .milliseconds(10)), clock: clock)
        }
        XCTFail("timed out waiting for wire count >= \(target)")
    }

    /// SET_FRAME payload layout: 1 byte playback, 1 byte reason length L,
    /// L reason bytes, then the 47-byte packed frame.
    private func reason(from payload: Data) -> String? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return nil }
        let reasonLength = Int(bytes[1])
        guard bytes.count >= 2 + reasonLength else { return nil }
        return String(bytes: bytes[2..<(2 + reasonLength)], encoding: .utf8)
    }

    /// SET_FRAME payload layout: 1 byte playback, 1 byte reason length L,
    /// L reason bytes, then the 47-byte packed frame.
    private func decodedFrame(from payload: Data) -> PackedFrame? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return nil }
        let reasonLength = Int(bytes[1])
        let frameStart = 2 + reasonLength
        guard bytes.count >= frameStart + PackedFrame.byteCount else { return nil }
        let frameBytes = Data(bytes[frameStart..<(frameStart + PackedFrame.byteCount)])
        return PackedFrame(data: frameBytes)
    }
}
