import XCTest
@testable import RinaCore

/// A plain-array reference model using the historical append + removeFirst
/// semantics, used to check `LipSyncSampleRing` behaves identically.
private struct ReferenceRing {
    let capacity: Int
    var storage: [Float] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func write(_ samples: [Float]) {
        storage.append(contentsOf: samples)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }

    func latest(_ requested: Int) -> [Float] {
        guard requested > 0 else { return [] }
        return storage.count > requested ? Array(storage.suffix(requested)) : storage
    }
}

/// Deterministic PRNG so the fuzz test is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Holds a ring the same way `LipSyncAudioCapture` does: a stored `var` on a
/// class. Used by the storage-stability test so it exercises the same
/// ownership shape as production code.
private final class RingHolder {
    var ring: LipSyncSampleRing
    init(capacity: Int) {
        ring = LipSyncSampleRing(capacity: capacity)
    }
}

/// The old sum-then-divide loop, kept as the ground truth for `writeMixed`'s
/// arithmetic regardless of channel count.
private func referenceMix(_ channels: [[Float]], frames: Int) -> [Float] {
    let channelCount = channels.count
    var mono = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
        var sum: Float = 0
        for channel in 0..<channelCount {
            sum += channels[channel][frame]
        }
        mono[frame] = sum / Float(channelCount)
    }
    return mono
}

/// Opens `withUnsafeBufferPointer` on every channel in turn and hands the
/// resulting raw pointers to `body`, so tests can call `writeMixed` for an
/// arbitrary number of channels without hand-nesting closures per call site.
private func withChannelPointers<R>(
    _ channels: [[Float]],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<Float>>, Int) -> R
) -> R {
    func recurse(_ index: Int, _ acc: [UnsafeMutablePointer<Float>]) -> R {
        if index == channels.count {
            var pointers = acc
            return pointers.withUnsafeMutableBufferPointer { pp in
                body(pp.baseAddress!, channels.count)
            }
        }
        return channels[index].withUnsafeBufferPointer { buf in
            recurse(index + 1, acc + [UnsafeMutablePointer(mutating: buf.baseAddress!)])
        }
    }
    return recurse(0, [])
}

/// Test helper: writes `samples` into `ring` via the mono fast path.
private func write(_ ring: inout LipSyncSampleRing, _ samples: [Float]) {
    samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
}

/// Test helper: mixes `channels` (one array per channel, all the same
/// length) and writes the result into `ring`.
private func writeMixed(_ ring: inout LipSyncSampleRing, channels: [[Float]], frames: Int) {
    withChannelPointers(channels) { pointer, channelCount in
        ring.writeMixed(pointer, channelCount: channelCount, frames: frames)
    }
}

final class LipSyncSampleRingTests: XCTestCase {

    // MARK: Basic unit cases

