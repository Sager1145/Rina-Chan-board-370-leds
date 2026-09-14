import XCTest
@testable import RinaCore

/// PR-0 performance baseline: throughput of the CURRENT `RinaLinkDecoder`
/// under a few feed patterns (whole frames, byte-at-a-time, chunked,
/// interspersed garbage, large payloads). No optimizations here; only the
/// frame count is asserted, the throughput numbers are printed for later
/// comparison.
final class RinaLinkDecoderBaselineTests: XCTestCase {
    private func report(_ name: String, frames: Int, bytes: Int, elapsed: Duration) {
        let seconds = millis(elapsed) / 1000
        let framesPerSecond = seconds > 0 ? Double(frames) / seconds : .infinity
        let mbPerSecond = seconds > 0 ? (Double(bytes) / 1_000_000) / seconds : .infinity
        print("[DecoderBench] \(name) frames/s=\(String(format: "%.0f", framesPerSecond)) MB/s=\(String(format: "%.2f", mbPerSecond))")
    }

    private func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    /// A: 100_000 frames with 16-byte payloads, each fed as one Data per frame.
    func testCaseAWholeFramesPerCall() throws {
        let count = 100_000
        let payload = Data(repeating: 0xAB, count: 16)
        var encoded: [Data] = []
        encoded.reserveCapacity(count)
        var totalBytes = 0
        for i in 0..<count {
            let frame = try RinaLinkEncoder.encode(type: .setFrame, seq: UInt8(truncatingIfNeeded: i), payload: payload)
            encoded.append(frame)
            totalBytes += frame.count
        }

        let decoder = RinaLinkDecoder()
        let clock = ContinuousClock()
        var decodedCount = 0
        let elapsed = clock.measure {
            for frame in encoded {
                decodedCount += decoder.feed(frame).count
            }
        }
        XCTAssertEqual(decodedCount, count)
        report("A-whole-frames-16B", frames: count, bytes: totalBytes, elapsed: elapsed)
    }

    /// B: 2_000 frames with 32-byte payloads, fed 1 byte at a time.
    func testCaseBByteAtATime() throws {
        let count = 2_000
        let payload = Data(repeating: 0xCD, count: 32)
        var stream = Data()
        for i in 0..<count {
            stream.append(try RinaLinkEncoder.encode(type: .setFrame, seq: UInt8(truncatingIfNeeded: i), payload: payload))
        }

        let decoder = RinaLinkDecoder()
        let clock = ContinuousClock()
        var decodedCount = 0
        let bytes = [UInt8](stream)
        let elapsed = clock.measure {
            for byte in bytes {
                decodedCount += decoder.feed(Data([byte])).count
            }
        }
        XCTAssertEqual(decodedCount, count)
        report("B-byte-at-a-time-32B", frames: count, bytes: stream.count, elapsed: elapsed)
    }

    /// C: 20_000 frames with 64-byte payloads, concatenated and fed in
    /// 1024-byte chunks.
    func testCaseCChunked1024() throws {
        let count = 20_000
        let payload = Data(repeating: 0xEF, count: 64)
        var stream = Data()
        for i in 0..<count {
            stream.append(try RinaLinkEncoder.encode(type: .setFrame, seq: UInt8(truncatingIfNeeded: i), payload: payload))
        }

        let decoder = RinaLinkDecoder()
        let clock = ContinuousClock()
        var decodedCount = 0
        let chunkSize = 1024
        let elapsed = clock.measure {
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decodedCount += decoder.feed(stream.subdata(in: offset..<end)).count
                offset = end
            }
        }
        XCTAssertEqual(decodedCount, count)
        report("C-chunked-1024-64B", frames: count, bytes: stream.count, elapsed: elapsed)
    }

    /// D: 2_000 frames, each preceded by 64 garbage bytes containing no 0xA5,
    /// fed in 512-byte chunks.
    func testCaseDGarbageResync() throws {
        let count = 2_000
        let payload = Data(repeating: 0x11, count: 24)
        let garbage = Data(repeating: 0x5A, count: 64) // 0x5A != 0xA5 magic
        var stream = Data()
        for i in 0..<count {
            stream.append(garbage)
            stream.append(try RinaLinkEncoder.encode(type: .setFrame, seq: UInt8(truncatingIfNeeded: i), payload: payload))
        }

        let decoder = RinaLinkDecoder()
        let clock = ContinuousClock()
        var decodedCount = 0
        let chunkSize = 512
        let elapsed = clock.measure {
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decodedCount += decoder.feed(stream.subdata(in: offset..<end)).count
                offset = end
            }
        }
        XCTAssertEqual(decodedCount, count)
        report("D-garbage-resync-512chunk", frames: count, bytes: stream.count, elapsed: elapsed)
    }

    /// E: 500 frames with 4096-byte payloads, fed in 4096-byte chunks.
    func testCaseELargePayloads() throws {
        let count = 500
        let payload = Data(repeating: 0x77, count: 4096)
        var stream = Data()
        for i in 0..<count {
            stream.append(try RinaLinkEncoder.encode(type: .setFrame, seq: UInt8(truncatingIfNeeded: i), payload: payload))
        }

        let decoder = RinaLinkDecoder()
        let clock = ContinuousClock()
        var decodedCount = 0
        let chunkSize = 4096
        let elapsed = clock.measure {
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decodedCount += decoder.feed(stream.subdata(in: offset..<end)).count
                offset = end
            }
        }
        XCTAssertEqual(decodedCount, count)
        report("E-large-payloads-4096B", frames: count, bytes: stream.count, elapsed: elapsed)
    }
}
