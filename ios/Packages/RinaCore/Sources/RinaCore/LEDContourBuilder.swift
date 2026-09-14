import Foundation

/// Closed perimeter contours of a frame's lit regions, in grid-corner
/// coordinates (design guide §14).
///
/// A grid cell is lit iff an LED physically exists there *and* it is lit in
/// the frame. 4-connected lit cells form one luminous region; each region's
/// boundary is emitted clockwise in screen space (x right, y down), so outer
/// contours wind clockwise and hole contours wind counter-clockwise — a
/// single non-zero fill of all contours together leaves holes empty.
public struct LEDContours: Equatable, Sendable {
    /// Corner grid is one wider/taller than the cell grid: `cols + 1` columns.
    /// `key = y * cornerColumns + x`.
    public static let cornerColumns = MatrixGeometry.cols + 1
    private static let cornerRows = MatrixGeometry.rows + 1

    /// Corner keys, contours concatenated back to back. The start corner of
    /// each contour is not repeated at its end (the walk is implicitly
    /// closed back to `contourStarts[i]`).
    public let corners: [UInt16]
    /// Contour `i` spans `contourStarts[i] ..< (contourStarts[i + 1] or corners.count)`.
    public let contourStarts: [Int]

    public var isEmpty: Bool { contourStarts.isEmpty }

    public init(corners: [UInt16], contourStarts: [Int]) {
        self.corners = corners
        self.contourStarts = contourStarts
    }
}

/// Builds `LEDContours` for a `PackedFrame` without any dictionary or
/// per-edge heap allocation: occupancy and outgoing edges are both fixed-size
/// arrays sized to the board's real topology.
public enum LEDContourBuilder {
    private static let cols = MatrixGeometry.cols
    private static let rows = MatrixGeometry.rows
    private static let cornerColumns = LEDContours.cornerColumns
    private static let cornerCount = LEDContours.cornerColumns * (MatrixGeometry.rows + 1)

    /// LED index → grid cell, built once via `MatrixGeometry.xy(ofLed:)`.
    private static let ledCells: [(x: Int, y: Int)] = {
        var result = [(x: Int, y: Int)](repeating: (0, 0), count: MatrixGeometry.ledCount)
        for led in 0..<MatrixGeometry.ledCount {
            if let xy = MatrixGeometry.xy(ofLed: led) {
                result[led] = xy
            }
        }
        return result
    }()

    public static func contours(for frame: PackedFrame) -> LEDContours {
        // Occupancy mask over the real topology.
        var lit = [Bool](repeating: false, count: cols * rows)
        var anyLit = false
        for led in 0..<MatrixGeometry.ledCount where frame[led] {
            let (x, y) = ledCells[led]
            lit[y * cols + x] = true
            anyLit = true
        }
        guard anyLit else { return LEDContours(corners: [], contourStarts: []) }

        func isLit(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < cols, y >= 0, y < rows else { return false }
            return lit[y * cols + x]
        }

        // At most two outgoing edges per corner (the diagonal-pinch case).
        // -1 marks an empty slot.
        var outA = [Int16](repeating: -1, count: cornerCount)
        var outB = [Int16](repeating: -1, count: cornerCount)
        var edgeCount = 0

        @inline(__always) func cornerKey(_ x: Int, _ y: Int) -> Int { y * cornerColumns + x }

        @inline(__always) func addEdge(from: Int, to: Int) {
            if outA[from] < 0 {
                outA[from] = Int16(to)
            } else if outB[from] < 0 {
                outB[from] = Int16(to)
            } else {
                assertionFailure("corner \(from) already has two outgoing edges")
            }
            edgeCount += 1
        }

        for y in 0..<rows {
            for x in 0..<cols where isLit(x, y) {
                // Corners of this cell, clockwise: TL(x,y) TR(x+1,y) BR(x+1,y+1) BL(x,y+1).
                let tl = cornerKey(x, y)
                let tr = cornerKey(x + 1, y)
                let br = cornerKey(x + 1, y + 1)
                let bl = cornerKey(x, y + 1)
                if !isLit(x, y - 1) { addEdge(from: tl, to: tr) }
                if !isLit(x + 1, y) { addEdge(from: tr, to: br) }
                if !isLit(x, y + 1) { addEdge(from: br, to: bl) }
                if !isLit(x - 1, y) { addEdge(from: bl, to: tl) }
            }
        }
        guard edgeCount > 0 else { return LEDContours(corners: [], contourStarts: []) }

        var corners: [UInt16] = []
        corners.reserveCapacity(edgeCount)
        var contourStarts: [Int] = []
        var remaining = edgeCount

        @inline(__always) func takeEdge(from corner: Int) -> Int? {
            if outB[corner] >= 0 {
                let target = Int(outB[corner])
                outB[corner] = -1
                return target
            }
            if outA[corner] >= 0 {
                let target = Int(outA[corner])
                outA[corner] = -1
                return target
            }
            return nil
        }

        @inline(__always) func hasOutgoing(_ corner: Int) -> Bool {
            outA[corner] >= 0 || outB[corner] >= 0
        }

        for startKey in 0..<cornerCount where remaining > 0 && hasOutgoing(startKey) {
            contourStarts.append(corners.count)
            var current = startKey
            while let next = takeEdge(from: current) {
                remaining -= 1
                corners.append(UInt16(current))
                current = next
                if current == startKey { break }
            }
        }

        return LEDContours(corners: corners, contourStarts: contourStarts)
    }
}
