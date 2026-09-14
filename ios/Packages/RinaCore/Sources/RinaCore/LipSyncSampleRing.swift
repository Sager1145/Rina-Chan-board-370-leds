import Foundation

/// Fixed-capacity circular buffer of mono samples for a real-time audio tap.
/// Writes copy straight into storage allocated once in `init`: no allocation,
/// no reallocation, no memmove — safe to call from a render callback (under the
/// caller's lock). Reads (`latest`) allocate their result; they run on the
/// consumer side.
///
/// `~Copyable` so the compiler enforces there is exactly one ring: any
/// attempt to alias it (`let alias = ring`) is a compile error instead of a
/// silent duplicate-storage bug.
public struct LipSyncSampleRing: ~Copyable {
    public let capacity: Int
    public private(set) var count: Int

    private var storage: [Float]
    private var writeIndex: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
        self.writeIndex = 0
        self.count = 0
    }

    /// Resets the logical contents of the ring. Storage is kept, so this
    /// never allocates.
    public mutating func removeAll() {
        writeIndex = 0
        count = 0
    }

    /// Copies `count` samples from `samples` into the ring, overwriting the
    /// oldest data once the ring is full. Never allocates.
    public mutating func write(_ samples: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }

        if n >= capacity {
            // Only the tail of this write can survive; it fills the ring.
            let source = samples + (n - capacity)
            storage.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: source, count: capacity)
            }
            writeIndex = 0
            count = capacity
            return
        }

        storage.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            let firstSegment = min(n, capacity - writeIndex)
            (base + writeIndex).update(from: samples, count: firstSegment)
            let remaining = n - firstSegment
            if remaining > 0 {
                base.update(from: samples + firstSegment, count: remaining)
            }
        }
        writeIndex = (writeIndex + n) % capacity
        self.count = min(capacity, self.count + n)
    }

    /// Mixes `channelCount` interleaved-by-channel float buffers down to mono
    /// (arithmetic-mean, matching the historical per-frame loop bit for bit)
    /// and writes the result straight into ring storage. Never allocates.
    public mutating func writeMixed(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frames: Int
    ) {
        guard frames > 0 else { return }

        if channelCount == 1 {
            write(channels[0], count: frames)
            return
        }

        // Only the last `capacity` frames can survive; skip mixing anything
        // that would be immediately overwritten.
        let startFrame = frames > capacity ? frames - capacity : 0
        let framesToWrite = frames - startFrame

        let destinationStart = framesToWrite >= capacity ? 0 : writeIndex

        // Mix straight into at most two contiguous runs of storage. Pointer
        // offsets (`+ destinationStart`, `+ startFrame`, ...) are hoisted
        // once per segment, outside the per-sample loop, so the loop body
        // itself is a flat `d[i] = (a[i] + b[i]) / 2` with no index math or
        // overflow checks per iteration.
        storage.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            let firstSegment = min(framesToWrite, capacity - destinationStart)
            let secondSegment = framesToWrite - firstSegment

            if channelCount == 2 {
                // Hand-unrolled stereo path: the runtime channel-count loop
                // below can't be unrolled by the optimizer since the trip
                // count isn't known at compile time. Stereo is by far the
                // common case for a microphone tap, so give it a form with a
                // fixed two-term sum instead. Same addition order and
                // division as the generic loop, so results match bit for
                // bit (module the sign of zero, which nobody depends on
                // here: `(a + b) / 2` versus `((0 + a) + b) / 2`).
                //
                // Verified with `swiftc -O -whole-module-optimization
                // -emit-assembly`: this loop compiles to NEON `fadd.4s` on
                // vector registers, i.e. it is actually auto-vectorized, not
                // just branch-free.
                let ch0 = channels[0]
                let ch1 = channels[1]

                let d0 = base + destinationStart
                let a0 = ch0 + startFrame
                let b0 = ch1 + startFrame
                for i in 0..<firstSegment {
                    d0[i] = (a0[i] + b0[i]) / 2
                }

                let a1 = ch0 + startFrame + firstSegment
                let b1 = ch1 + startFrame + firstSegment
                for i in 0..<secondSegment {
                    base[i] = (a1[i] + b1[i]) / 2
                }
                return
            }

            // Generic N-channel path (N == 1 is handled above via `write`,
            // so this covers N >= 3). `withUnsafeTemporaryAllocation` gets
            // per-channel pointers pre-offset by `startFrame`, stack
            // allocated, so the inner loop indexes with `i` alone instead of
            // recomputing `startFrame + i` for every channel on every frame.
            withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: channelCount) { offsets in
                for c in 0..<channelCount {
                    offsets[c] = channels[c] + startFrame
                }

                let d0 = base + destinationStart
                for i in 0..<firstSegment {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += offsets[c][i]
                    }
                    d0[i] = sum / Float(channelCount)
                }

                for i in 0..<secondSegment {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += offsets[c][firstSegment + i]
                    }
                    base[i] = sum / Float(channelCount)
                }
            }
        }

        if framesToWrite >= capacity {
            writeIndex = 0
            count = capacity
        } else {
            writeIndex = (writeIndex + framesToWrite) % capacity
            count = min(capacity, count + framesToWrite)
        }
    }

    /// The most recent `min(requested, count)` samples, oldest first.
    public func latest(_ requested: Int) -> [Float] {
        guard requested > 0, count > 0 else { return [] }
        let n = min(requested, count)
        // The oldest surviving sample sits `n` slots behind writeIndex,
        // wrapped into [0, capacity).
        let start = ((writeIndex - n) % capacity + capacity) % capacity

        return [Float](unsafeUninitializedCapacity: n) { buffer, initializedCount in
            guard let destBase = buffer.baseAddress else {
                initializedCount = 0
                return
            }
            storage.withUnsafeBufferPointer { source in
                let sourceBase = source.baseAddress!
                let firstSegment = min(n, capacity - start)
                destBase.update(from: sourceBase + start, count: firstSegment)
                let remaining = n - firstSegment
                if remaining > 0 {
                    destBase.advanced(by: firstSegment).update(from: sourceBase, count: remaining)
                }
            }
            initializedCount = n
        }
    }

    /// Test-only hook to verify storage is never reallocated.
    var storageBaseAddressForTesting: UnsafeRawPointer? {
        storage.withUnsafeBufferPointer { $0.baseAddress.map(UnsafeRawPointer.init) }
    }
}
