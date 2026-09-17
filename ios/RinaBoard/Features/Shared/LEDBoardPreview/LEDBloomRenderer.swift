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
///
/// The contour geometry itself (occupancy → directed boundary edges → closed
/// chains) lives in `RinaCore.LEDContourBuilder`, which uses fixed-size
/// arrays instead of per-frame dictionaries. This renderer turns that into a
/// unit-space `Path` (§14.4), caches it per frame (`BloomContourCache`, since
/// a redraw at up to 120 Hz would otherwise rebuild an identical contour
/// every time), and only then applies the view's layout transform.
enum LEDBloomRenderer {

    /// Builds the unit-space (grid-corner coordinates) path for `frame`'s
    /// contours, straight from `LEDContourBuilder`. One `moveTo` + `addLine`
    /// chain per contour, closed — clockwise outer contours and
    /// counter-clockwise hole contours so a single non-zero fill leaves holes
    /// empty (§14.2).
    static func unitPath(for frame: PackedFrame) -> Path {
        let contours = LEDContourBuilder.contours(for: frame)
        guard !contours.isEmpty else { return Path() }

        let cornerColumns = LEDContours.cornerColumns
        func point(_ corner: UInt16) -> CGPoint {
            let key = Int(corner)
            return CGPoint(x: key % cornerColumns, y: key / cornerColumns)
        }

        var path = Path()
        let starts = contours.contourStarts
        for i in 0..<starts.count {
            let start = starts[i]
            let end = (i + 1 < starts.count) ? starts[i + 1] : contours.corners.count
            guard end > start else { continue }
            path.move(to: point(contours.corners[start]))
            for j in (start + 1)..<end {
                path.addLine(to: point(contours.corners[j]))
            }
            path.closeSubpath()
        }
        return path
    }

    /// Shared unit-space contour cache. Several previews (Control, Text,
    /// Video, PresetLive, LipSync, Debug) can be on screen at once, so this
    /// is keyed process-wide rather than per view.
    private static let contourCache = BloomContourCache()

    /// Builds the closed perimeter contours of every connected lit region, in
    /// `layout`'s view coordinates, via the shared unit-space cache.
    static func contourPath(frame: PackedFrame, layout: LEDBoardLayout) -> Path {
        let unit = contourCache.path(for: frame, build: { unitPath(for: frame) })
        guard !unit.isEmpty else { return Path() }
        return unit.applying(CGAffineTransform(a: layout.cell, b: 0, c: 0, d: layout.cell,
                                               tx: layout.origin.x, ty: layout.origin.y))
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

/// A small LRU cache of unit-space bloom contour paths, keyed by
/// `PackedFrame`. Several previews (Control, Text at up to 120 Hz, Video,
/// PresetLive, LipSync, Debug) can be on screen at once and frequently redraw
/// the same frame, so a capacity of 1 would thrash; 8 comfortably covers
/// every preview that could be visible together.
///
/// `@unchecked Sendable`: all mutable state is protected by `lock`, and
/// `Path`/`PackedFrame` values are copied in and out under the lock.
final class BloomContourCache: @unchecked Sendable {
    private let capacity = 8
    private let lock = NSLock()
    private var paths: [PackedFrame: Path] = [:]
    /// Most-recently-used last; used to pick an eviction victim.
    private var order: [PackedFrame] = []

    /// Returns the cached path for `frame`, computing and storing it via
    /// `build()` on a miss.
    func path(for frame: PackedFrame, build: () -> Path) -> Path {
        lock.lock()
        if let cached = paths[frame] {
            touch(frame)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = build()

        lock.lock()
        defer { lock.unlock() }
        // Another caller may have raced us to the same frame; last write wins,
        // which is fine since both computed the same path.
        paths[frame] = built
        touch(frame)
        if order.count > capacity {
            let victim = order.removeFirst()
            if victim != frame {
                paths.removeValue(forKey: victim)
            }
        }
        return built
    }

    /// Moves `frame` to the most-recently-used end of `order`, adding it if
    /// new. Must be called with `lock` held.
    private func touch(_ frame: PackedFrame) {
        if let index = order.firstIndex(of: frame) {
            order.remove(at: index)
        }
        order.append(frame)
    }
}
