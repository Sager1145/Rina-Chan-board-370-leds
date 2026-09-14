import XCTest
import CoreGraphics
import SwiftUI
@testable import RinaBoard
@testable import RinaCore

private struct PR7BloomSplitMix64: RandomNumberGenerator {
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

/// A directed segment between two points, mapped back to integer grid-corner
/// coordinates via `layout` before comparison. `Path.applying` stores its
/// coordinates at `Float` precision (~1e-5 at this layout's magnitude), so
/// comparing raw view-space coordinates at a 1e-6 scale is too tight; corner
/// coordinates are exact integers in both the renderer and the reference, so
/// rounding the round-trip recovers them exactly.
private struct RoundedSegment: Hashable {
    let fromX, fromY, toX, toY: Int

    init(from: CGPoint, to: CGPoint, layout: LEDBoardLayout) {
        func corner(_ v: CGFloat, origin: CGFloat) -> Int {
            Int(((v - origin) / layout.cell).rounded())
        }
        fromX = corner(from.x, origin: layout.origin.x)
        fromY = corner(from.y, origin: layout.origin.y)
        toX = corner(to.x, origin: layout.origin.x)
        toY = corner(to.y, origin: layout.origin.y)
    }
}

private struct Multiset<T: Hashable>: Equatable {
    var counts: [T: Int] = [:]
    init(_ items: [T]) {
        for item in items { counts[item, default: 0] += 1 }
    }
}

final class LEDBloomRendererTests: XCTestCase {
    private let cols = MatrixGeometry.cols
    private let rows = MatrixGeometry.rows

    /// Non-trivial layout: origin (13.5, 7.25), cell 11.3, matching the app's
    /// own `LEDBoardLayout` construction (`.make(in:region:)`).
    private let layout = LEDBoardLayout(
        cell: 11.3,
        origin: CGPoint(x: 13.5, y: 7.25),
        stage: .zero,
        region: .wholeBoard
    )

    private func frame(litCells: Set<Int>) -> PackedFrame {
        var frame = PackedFrame()
        for led in 0..<MatrixGeometry.ledCount {
            guard let (x, y) = MatrixGeometry.xy(ofLed: led) else { continue }
            if litCells.contains(y * cols + x) {
                frame.set(led)
            }
        }
        return frame
    }

    private func randomFrame(density: Double, rng: inout PR7BloomSplitMix64) -> PackedFrame {
        var frame = PackedFrame()
        for led in 0..<MatrixGeometry.ledCount {
            if Double.random(in: 0..<1, using: &rng) < density {
                frame.set(led)
            }
        }
        return frame
    }

    /// Reference directed edges in corner space, ported from the pre-PR-7
    /// dictionary algorithm (same source of truth as
    /// `BloomContourReferencePR7` in RinaCoreTests), mapped through `layout`.
    private func referenceSegments(for frame: PackedFrame) -> [RoundedSegment] {
        struct Corner: Hashable {
            let x: Int
            let y: Int
            var key: Int { y * (MatrixGeometry.cols + 1) + x }
        }

        var lit = [Bool](repeating: false, count: cols * rows)
        var anyLit = false
        for led in 0..<MatrixGeometry.ledCount where frame[led] {
            guard let (x, y) = MatrixGeometry.xy(ofLed: led) else { continue }
            lit[y * cols + x] = true
            anyLit = true
        }
        guard anyLit else { return [] }

        func isLit(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < cols, y >= 0, y < rows else { return false }
            return lit[y * cols + x]
        }

        func point(_ corner: Corner) -> CGPoint {
            CGPoint(x: layout.origin.x + CGFloat(corner.x) * layout.cell,
                    y: layout.origin.y + CGFloat(corner.y) * layout.cell)
        }

        var segments: [RoundedSegment] = []
        func addEdge(_ from: Corner, _ to: Corner) {
            segments.append(RoundedSegment(from: point(from), to: point(to), layout: layout))
        }

        for y in 0..<rows {
            for x in 0..<cols where isLit(x, y) {
                if !isLit(x, y - 1) { addEdge(Corner(x: x, y: y), Corner(x: x + 1, y: y)) }
                if !isLit(x + 1, y) { addEdge(Corner(x: x + 1, y: y), Corner(x: x + 1, y: y + 1)) }
                if !isLit(x, y + 1) { addEdge(Corner(x: x + 1, y: y + 1), Corner(x: x, y: y + 1)) }
                if !isLit(x - 1, y) { addEdge(Corner(x: x, y: y + 1), Corner(x: x, y: y)) }
            }
        }
        return segments
    }