    func testEmpty() {
        let ring = LipSyncSampleRing(capacity: 8)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.latest(4), [])
    }

    func testFewerThanCapacity() {
        var ring = LipSyncSampleRing(capacity: 8)
        write(&ring, [1, 2, 3])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.latest(3), [1, 2, 3])
    }

    func testExactlyCapacity() {
        var ring = LipSyncSampleRing(capacity: 4)
        write(&ring, [1, 2, 3, 4])
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.latest(4), [1, 2, 3, 4])
    }

    func testWrapsOnce() {
        var ring = LipSyncSampleRing(capacity: 4)
        write(&ring, [1, 2, 3, 4])
        write(&ring, [5, 6])
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.latest(4), [3, 4, 5, 6])
    }

    func testWrapsManyTimes() {
        var ring = LipSyncSampleRing(capacity: 3)
        var reference = ReferenceRing(capacity: 3)
        for i in 0..<20 {
            let chunk: [Float] = [Float(i)]
            write(&ring, chunk)
            reference.write(chunk)
        }
        XCTAssertEqual(ring.latest(3), reference.latest(3))
    }

    func testLatestVariants() {
        var ring = LipSyncSampleRing(capacity: 8)
        write(&ring, [1, 2, 3, 4, 5])

        XCTAssertEqual(ring.latest(3), [3, 4, 5]) // N < count
        XCTAssertEqual(ring.latest(5), [1, 2, 3, 4, 5]) // N == count
        XCTAssertEqual(ring.latest(10), [1, 2, 3, 4, 5]) // N > count
        XCTAssertEqual(ring.latest(0), []) // N == 0
    }

    func testSingleWriteLargerThanCapacity() {
        var ring = LipSyncSampleRing(capacity: 4)
        write(&ring, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.latest(4), [4, 5, 6, 7])
    }

    func testRemoveAllThenWrite() {
        var ring = LipSyncSampleRing(capacity: 4)
        write(&ring, [1, 2, 3, 4])
        ring.removeAll()
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.latest(4), [])

        write(&ring, [9, 8])
        XCTAssertEqual(ring.latest(4), [9, 8])
    }

    // MARK: writeMixed

    func testWriteMixedTwoChannels() {
        let frames = 6
        let channelA: [Float] = [1, 2, 3, 4, 5, 6]
        let channelB: [Float] = [10, 20, 30, 40, 50, 60]
        let expected = referenceMix([channelA, channelB], frames: frames)

        var ring = LipSyncSampleRing(capacity: 16)
        writeMixed(&ring, channels: [channelA, channelB], frames: frames)
        XCTAssertEqual(ring.latest(frames), expected)
    }

    func testWriteMixedThreeChannels() {
        let frames = 5
        let channelA: [Float] = [1, 2, 3, 4, 5]
        let channelB: [Float] = [10, 20, 30, 40, 50]
        let channelC: [Float] = [100, 200, 300, 400, 500]
        let expected = referenceMix([channelA, channelB, channelC], frames: frames)

        var ring = LipSyncSampleRing(capacity: 16)
        writeMixed(&ring, channels: [channelA, channelB, channelC], frames: frames)
        XCTAssertEqual(ring.latest(frames), expected)
    }

    func testWriteMixedOneChannelEqualsWrite() {
        let frames = 5
        let channelA: [Float] = [1, 2, 3, 4, 5]

        var ringA = LipSyncSampleRing(capacity: 16)
        write(&ringA, channelA)

        var ringB = LipSyncSampleRing(capacity: 16)
        writeMixed(&ringB, channels: [channelA], frames: frames)

        XCTAssertEqual(ringA.latest(frames), ringB.latest(frames))
    }

    // MARK: 3+ channel edge cases (generic path)

    func testThreeChannelWrapsAroundPartiallyFilledRing() {
        let capacity = 6
        var ring = LipSyncSampleRing(capacity: capacity)
        var reference = ReferenceRing(capacity: capacity)

        // Move writeIndex to 2 without filling the ring.
        let seed: [Float] = [1, 2]
        write(&ring, seed)
        reference.write(seed)

        // 5 frames on top of writeIndex=2, capacity=6: 4 fit before the
        // wrap, 1 wraps to the front.
        let channelA: [Float] = [10, 20, 30, 40, 50]
        let channelB: [Float] = [100, 200, 300, 400, 500]
        let channelC: [Float] = [1000, 2000, 3000, 4000, 5000]
        let channels = [channelA, channelB, channelC]
        let expectedMono = referenceMix(channels, frames: 5)

        writeMixed(&ring, channels: channels, frames: 5)
        reference.write(expectedMono)

        XCTAssertEqual(ring.count, reference.storage.count)
        XCTAssertEqual(ring.latest(capacity), reference.latest(capacity))
    }

    func testThreeChannelFramesExceedCapacity() {
        let capacity = 4
        var ring = LipSyncSampleRing(capacity: capacity)
        var reference = ReferenceRing(capacity: capacity)

        let frames = 9
        let channelA = (0..<frames).map { Float($0) }
        let channelB = (0..<frames).map { Float($0) * 10 }
        let channelC = (0..<frames).map { Float($0) * 100 }
        let channels = [channelA, channelB, channelC]
        let expectedMono = referenceMix(channels, frames: frames)

        writeMixed(&ring, channels: channels, frames: frames)
        reference.write(expectedMono)

        XCTAssertEqual(ring.count, capacity)
        XCTAssertEqual(ring.latest(capacity), reference.latest(capacity))
    }

    func testExactlyCapacityWriteWithNonZeroWriteIndexMono() {
        let capacity = 5
        var ring = LipSyncSampleRing(capacity: capacity)
        var reference = ReferenceRing(capacity: capacity)

        let seed: [Float] = [-1, -2]
        write(&ring, seed)
        reference.write(seed)

        let fullWrite: [Float] = [1, 2, 3, 4, 5]
        write(&ring, fullWrite)
        reference.write(fullWrite)

        XCTAssertEqual(ring.count, capacity)
        XCTAssertEqual(ring.latest(capacity), reference.latest(capacity))
        XCTAssertEqual(ring.latest(capacity), fullWrite)
    }

    func testExactlyCapacityWriteWithNonZeroWriteIndexStereo() {
        let capacity = 5
        var ring = LipSyncSampleRing(capacity: capacity)
        var reference = ReferenceRing(capacity: capacity)

        let seed: [Float] = [-1, -2]
        write(&ring, seed)
        reference.write(seed)

        let channelA: [Float] = [1, 2, 3, 4, 5]
        let channelB: [Float] = [10, 20, 30, 40, 50]
        let channels = [channelA, channelB]
        let expectedMono = referenceMix(channels, frames: capacity)

        writeMixed(&ring, channels: channels, frames: capacity)
        reference.write(expectedMono)

        XCTAssertEqual(ring.count, capacity)
        XCTAssertEqual(ring.latest(capacity), reference.latest(capacity))
        XCTAssertEqual(ring.latest(capacity), expectedMono)
    }

    // MARK: Differential fuzz

    func testDifferentialFuzz() {
        for capacity in [7, 1024, 12_288] {
            var rng = SplitMix64(seed: UInt64(capacity) &+ 1)
            var ring = LipSyncSampleRing(capacity: capacity)
            var reference = ReferenceRing(capacity: capacity)

            for iteration in 0..<2_000 {
                let size = Int.random(in: 1...3_000, using: &rng)
                let channelCount = [1, 2, 3].randomElement(using: &rng)!

                var channels: [[Float]] = []
                for _ in 0..<channelCount {
                    var channel = [Float](repeating: 0, count: size)
                    for i in 0..<size {
                        channel[i] = Float.random(in: -1...1, using: &rng)
                    }
                    channels.append(channel)
                }
                let expectedMono = referenceMix(channels, frames: size)

                writeMixed(&ring, channels: channels, frames: size)
                reference.write(expectedMono)

                let r = Int.random(in: 0...(capacity + 10), using: &rng)
                XCTAssertEqual(
                    ring.latest(r), reference.latest(r),
                    "capacity=\(capacity) iteration=\(iteration) channelCount=\(channelCount) r=\(r)"
                )

                if iteration % 137 == 0 {
                    ring.removeAll()
                    reference.removeAll()
                }
            }
        }
    }

    // MARK: Storage stability

    func testStorageAddressStableAcrossWrites() {
        let holder = RingHolder(capacity: 12_288)
        let originalAddress = holder.ring.storageBaseAddressForTesting

        let chunk = [Float](repeating: 0.5, count: 1_024)
        for i in 0..<10_000 {
            chunk.withUnsafeBufferPointer { holder.ring.write($0.baseAddress!, count: $0.count) }
            if i == 5_000 {
                holder.ring.removeAll()
            }
            XCTAssertEqual(holder.ring.storageBaseAddressForTesting, originalAddress)
        }
    }
}

