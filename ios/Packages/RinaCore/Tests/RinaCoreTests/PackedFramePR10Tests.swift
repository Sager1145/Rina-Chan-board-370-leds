import XCTest
@testable import RinaCore

/// PR-10: `PackedFrame.litCount`/`fill()`/`isEmpty` were changed from
/// bit-by-bit loops to byte-wise operations. These tests hold a private
/// bit-by-bit reference implementation of the old code and check the new
/// byte-wise implementation against it over many random frames, plus the
/// tail-bit invariant (top 6 bits of byte 46 must stay zero).
final class PackedFramePR10Tests: XCTestCase {
    /// Deterministic seeded RNG (SplitMix64), private to this file to avoid
    /// name collisions with other stages' test helpers at cherry-pick time.
    private struct PR10SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Old bit-by-bit `litCount` (pre-PR-10).
    private func referenceLitCount(_ frame: PackedFrame) -> Int {
        var count = 0
        for i in 0..<PackedFrame.ledCount where frame[i] {
            count += 1
        }
        return count
    }

    /// Old bit-by-bit `fill()` (pre-PR-10): set every LED individually via the
    /// bounds-checked subscript.
    private func referenceFill() -> PackedFrame {
        var frame = PackedFrame()
        for i in 0..<PackedFrame.ledCount { frame[i] = true }
        return frame
    }

    /// Builds a random frame by setting each LED independently with
    /// probability ~50%, using `set(_:)` (never touching bytes directly), so
    /// every frame produced here upholds the tail-zero invariant the same way
    /// production code does.
    private func randomFrame(using generator: inout PR10SplitMix64) -> PackedFrame {
        var frame = PackedFrame()
        for i in 0..<PackedFrame.ledCount where Bool.random(using: &generator) {
            frame.set(i)
        }
        return frame
    }

    func testLitCountMatchesBitByBitReferenceForManyRandomFrames() {
        var generator = PR10SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<500 {
            let frame = randomFrame(using: &generator)
            XCTAssertEqual(frame.litCount, referenceLitCount(frame))
        }
    }

    func testLitCountMatchesReferenceForEmptyAndFull() {
        XCTAssertEqual(PackedFrame().litCount, referenceLitCount(PackedFrame()))
        var full = PackedFrame()
        full.fill()
        XCTAssertEqual(full.litCount, referenceLitCount(full))
    }

    func testFillMatchesBitByBitReferenceByteForByte() {
        var fast = PackedFrame()
        fast.fill()
        let reference = referenceFill()
        XCTAssertEqual(fast.bytes, reference.bytes)
        XCTAssertEqual(fast, reference)
    }

    func testFillLeavesTailBitsZero() {
        var frame = PackedFrame()
        frame.fill()
        XCTAssertTrue(frame.validate())
        // Bits 370..375 are the top 6 bits of byte 46 (bit order is LSB-first
        // within a byte per PackedFrame's doc comment: byte 46 holds LEDs
        // 368/369 at bits 0/1).
        XCTAssertEqual(frame.bytes[PackedFrame.byteCount - 1] & 0b1111_1100, 0)
        XCTAssertEqual(frame.litCount, PackedFrame.ledCount)
    }

    func testIsEmptyForEmptyFrame() {
        XCTAssertTrue(PackedFrame().isEmpty)
    }

    func testIsEmptyFalseForSingleBitFirst() {
        var frame = PackedFrame()
        frame.set(0)
        XCTAssertFalse(frame.isEmpty)
    }

    func testIsEmptyFalseForSingleBitLast() {
        var frame = PackedFrame()
        frame.set(PackedFrame.ledCount - 1) // bit 369, last valid LED
        XCTAssertFalse(frame.isEmpty)
    }

    func testIsEmptyFalseForFullFrame() {
        var frame = PackedFrame()
        frame.fill()
        XCTAssertFalse(frame.isEmpty)
    }

    func testIsEmptyMatchesLitCountZeroForManyRandomFrames() {
        var generator = PR10SplitMix64(seed: 0x5EED_1234)
        for _ in 0..<500 {
            let frame = randomFrame(using: &generator)
            XCTAssertEqual(frame.isEmpty, frame.litCount == 0)
        }
        // Also cover the truly-empty and truly-full corners explicitly.
        XCTAssertEqual(PackedFrame().isEmpty, PackedFrame().litCount == 0)
        var full = PackedFrame()
        full.fill()
        XCTAssertEqual(full.isEmpty, full.litCount == 0)
    }
}