    /// Directed segments from a `Path`, treating `.closeSubpath` as a segment
    /// back to the subpath's start point when they differ.
    private func segments(of path: Path) -> [RoundedSegment] {
        var result: [RoundedSegment] = []
        var current: CGPoint = .zero
        var subpathStart: CGPoint = .zero
        path.forEach { element in
            switch element {
            case .move(let to):
                current = to
                subpathStart = to
            case .line(let to):
                result.append(RoundedSegment(from: current, to: to, layout: layout))
                current = to
            case .quadCurve(let to, _):
                result.append(RoundedSegment(from: current, to: to, layout: layout))
                current = to
            case .curve(let to, _, _):
                result.append(RoundedSegment(from: current, to: to, layout: layout))
                current = to
            case .closeSubpath:
                if current != subpathStart {
                    result.append(RoundedSegment(from: current, to: subpathStart, layout: layout))
                }
                current = subpathStart
            }
        }
        return result
    }

    private func assertMatchesReference(_ frame: PackedFrame, file: StaticString = #filePath, line: UInt = #line) {
        let path = LEDBloomRenderer.contourPath(frame: frame, layout: layout)
        let actual = Multiset(segments(of: path))
        let expected = Multiset(referenceSegments(for: frame))
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testEmptyFrame() {
        assertMatchesReference(PackedFrame())
    }

    func testAllLit() {
        var frame = PackedFrame()
        frame.fill()
        assertMatchesReference(frame)
    }

    func testSingleLED() {
        assertMatchesReference(frame(litCells: [4 * cols + 10]))
    }

    func testFilledBlock() {
        var cells = Set<Int>()
        for y in 4...7 {
            for x in 8...12 {
                cells.insert(y * cols + x)
            }
        }
        assertMatchesReference(frame(litCells: cells))
    }

    func testRingWithHole() {
        var cells = Set<Int>()
        for y in 3...9 {
            for x in 5...15 {
                let onBorder = y == 3 || y == 9 || x == 5 || x == 15
                if onBorder { cells.insert(y * cols + x) }
            }
        }
        assertMatchesReference(frame(litCells: cells))
    }

    func testCheckerboard() {
        var cells = Set<Int>()
        for y in 0..<rows {
            for x in 0..<cols where (x + y) % 2 == 0 {
                cells.insert(y * cols + x)
            }
        }
        assertMatchesReference(frame(litCells: cells))
    }

    func testDiagonallyTouchingCells() {
        assertMatchesReference(frame(litCells: [5 * cols + 5, 6 * cols + 6]))
    }

    func testRandomFrames() {
        var rng = PR7BloomSplitMix64(seed: 0xFEED_CAFE)
        for _ in 0..<100 {
            let density = Double.random(in: 0.05...0.95, using: &rng)
            assertMatchesReference(randomFrame(density: density, rng: &rng))
        }
    }

    func testRepeatedCallsReturnEqualPaths() {
        var cells = Set<Int>()
        for y in 4...7 {
            for x in 8...12 {
                cells.insert(y * cols + x)
            }
        }
        let frame = frame(litCells: cells)
        let first = LEDBloomRenderer.contourPath(frame: frame, layout: layout)
        let second = LEDBloomRenderer.contourPath(frame: frame, layout: layout)
        XCTAssertEqual(Multiset(segments(of: first)), Multiset(segments(of: second)))
    }

    /// The cache capacity is 8; alternating 10 distinct frames must still
    /// produce correct output for every one of them, cache pressure or not.
    func testAlternatingFramesBeyondCacheCapacity() {
        var rng = PR7BloomSplitMix64(seed: 0x1234_5678)
        var frames: [PackedFrame] = []
        for _ in 0..<10 {
            frames.append(randomFrame(density: 0.4, rng: &rng))
        }
        for _ in 0..<3 {
            for frame in frames {
                assertMatchesReference(frame)
            }
        }
    }
}
