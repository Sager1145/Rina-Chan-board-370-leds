import XCTest
@testable import RinaCore

/// PR-7 performance gate: reference (dictionary-of-arrays edge chaining,
/// building comparable output arrays) vs the array-based `LEDContourBuilder`.
/// Skipped unless `RINA_PERF_GATE=1`, and only asserts a speed ratio in
/// release builds, since debug builds are dominated by bounds-check/ARC
/// overhead that a cache-free array rewrite does not change proportionally.
final class LEDContourBuilderPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["RINA_PERF_GATE"] == "1" else {
            throw XCTSkip("set RINA_PERF_GATE=1 to run")
        }
    }

    private func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double) {
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        return (p50, sorted[p95Index])
    }

    private func interleavedTimings(iterations: Int,
                                    reference: () -> Void,
                                    engine: () -> Void) -> (reference: (p50: Double, p95: Double), engine: (p50: Double, p95: Double)) {
        for _ in 0..<5 {
            reference()
            engine()
        }
        let clock = ContinuousClock()
        var referenceSamples: [Double] = []
        var engineSamples: [Double] = []
        referenceSamples.reserveCapacity(iterations)
        engineSamples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            referenceSamples.append(millis(clock.measure(reference)))
            engineSamples.append(millis(clock.measure(engine)))
        }
        return (percentiles(referenceSamples), percentiles(engineSamples))
    }

    private func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private struct PR7PerfSplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func randomFrame(density: Double, seed: UInt64) -> PackedFrame {
        var rng = PR7PerfSplitMix64(seed: seed)
        var frame = PackedFrame()
        for led in 0..<MatrixGeometry.ledCount {
            if Double.random(in: 0..<1, using: &rng) < density {
                frame.set(led)
            }
        }
        return frame
    }

    /// Same directed-edge collection as the reference in
    /// `LEDContourBuilderTests`, but also chains edges into contour arrays
    /// (`corners`/`starts`) so the comparison covers comparable output, not
    /// just edge collection.
    private struct Corner: Hashable {
        let x: Int
        let y: Int
        var key: Int { y * (MatrixGeometry.cols + 1) + x }
    }

    private func referenceContours(for frame: PackedFrame) -> (corners: [Int], starts: [Int]) {
        let cols = MatrixGeometry.cols
        let rows = MatrixGeometry.rows

        var lit = [Bool](repeating: false, count: cols * rows)
        var anyLit = false
        for led in 0..<MatrixGeometry.ledCount where frame[led] {
            guard let (x, y) = MatrixGeometry.xy(ofLed: led) else { continue }
            lit[y * cols + x] = true
            anyLit = true
        }
        guard anyLit else { return ([], []) }

        func isLit(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < cols, y >= 0, y < rows else { return false }
            return lit[y * cols + x]
        }

        var outgoing: [Int: [Corner]] = [:]
        var edgeCount = 0
        func addEdge(_ from: Corner, _ to: Corner) {
            outgoing[from.key, default: []].append(to)
            edgeCount += 1
        }

        for y in 0..<rows {
            for x in 0..<cols where isLit(x, y) {
                if !isLit(x, y - 1) { addEdge(Corner(x: x, y: y), Corner(x: x + 1, y: y)) }
                if !isLit(x + 1, y) { addEdge(Corner(x: x + 1, y: y), Corner(x: x + 1, y: y + 1)) }
                if !isLit(x, y + 1) { addEdge(Corner(x: x + 1, y: y + 1), Corner(x: x, y: y + 1)) }
                if !isLit(x - 1, y) { addEdge(Corner(x: x, y: y + 1), Corner(x: x, y: y)) }
            }
        }
        guard edgeCount > 0 else { return ([], []) }

        var corners: [Int] = []
        var starts: [Int] = []
        var remaining = edgeCount
        while remaining > 0 {
            guard let startKey = outgoing.first(where: { !$0.value.isEmpty })?.key else { break }
            starts.append(corners.count)
            var current = startKey
            corners.append(current)
            while let next = outgoing[current]?.popLast() {
                remaining -= 1
                if outgoing[current]?.isEmpty == true { outgoing[current] = nil }
                current = next.key
                if current == startKey { break }
                corners.append(current)
            }
        }
        return (corners, starts)
    }

    private func runBench(density: Double) {
        let frame = randomFrame(density: density, seed: UInt64(density * 1_000_000) &+ 1)

        let (referenceResult, engineResult) = interleavedTimings(
            iterations: 300,
            reference: { _ = self.referenceContours(for: frame) },
            engine: { _ = LEDContourBuilder.contours(for: frame) }
        )

        print("[ContourBench density=\(density)] reference p50=\(String(format: "%.4f", referenceResult.p50)) p95=\(String(format: "%.4f", referenceResult.p95)) builder p50=\(String(format: "%.4f", engineResult.p50)) p95=\(String(format: "%.4f", engineResult.p95)) ratioP50=\(String(format: "%.4f", engineResult.p50 / referenceResult.p50))")

        #if !DEBUG
        XCTAssertLessThanOrEqual(engineResult.p50, 0.5 * referenceResult.p50)
        #endif
    }

    func testContoursRatioDensity30() {
        runBench(density: 0.3)
    }

    func testContoursRatioDensity60() {
        runBench(density: 0.6)
    }
}
