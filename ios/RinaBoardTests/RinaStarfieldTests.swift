import XCTest
@testable import RinaBoard

/// A `RandomNumberGenerator` that plays back a scripted sequence of `next()`
/// values, so `Math.random()`'s three draws per element (icon, move, left)
/// can be pinned to exact inputs.
private struct ScriptedGenerator: RandomNumberGenerator {
    var values: [UInt64]
    var index = 0

    mutating func next() -> UInt64 {
        defer { index += 1 }
        return values[index % values.count]
    }
}

final class RinaStarfieldTests: XCTestCase {
    // MARK: 1. Element count

    func testElementCountIsSixteen() {
        XCTAssertEqual(RinaStarfieldSourceSpec.elementCount, 16)
    }

    func testMakeElementsYieldsSixteenForSeveralSeedsAndWidths() {
        for seed: UInt64 in [0, 1, 42, .max, 0x5249_4E41_5354_4152] {
            for width in [1, 320, 402, 767, 768, 1080, 2000] {
                var generator = RinaSplitMix64(state: seed)
                let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: width)
                XCTAssertEqual(elements.count, 16, "seed \(seed) width \(width)")
            }
        }
    }

    // MARK: 2. Formula with a scripted RNG

    func testAllZeroRandomValuesYieldNilAppearanceMoveZeroLeftZero() {
        var generator = ScriptedGenerator(values: [0])
        let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: 402)
        for element in elements {
            XCTAssertNil(element.appearance)
            XCTAssertEqual(element.movement, .move0)
            XCTAssertEqual(element.leftPercent, 0)
        }
    }

    func testAllMaxRandomValuesYieldItem5Move15LeftHundred() {
        var generator = ScriptedGenerator(values: [UInt64.max])
        let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: 402)
        for element in elements {
            XCTAssertEqual(element.appearance, .item5)
            XCTAssertEqual(element.movement, .move15)
            XCTAssertEqual(element.leftPercent, 100)
        }
    }

    func testHalfRandomValuesYieldItem3Move8LeftFifty() {
        var generator = ScriptedGenerator(values: [1 << 63])
        let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: 402)
        for element in elements {
            XCTAssertEqual(element.appearance, .item3)
            XCTAssertEqual(element.movement, .move8)
            XCTAssertEqual(element.leftPercent, 50)
        }
    }

    // MARK: 3. Seeded layout, exact reference values

    func testSeededLayoutMatchesIndependentReference() {
        var generator = RinaSplitMix64(state: RinaStarfieldSourceSpec.snapshotSeed)
        let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: 402)
        let expected: [(Int, Int, Int)] = [
            (5, 7, 74), (2, 12, 10), (3, 15, 47), (2, 15, 19),
            (3, 2, 87), (5, 3, 72), (2, 5, 100), (4, 1, 92),
            (2, 8, 64), (2, 12, 33), (5, 6, 99), (4, 11, 70),
            (4, 3, 78), (1, 3, 48), (1, 2, 53), (2, 12, 83)
        ]
        XCTAssertEqual(elements.count, expected.count)
        for (element, (icon, move, left)) in zip(elements, expected) {
            XCTAssertEqual(element.appearance?.rawValue, icon)
            XCTAssertEqual(element.movement.rawValue, move)
            XCTAssertEqual(element.leftPercent, left)
        }
    }

    // MARK: 4. Many seeds stay within range

    func testManySeedsStayWithinRange() {
        for seed: UInt64 in stride(from: 0, to: 5000, by: 137) {
            var generator = RinaSplitMix64(state: seed)
            let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: 402)
            for element in elements {
                if let appearance = element.appearance {
                    XCTAssert((1...5).contains(appearance.rawValue))
                } // else icon == 0, which is valid too.
                XCTAssert((0...15).contains(element.movement.rawValue))
                XCTAssert((0...100).contains(element.leftPercent))
            }
        }
    }

    // MARK: 5. Appearance tables

    func testAppearanceStyleAtBaseBreakpoint() {
        let cases: [(RinaStarAppearance, Double, Double)] = [
            (.item1, 31, 31), (.item2, 31, 31), (.item3, 26, 27), (.item4, 20, 20), (.item5, 20, 20)
        ]
        for (appearance, width, height) in cases {
            let style = RinaStarAppearanceStyle.appearanceStyle(for: appearance, viewportWidth: 768)
            XCTAssertEqual(style.width, width)
            XCTAssertEqual(style.height, height)
            XCTAssertEqual(style.imageName, "RinaBackgroundStar\(appearance.rawValue)")
        }
    }

    func testAppearanceStyleAtSmallBreakpoint() {
        let cases: [(RinaStarAppearance, Double, Double)] = [
            (.item1, 16, 16), (.item2, 16, 16), (.item3, 14, 14), (.item4, 10, 10), (.item5, 10, 10)
        ]
        for (appearance, width, height) in cases {
            let style = RinaStarAppearanceStyle.appearanceStyle(for: appearance, viewportWidth: 767)
            XCTAssertEqual(style.width, width)
            XCTAssertEqual(style.height, height)
        }
    }

    func testAppearanceBreakpointBoundaries() {
        XCTAssertEqual(RinaStarAppearanceStyle.appearanceStyle(for: .item1, viewportWidth: 767).width, 16)
        XCTAssertEqual(RinaStarAppearanceStyle.appearanceStyle(for: .item1, viewportWidth: 767.5).width, 31)
        XCTAssertEqual(RinaStarAppearanceStyle.appearanceStyle(for: .item1, viewportWidth: 768).width, 31)
    }

    // MARK: 6. Motion table

    func testMotionStyleTable() {
        let expected: [RinaStarMovement: (TimeInterval, TimeInterval)] = [
            .move0: (12, 0), .move1: (14, 0.5), .move2: (16, 1), .move3: (18, 1.5),
            .move4: (20, 2), .move5: (22, 2.5), .move6: (24, 3), .move7: (26, 3.5),
            .move8: (28, 4), .move9: (30, 4.5), .move10: (32, 5), .move11: (34, 5.5),
            .move12: (36, 6), .move13: (38, 6.5), .move14: (40, 7), .move15: (42, 7.5)
        ]
        for movement in RinaStarMovement.allCases {
            let style = RinaStarMotionStyle.motionStyle(for: movement)
            let (duration, delay) = expected[movement]!
            XCTAssertEqual(style.duration, duration, "\(movement)")
            XCTAssertEqual(style.delay, delay, "\(movement)")
        }
    }

    // MARK: 7. Keyframe / spin selection by child index

    func testRiseKeyframesAndSpinDurationByChildIndex() {
        let expectedKeyframes: [RinaStarRiseKeyframes] = [
            .topAnm2, .topAnm, .topAnm3, .topAnm, .topAnm2, .topAnm3, .topAnm2, .topAnm,
            .topAnm3, .topAnm, .topAnm2, .topAnm3, .topAnm2, .topAnm, .topAnm3, .topAnm
        ]
        let expectedSpin: [TimeInterval] = [5, 6, 3, 6, 4, 3, 5, 6, 3, 4, 5, 3, 5, 6, 4, 6]
        for index in 1...16 {
            XCTAssertEqual(RinaStarRiseKeyframes.riseKeyframes(forChildIndex: index), expectedKeyframes[index - 1], "child \(index)")
            XCTAssertEqual(RinaStarRiseKeyframes.spinDuration(forChildIndex: index), expectedSpin[index - 1], "child \(index)")
        }
    }

    // MARK: 8. Left edge semantics

    func testLeftIsTheElementsLeftEdge() throws {
        let element = RinaStarSourceElement(appearance: .item1, movement: .move0, leftPercent: 96)
        let placement = try XCTUnwrap(RinaStarfield.placement(of: element, childIndex: 1, in: CGSize(width: 402, height: 874), time: 0))
        XCTAssertEqual(placement.rect.minX, 385.92, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.midX, 393.92, accuracy: 1e-9)
    }

    // MARK: 9. Bezier evaluator

    func testCubicBezierEvaluator() {
        let timing = RinaStarRiseKeyframes.timingFunction
        XCTAssertEqual(timing.solve(0.25), 0.383946, accuracy: 1e-5)
        XCTAssertEqual(timing.solve(0.5), 0.735739, accuracy: 1e-5)
        XCTAssertEqual(timing.solve(0.75), 0.943421, accuracy: 1e-5)
    }

    // MARK: 10. Keyframe samples

    func testKeyframeSamplesAcrossChildren() throws {
        let element = RinaStarSourceElement(appearance: .item1, movement: .move12, leftPercent: 14)
        let size = CGSize(width: 402, height: 874)

        func sample(childIndex: Int, fraction: Double) throws -> (top: Double, opacity: Double) {
            let time = 6 + fraction * 36
            let placement = try XCTUnwrap(RinaStarfield.placement(of: element, childIndex: childIndex, in: size, time: time))
            return (Double(placement.rect.minY), placement.opacity)
        }

        let fractions: [Double] = [0, 0.25, 0.5, 0.75, 0.8, 1 - 1e-9]

        let expectedChild1: [(Double, Double)] = [
            (1048.8, 0.3), (580.8467, 0.2041), (152.0809, 0.1278), (-101.0417, 0.1006), (-127.4915, 0.1), (-170, 0)
        ]
        let expectedChild2: [(Double, Double)] = [
            (917.7, 0.3), (526.9582, 0.2041), (168.9381, 0.1278), (-42.4197, 0.1006), (-64.5053, 0.1), (-100, 0)
        ]
        let expectedChild3: [(Double, Double)] = [
            (1311, 0.3), (742.3761, 0.2041), (221.37, 0.1278), (-86.2067, 0.1006), (-118.3466, 0.1), (-170, 0)
        ]

        for (fraction, expected) in zip(fractions, expectedChild1) {
            let (top, opacity) = try sample(childIndex: 1, fraction: fraction)
            XCTAssertEqual(top, expected.0, accuracy: 0.01, "child1 f=\(fraction)")
            XCTAssertEqual(opacity, expected.1, accuracy: 1e-3, "child1 f=\(fraction)")
        }
        for (fraction, expected) in zip(fractions, expectedChild2) {
            let (top, opacity) = try sample(childIndex: 2, fraction: fraction)
            XCTAssertEqual(top, expected.0, accuracy: 0.01, "child2 f=\(fraction)")
            XCTAssertEqual(opacity, expected.1, accuracy: 1e-3, "child2 f=\(fraction)")
        }
        for (fraction, expected) in zip(fractions, expectedChild3) {
            let (top, opacity) = try sample(childIndex: 3, fraction: fraction)
            XCTAssertEqual(top, expected.0, accuracy: 0.01, "child3 f=\(fraction)")
            XCTAssertEqual(opacity, expected.1, accuracy: 1e-3, "child3 f=\(fraction)")
        }

        // Before the delay elapses: child 1 (top_anm2), whose base `top:105%`
        // (917.7) differs from its own keyframe 0% (1048.8), so this can only
        // distinguish "not started yet" from "started" using a child whose
        // keyframes aren't top_anm (which shares the 105%/917.7 value).
        let beforeDelay = try XCTUnwrap(RinaStarfield.placement(of: element, childIndex: 1, in: size, time: 5.9))
        XCTAssertEqual(Double(beforeDelay.rect.minY), 917.7, accuracy: 0.01)
        XCTAssertEqual(beforeDelay.opacity, 1, accuracy: 1e-9)

        // Exact iteration boundary: back to the start values.
        let boundary = try XCTUnwrap(RinaStarfield.placement(of: element, childIndex: 1, in: size, time: 42))
        XCTAssertEqual(Double(boundary.rect.minY), 1048.8, accuracy: 0.01)
        XCTAssertEqual(boundary.opacity, 0.3, accuracy: 1e-3)

        // p=0.9: the eased second opacity segment, not a linear interpolation
        // (linear would give 0.05).
        let lateSegment = try XCTUnwrap(RinaStarfield.placement(of: element, childIndex: 1, in: size, time: 6 + 0.9 * 36))
        XCTAssertEqual(lateSegment.opacity, 0.0264, accuracy: 1e-3)
    }

    // MARK: 11. Rotation

    func testRotationIsIndependentOfDelayAndRunsFromTimeZero() throws {
        // move12 has a 6s delay, so tau < 0 at these times (the rise
        // animation hasn't started) — the span's spin still runs from t=0.
        let element1 = RinaStarSourceElement(appearance: .item1, movement: .move12, leftPercent: 0)

        // Child 1: spin duration 5s. At t=1.25s, quarter turn: -90deg.
        let placement1 = try XCTUnwrap(RinaStarfield.placement(of: element1, childIndex: 1, in: CGSize(width: 402, height: 874), time: 1.25))
        XCTAssertEqual(placement1.rotation.degrees, -90, accuracy: 1e-6)

        // Child 3: spin duration 3s. At t=1.5s, half turn: -180deg.
        let placement3 = try XCTUnwrap(RinaStarfield.placement(of: element1, childIndex: 3, in: CGSize(width: 402, height: 874), time: 1.5))
        XCTAssertEqual(placement3.rotation.degrees, -180, accuracy: 1e-6)
    }

    // MARK: 12. Reduce Motion frame

    func testReduceMotionFrameKeepsEveryStarBelowTheCanvas() {
        let size = CGSize(width: 402, height: 874)
        for seed: UInt64 in [1, 7, 99, 12345] {
            var generator = RinaSplitMix64(state: seed)
            let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: 402)
            for (index, element) in elements.enumerated() {
                guard let placement = RinaStarfield.placement(of: element, childIndex: index + 1, in: size, time: 0) else { continue }
                XCTAssertGreaterThanOrEqual(placement.rect.minY, size.height, "seed \(seed) index \(index)")
            }
        }
    }

    // MARK: 13. Snapshot frame

    func testSnapshotFrameHasFourteenDrawnPlacements() {
        var generator = RinaSplitMix64(state: RinaStarfieldSourceSpec.snapshotSeed)
        let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: 402)
        let size = CGSize(width: 402, height: 874)
        let bounds = CGRect(origin: .zero, size: size)
        var visible = 0
        for (index, element) in elements.enumerated() {
            guard let placement = RinaStarfield.placement(of: element, childIndex: index + 1, in: size, time: RinaStarfieldSourceSpec.snapshotTime) else { continue }
            if RinaStarfield.isDrawn(placement, in: bounds) {
                visible += 1
            }
        }
        // One element (child 7) sits exactly at the right edge (x == canvas
        // width); the inflated-rect predicate (draw-time culling) reaches it
        // even though a same-size intersects test would not, so this count
        // is one higher than a plain-rect / opacity>0.02 check would give.
        XCTAssertEqual(visible, 14)
    }

    // MARK: 14. Clock

    @MainActor
    func testAnimationClockDoesNotAdvanceWhilePaused() {
        let clock = RinaStarClock()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(clock.time(at: start), 0)

        clock.setRunning(true, at: start)
        clock.setRunning(true, at: start.addingTimeInterval(1)) // repeated report from a second backdrop
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(2)), 2, accuracy: 1e-9)

        clock.setRunning(false, at: start.addingTimeInterval(2))
        clock.setRunning(false, at: start.addingTimeInterval(3))
        // A 60 s pause (boot loader, Notification Center) adds nothing.
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(62)), 2, accuracy: 1e-9)

        clock.setRunning(true, at: start.addingTimeInterval(62))
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(62)), 2, accuracy: 1e-9)
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(63.5)), 3.5, accuracy: 1e-9)
    }
}
