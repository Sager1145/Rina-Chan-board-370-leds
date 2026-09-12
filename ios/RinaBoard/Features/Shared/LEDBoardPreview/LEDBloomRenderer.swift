import SwiftUI
import RinaCore

/// Perimeter bloom for the LED preview (design guide §14).
///
/// Bloom is **not** applied per LED. Lit LEDs are treated as a binary
/// occupancy mask over the board's real topology; 4-connected lit cells form
/// one luminous region, and the glow follows that region's perimeter. Because
/// the contour is built from *full* grid cells (not the inset LED squares),
/// neighbouring LEDs merge into a single shape instead of sixteen separate
/// glowing squares, and interior holes keep their own inner contour — so a
/// ring of lit LEDs glows both outwards and into the hole, while the hole
/// itself stays unlit (§14.2).
///
/// The whole board is blurred in two layer passes regardless of how many LEDs
/// are lit, never one blur per LED (§14.4 step 9, §44).
enum LEDBloomRenderer {

    /// A corner of the grid, addressed in cell-corner coordinates
    /// (`0...cols` × `0...rows`), packed into one Int for cheap hashing.
    private struct Corner: Hashable {
        let x: Int
        let y: Int

        var key: Int { y * (LEDBoardGeometry.cols + 1) + x }
    }

    /// Builds the closed perimeter contours of every connected lit region.
    ///
    /// Algorithm (§14.4): collect the occupancy mask, emit each lit cell's
    /// boundary sides as directed edges (shared edges between two lit cells
    /// are never emitted, so they cancel by construction), then chain the
    /// edges head-to-tail into closed contours. Emitting each cell's sides
    /// clockwise in screen space makes outer contours wind clockwise and hole
    /// contours wind counter-clockwise, so a single non-zero fill of the
    /// resulting path leaves holes empty.
    static func contourPath(frame: PackedFrame, layout: LEDBoardLayout) -> Path {
        let cols = LEDBoardGeometry.cols
        let rows = LEDBoardGeometry.rows

        // Occupancy mask over the real topology: a position is active only if
        // an LED physically exists there *and* it is lit.
        var lit = [Bool](repeating: false, count: cols * rows)
        var anyLit = false
        for cell in LEDBoardGeometry.cells where frame[cell.id] {
            lit[cell.gridY * cols + cell.gridX] = true
            anyLit = true
        }
        guard anyLit else { return Path() }

        func isLit(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < cols, y >= 0, y < rows else { return false }
            return lit[y * cols + x]
        }

        // Directed boundary edges, keyed by their start corner. A vertex can
        // have more than one outgoing edge where two regions touch only
        // diagonally; any consistent choice still yields closed contours.
        var outgoing: [Int: [Corner]] = [:]
        var edgeCount = 0
        func addEdge(_ from: Corner, _ to: Corner) {
            outgoing[from.key, default: []].append(to)
            edgeCount += 1
        }

        for y in 0..<rows {
            for x in 0..<cols where isLit(x, y) {
                // A side is on the boundary when the neighbour across it is
                // inactive or absent (§14.4 step 4). 4-directional adjacency:
                // diagonally touching LEDs stay separate regions (§14.3).
                if !isLit(x, y - 1) { addEdge(Corner(x: x, y: y), Corner(x: x + 1, y: y)) }
                if !isLit(x + 1, y) { addEdge(Corner(x: x + 1, y: y), Corner(x: x + 1, y: y + 1)) }
                if !isLit(x, y + 1) { addEdge(Corner(x: x + 1, y: y + 1), Corner(x: x, y: y + 1)) }
                if !isLit(x - 1, y) { addEdge(Corner(x: x, y: y + 1), Corner(x: x, y: y)) }
            }
        }
        guard edgeCount > 0 else { return Path() }

        func point(_ corner: Corner) -> CGPoint {
            CGPoint(x: layout.origin.x + CGFloat(corner.x) * layout.cell,
                    y: layout.origin.y + CGFloat(corner.y) * layout.cell)
        }

        var path = Path()
        var remaining = edgeCount
        // Walk contours by repeatedly consuming an unused outgoing edge and
        // following the chain until it returns to the starting corner.
        while remaining > 0 {
            guard let startKey = outgoing.first(where: { !$0.value.isEmpty })?.key else { break }
            let startX = startKey % (cols + 1)
            let startY = startKey / (cols + 1)
            var current = Corner(x: startX, y: startY)
            path.move(to: point(current))

            while let next = outgoing[current.key]?.popLast() {
                remaining -= 1
                if outgoing[current.key]?.isEmpty == true { outgoing[current.key] = nil }
                path.addLine(to: point(next))
                current = next
                if current.key == startKey { break }
            }
            path.closeSubpath()
        }
        return path
    }

    /// Draws the bloom underneath the LED cores.
    ///
    /// `intensity` (0…1) scales with board brightness so the glow tracks the
    /// physical board, while staying a slight luminous edge rather than a neon
    /// halo (§14.6).
    static func drawBloom(
        path: Path,
        in context: inout GraphicsContext,
        layout: LEDBoardLayout,
        color: Color,
        intensity: Double
    ) {
        guard !path.isEmpty, layout.cell > 0, intensity > 0 else { return }

        // Wide, faint halo just outside the perimeter.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: layout.cell * 0.85))
            layer.fill(path, with: .color(color.opacity(0.22 * intensity)))
        }
        // Tight, brighter rim hugging the contour itself.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: layout.cell * 0.30))
            layer.fill(path, with: .color(color.opacity(0.38 * intensity)))
            layer.stroke(path,
                         with: .color(color.opacity(0.50 * intensity)),
                         lineWidth: layout.cell * 0.34)
        }
    }
}