// MARK: - Performance benchmark

final class LipSyncSampleRingPerformanceTests: XCTestCase {

    private static let capacity = 12_288
    private static let callbackFrames = 1_024
    private static let callbackCount = 20_000

    private func referenceRun() {
        var storage = [Float]()
        storage.reserveCapacity(Self.capacity * 2)
        let channelA = [Float](repeating: 0.1, count: Self.callbackFrames)
        let channelB = [Float](repeating: 0.2, count: Self.callbackFrames)

        for _ in 0..<Self.callbackCount {
            var mono = [Float](repeating: 0, count: Self.callbackFrames)
            for frame in 0..<Self.callbackFrames {
                var sum: Float = 0
                sum += channelA[frame]
                sum += channelB[frame]
                mono[frame] = sum / 2
            }
            storage.append(contentsOf: mono)
            if storage.count > Self.capacity {
                storage.removeFirst(storage.count - Self.capacity)
            }
        }
    }

    private func ringRun() {
        var ring = LipSyncSampleRing(capacity: Self.capacity)
        let channelA = [Float](repeating: 0.1, count: Self.callbackFrames)
        let channelB = [Float](repeating: 0.2, count: Self.callbackFrames)

        channelA.withUnsafeBufferPointer { bufA in
            channelB.withUnsafeBufferPointer { bufB in
                var pointers: [UnsafeMutablePointer<Float>] = [
                    UnsafeMutablePointer(mutating: bufA.baseAddress!),
                    UnsafeMutablePointer(mutating: bufB.baseAddress!)
                ]
                pointers.withUnsafeMutableBufferPointer { pp in
                    for _ in 0..<Self.callbackCount {
                        ring.writeMixed(pp.baseAddress!, channelCount: 2, frames: Self.callbackFrames)
                    }
                }
            }
        }
    }

    private func bestOf(_ runs: Int, _ body: () -> Void) -> Duration {
        var best: Duration?
        for _ in 0..<runs {
            let clock = ContinuousClock()
            let elapsed = clock.measure { body() }
            if best == nil || elapsed < best! {
                best = elapsed
            }
        }
        return best!
    }

    /// This benchmark runs 20k simulated audio callbacks and takes ~15s+;
    /// it is opt-in via `RINA_PERF_GATE` so routine `swift test` runs stay
    /// fast. Set `RINA_PERF_GATE=1` to run it (and, in a release build, to
    /// enforce the ratio assertion below).
    func testRingIsFasterThanReferenceAlgorithm() throws {
        guard ProcessInfo.processInfo.environment["RINA_PERF_GATE"] != nil else {
            throw XCTSkip("set RINA_PERF_GATE=1 to run")
        }

        // Warm-up (JIT/caching effects, not measured).
        referenceRun()
        ringRun()

        let referenceDuration = bestOf(3) { self.referenceRun() }
        let ringDuration = bestOf(3) { self.ringRun() }

        let referenceMillis = Double(referenceDuration.components.seconds) * 1000
            + Double(referenceDuration.components.attoseconds) / 1e15
        let ringMillis = Double(ringDuration.components.seconds) * 1000
            + Double(ringDuration.components.attoseconds) / 1e15
        let ratio = ringMillis > 0 ? referenceMillis / ringMillis : .infinity

        print("[RingBench] reference=\(referenceMillis)ms ring=\(ringMillis)ms ratio=\(ratio)x")

        #if !DEBUG
        XCTAssertGreaterThanOrEqual(ratio, 1.0)
        #endif
    }
}
