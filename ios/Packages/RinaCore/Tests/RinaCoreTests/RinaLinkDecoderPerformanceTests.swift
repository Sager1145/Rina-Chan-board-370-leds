import XCTest
@testable import RinaCore

// Workloads shared by both decoder implementations. Each workload feeds a
// fixed sequence of chunks and counts the total decoded frames, which is
// then compared against the expected count.

private struct DecoderWorkload {
    let name: String
    let chunks: [Data]
    let expectedFrameCount: Int
}

private func makeFrame(payloadSize: Int, seq: UInt8) -> Data {
    let payload = Data(repeating: UInt8(seq & 0xFF), count: payloadSize)
    let frame = RinaLinkFrame(type: 0x01, seq: seq, flags: 0, payload: payload)
    return try! RinaLinkEncoder.encode(frame)
}

private func chunkedBytes(_ data: Data, size: Int) -> [Data] {
    guard size > 0 else { return [data] }
    var chunks: [Data] = []
    var offset = data.startIndex
    while offset < data.endIndex {
        let end = min(offset + size, data.endIndex)
        chunks.append(data.subdata(in: offset..<end))
        offset = end
    }
    return chunks
}

/// A: 100_000 frames with 16-byte payloads, one feed per frame.
private func workloadA() -> DecoderWorkload {
    let count = 100_000
    var chunks: [Data] = []
    chunks.reserveCapacity(count)
    for i in 0..<count {
        chunks.append(makeFrame(payloadSize: 16, seq: UInt8(i & 0xFF)))
    }
    return DecoderWorkload(name: "A(100k x16B, per-frame feed)", chunks: chunks, expectedFrameCount: count)
}

/// B: 2_000 frames with 32-byte payloads, fed 1 byte at a time.
private func workloadB() -> DecoderWorkload {
    let count = 2_000
    var stream = Data()
    for i in 0..<count {
        stream.append(makeFrame(payloadSize: 32, seq: UInt8(i & 0xFF)))
    }
    let chunks = chunkedBytes(stream, size: 1)
    return DecoderWorkload(name: "B(2k x32B, 1-byte feeds)", chunks: chunks, expectedFrameCount: count)
}

/// C: 20_000 frames with 64-byte payloads, fed in 1024-byte chunks.
private func workloadC() -> DecoderWorkload {
    let count = 20_000
    var stream = Data()
    for i in 0..<count {
        stream.append(makeFrame(payloadSize: 64, seq: UInt8(i & 0xFF)))
    }
    let chunks = chunkedBytes(stream, size: 1024)
    return DecoderWorkload(name: "C(20k x64B, 1024B chunks)", chunks: chunks, expectedFrameCount: count)
}

/// D: 2_000 frames, each after 64 garbage bytes without 0xA5, fed in 512-byte chunks.
private func workloadD() -> DecoderWorkload {
    let count = 2_000
    var stream = Data()
    var rng = RinaLinkFuzzRNG(seed: 12345)
    for i in 0..<count {
        for _ in 0..<64 {
            var byte = rng.nextByte()
            while byte == RinaLinkFrameConstants.magic {
                byte = rng.nextByte()
            }
            stream.append(byte)
        }
        stream.append(makeFrame(payloadSize: 20, seq: UInt8(i & 0xFF)))
    }
    let chunks = chunkedBytes(stream, size: 512)
    return DecoderWorkload(name: "D(2k frames after 64B garbage, 512B chunks)", chunks: chunks, expectedFrameCount: count)
}

/// E: 500 frames with 4096-byte payloads, fed in 4096-byte chunks.
private func workloadE() -> DecoderWorkload {
    let count = 500
    var stream = Data()
    for i in 0..<count {
        stream.append(makeFrame(payloadSize: 4096, seq: UInt8(i & 0xFF)))
    }
    let chunks = chunkedBytes(stream, size: 4096)
    return DecoderWorkload(name: "E(500 x4096B, 4096B chunks)", chunks: chunks, expectedFrameCount: count)
}

private func runReference(_ workload: DecoderWorkload) -> Int {
    let decoder = ReferenceRinaLinkDecoder()
    var total = 0
    for chunk in workload.chunks {
        total += decoder.feed(chunk).count
    }
    return total
}

private func runCursor(_ workload: DecoderWorkload) -> Int {
    let decoder = RinaLinkDecoder()
    var total = 0
    for chunk in workload.chunks {
        total += decoder.feed(chunk).count
    }
    return total
}

/// Runs `body` `runs` times (after a warm-up) and returns the shortest duration.
private func bestOf3<T>(warmup: () -> T, body: () -> T) -> (result: T, duration: Duration) {
    _ = warmup()

    var best: Duration?
    var lastResult: T!
    for _ in 0..<3 {
        let clock = ContinuousClock()
        let start = clock.now
        lastResult = body()
        let elapsed = clock.now - start
        if best == nil || elapsed < best! {
            best = elapsed
        }
    }
    return (lastResult, best!)
}

final class RinaLinkDecoderPerformanceTests: XCTestCase {

    func testBenchmarkAllWorkloads() {
        let workloads = [workloadA(), workloadB(), workloadC(), workloadD(), workloadE()]

        for workload in workloads {
            let (refCount, refDuration) = bestOf3(warmup: { runReference(workload) }, body: { runReference(workload) })
            let (curCount, curDuration) = bestOf3(warmup: { runCursor(workload) }, body: { runCursor(workload) })

            XCTAssertEqual(refCount, workload.expectedFrameCount, "\(workload.name) reference frame count")
            XCTAssertEqual(curCount, workload.expectedFrameCount, "\(workload.name) cursor frame count")

            let refFramesPerSecond = Double(workload.expectedFrameCount) / refDuration.inSeconds
            let curFramesPerSecond = Double(workload.expectedFrameCount) / curDuration.inSeconds
            let ratio = curFramesPerSecond / refFramesPerSecond

            print(String(
                format: "[DecoderBench] %@ reference=%.0f cursor=%.0f ratio=%.2fx",
                workload.name, refFramesPerSecond, curFramesPerSecond, ratio
            ))

            #if !DEBUG
            if ProcessInfo.processInfo.environment["RINA_PERF_GATE"] != nil {
                let minimumRatio: Double = (workload.name.hasPrefix("B") || workload.name.hasPrefix("D")) ? 1.5 : 0.8
                XCTAssertGreaterThanOrEqual(
                    ratio, minimumRatio,
                    "\(workload.name) cursor decoder must be at least \(minimumRatio)x the reference decoder's throughput"
                )
            }
            #endif
        }
    }
}

private extension Duration {
    var inSeconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
