import XCTest
@testable import RinaCore

/// PR-7 seeded RNG for this test file only.
private struct PR7SplitMix64: RandomNumberGenerator {
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

/// A directed edge in corner-key space, comparable/hashable for multiset
/// comparison.
private struct DirectedEdge: Hashable {
    let from: Int
    let to: Int
}

/// Ground truth for `LEDContourBuilder`: the dictionary-based algorithm as it
/// existed in `LEDBloomRenderer` before PR-7, reworked to emit directed edges
/// in corner-key space (`y * cornerColumns + x`) instead of a `Path`.
private enum BloomContourReferencePR7 {
    private struct Corner: Hashable {
        let x: Int
        let y: Int
        var key: Int { y * (MatrixGeometry.cols + 1) + x }
    }

    /// Returns the directed boundary edges (as corner keys) for `frame`.
    static func directedEdges(for frame: PackedFrame) -> [DirectedEdge] {
        let cols = MatrixGeometry.cols
        let rows = MatrixGeometry.rows

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

        var outgoing: [Int: [Corner]] = [:]
        var edges: [DirectedEdge] = []
        func addEdge(_ from: Corner, _ to: Corner) {
            outgoing[from.key, default: []].append(to)
            edges.append(DirectedEdge(from: from.key, to: to.key))
        }

        for y in 0..<rows {
            for x in 0..<cols where isLit(x, y) {
                if !isLit(x, y - 1) { addEdge(Corner(x: x, y: y), Corner(x: x + 1, y: y)) }
                if !isLit(x + 1, y) { addEdge(Corner(x: x + 1, y: y), Corner(x: x + 1, y: y + 1)) }
                if !isLit(x, y + 1) { addEdge(Corner(x: x + 1, y: y + 1), Corner(x: x, y: y + 1)) }
                if !isLit(x - 1, y) { addEdge(Corner(x: x, y: y + 1), Corner(x: x, y: y)) }
            }
        }
        return edges
    }
}

final class LEDContourBuilderTests: XCTestCase {
    private let cols = MatrixGeometry.cols
    private let rows = MatrixGeometry.rows
    private let cornerColumns = LEDContours.cornerColumns

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

    private func randomFrame(density: Double, rng: inout PR7SplitMix64) -> PackedFrame {
        var frame = PackedFrame()
        for led in 0..<MatrixGeometry.ledCount {
            if Double.random(in: 0..<1, using: &rng) < density {
                frame.set(led)
            }
        }
        return frame
    }

    /// Directed edges (consecutive corners plus the closing edge) from an
    /// `LEDContours` value.
    private func directedEdges(of contours: LEDContours) -> [DirectedEdge] {
        var edges: [DirectedEdge] = []
        let starts = contours.contourStarts
        for i in 0..<starts.count {
            let start = starts[i]
            let end = (i + 1 < starts.count) ? starts[i + 1] : contours.corners.count
            guard end > start else { continue }
            for j in start..<(end - 1) {
                edges.append(DirectedEdge(from: Int(contours.corners[j]), to: Int(contours.corners[j + 1])))
            }
            edges.append(DirectedEdge(from: Int(contours.corners[end - 1]), to: Int(contours.corners[start])))
        }
        return edges
    }

    private func assertMatchesReference(_ frame: PackedFrame, file: StaticString = #filePath, line: UInt = #line) {
        let contours = LEDContourBuilder.contours(for: frame)
        let actual = directedEdges(of: contours)
        let expected = BloomContourReferencePR7.directedEdges(for: frame)

        XCTAssertEqual(Multiset(actual), Multiset(expected), file: file, line: line)

        guard !expected.isEmpty else {
            XCTAssertTrue(contours.isEmpty, file: file, line: line)
            return
        }

        // Every contour has >= 4 corners and each step is a unit axis-aligned move.
        let starts = contours.contourStarts
        for i in 0..<starts.count {
            let start = starts[i]
            let end = (i + 1 < starts.count) ? starts[i + 1] : contours.corners.count
            XCTAssertGreaterThanOrEqual(end - start, 4, "contour \(i) too short", file: file, line: line)
            for j in start..<end {
                let current = Int(contours.corners[j])
                let nextIndex = (j + 1 < end) ? j + 1 : start
                let next = Int(contours.corners[nextIndex])
                let cx = current % cornerColumns, cy = current / cornerColumns
                let nx = next % cornerColumns, ny = next / cornerColumns
                let dx = abs(cx - nx), dy = abs(cy - ny)
                XCTAssertTrue((dx == 1 && dy == 0) || (dx == 0 && dy == 1),
                               "non-unit-axis step at contour \(i) index \(j)", file: file, line: line)
            }
        }
    }

    private struct Multiset<T: Hashable>: Equatable {
        var counts: [T: Int] = [:]
        init(_ items: [T]) {
            for item in items { counts[item, default: 0] += 1 }
        }
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

    func testLastShortestRowFullyLit() {
        // Row 17 is the shortest row (16 wide).
        var cells = Set<Int>()
        for led in 0..<MatrixGeometry.ledCount {
            guard let (x, y) = MatrixGeometry.xy(ofLed: led), y == rows - 1 else { continue }
            cells.insert(y * cols + x)
        }
        assertMatchesReference(frame(litCells: cells))
    }

    func testRandomFrames() {
        var rng = PR7SplitMix64(seed: 0xC0FFEE_7)
        let densities: [Double] = [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]
        for density in densities {
            for _ in 0..<30 {
                assertMatchesReference(randomFrame(density: density, rng: &rng))
            }
        }
    }
}
