import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// PR-0 performance baseline: measures how the CURRENT (unoptimized)
/// `ControlViewModel.pushLiveIfNeeded` / `BoardConnection` pipeline behaves
/// under a rapid stream of local edits against a simulated BLE round trip.
/// This adds no optimizations and asserts nothing about the numbers beyond
/// "at least one edit happened" — the printed line is the artifact.
@MainActor
final class ControlLivePreviewStressTests: XCTestCase {
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

        // Wait for quiescence: the wire count stops changing for 300 ms, capped at 3 s.
        var lastCount = transport.sentCount(type: .setFrame)
        var stableSince = clock.now
        let quiescenceDeadline = clock.now.advanced(by: .seconds(3))
        while clock.now < quiescenceDeadline {
            try? await Task.sleep(until: clock.now.advanced(by: .milliseconds(20)), clock: clock)
            let current = transport.sentCount(type: .setFrame)
            if current != lastCount {
                lastCount = current
                stableSince = clock.now
            } else if clock.now - stableSince >= .milliseconds(300) {
                break
            }
        }

        let wire = transport.sentCount(type: .setFrame)
        let quarantineEvents = connection.quarantineEventCount
        let quarantinedNow = connection.quarantinedSequenceCount
        var finalMatches = false
        if let lastFrame = transport.lastSent(type: .setFrame) {
            finalMatches = decodedFrame(from: lastFrame.payload) == model.draftFrame
        }
        print("[ControlLiveStress] rate=\(rateHz) edits=\(edits) wire=\(wire) quarantineEvents=\(quarantineEvents) quarantinedNow=\(quarantinedNow) finalMatches=\(finalMatches) errorsSeen=\(errorsSeen)")

        XCTAssertGreaterThan(edits, 0)

        connection.disconnect()
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
