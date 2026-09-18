import Foundation

/// The 18-row scroll-text bitmap before it is windowed into per-offset
/// `PackedFrame`s. `rows[y][x]` is `true` when the pixel is lit.
public struct ScrollBitmap: Sendable {
    public let rows: [[Bool]]
    public let width: Int

    public init(rows: [[Bool]], width: Int) {
        self.rows = rows
        self.width = width
    }

    /// `ceil(width/8)` — the number of bytes per packed row (RINALINK_PROTOCOL_V1 §7.1).
    public var stride: Int { (width + 7) / 8 }

    /// Row-major packed bytes: row `y` occupies `[y*stride, (y+1)*stride)`;
    /// pixel `x` of row `y` is bit `(x & 7)` (LSB-first) of byte `y*stride + (x >> 3)`.
    public func packedBytes() -> Data {
        let s = stride
        var bytes = [UInt8](repeating: 0, count: s * rows.count)
        for y in 0..<rows.count {
            let row = rows[y]
            for x in 0..<min(width, row.count) where row[x] {
                bytes[y * s + (x >> 3)] |= UInt8(1 << (x & 7))
            }
        }
        return Data(bytes)
    }
}

/// A fully rasterised, ready-to-upload scroll timeline.
public struct ScrollTimeline: Sendable {
    public let frames: [PackedFrame]
    public let bitmap: ScrollBitmap
    public let bitmapWidth: Int
    public let frameCount: Int
    public let text: String
    public let timelineId: String
    public let fps: Int
    public let intervalMs: Int
    /// Number of leading dark frames the rasterizer moved to the end of the
    /// sequence to make index 0 the first lit frame (0 if nothing lit). Must
    /// match the firmware's `BLOB_END` reply `rotation` for `kind:"scroll_bitmap"`.
    public let rotation: Int
}

/// Ports the WebUI scroll-text rasterizer (app.js `buildTextScrollBitmap`,
/// `blitGlyphBitmap`, `extractFrameFromTextImage`, `prepareTextScrollTimeline`,
/// `rotateScrollTimelineToFirstLitFrame`) to produce bit-identical output.
public enum ScrollRasterizer {
    public static let fontId = "ark_pixel_12px_fusion_bitmap_v4"
    public static let generatorVersion = "webui-scrollgen-6.4.2"
    public static let charSpacing = 0
    public static let spaceColumns = 6
    public static let maxTextChars = ScrollText.maxVisibleChars
    public static let maxTextBytes = ScrollText.maxTextBytes
    public static let maxFrames = 3072

    public enum RasterizerError: Error, Equatable {
        case emptyText
        case tooManyFrames(projected: Int)
        case textTooLong
    }

    /// `leading = trailing = COLS + 4` (app.js ~12118).
    public static func leadingBlank(geometry: MatrixGeometry.Type = MatrixGeometry.self) -> Int {
        geometry.cols + 4
    }

    public static func trailingBlank(geometry: MatrixGeometry.Type = MatrixGeometry.self) -> Int {
        geometry.cols + 4
    }

    /// `textScrollVerticalOffset()` (app.js ~4095).
    public static func verticalOffset(
        font: ArkPixelFont, geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> Int {
        let rows = geometry.rows
        let lineHeight = max(1, font.lineHeight)
        return min(max(0, rows - 1), max(0, (rows - lineHeight) / 2) + 2)
    }

    /// `buildTextScrollBitmap(text)` (app.js ~12110).
    public static func buildBitmap(
        text: String, font: ArkPixelFont, geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> ScrollBitmap {
        buildBitmapCore(
            text: text, font: font, geometry: geometry,
            leading: leadingBlank(geometry: geometry), trailing: trailingBlank(geometry: geometry),
            minWidth: geometry.cols * 2 + 8
        )
    }

    /// Same glyph rasterization as `buildBitmap`, but without the single-board
    /// leading/trailing blank padding — used by the group bitmap builder
    /// (`GroupScrollBitmap`), which applies its own `[V dark][text][V dark]`
    /// padding (BOARD_GROUP_SPEC.md §1.4/§2).
    public static func buildRawTextBitmap(
        text: String, font: ArkPixelFont, geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> ScrollBitmap {
        buildBitmapCore(text: text, font: font, geometry: geometry, leading: 0, trailing: 0, minWidth: 0)
    }

    private static func buildBitmapCore(
        text: String, font: ArkPixelFont, geometry: MatrixGeometry.Type,
        leading: Int, trailing: Int, minWidth: Int
    ) -> ScrollBitmap {
        let raw = text.isEmpty ? " " : text
        let chars = raw.unicodeScalars.filter { !ScrollText.isEmojiFormatControl($0) }
        let glyphs = chars.map { font.glyph(for: $0) }

        var contentWidth = 0
        for i in 0..<glyphs.count {
            contentWidth += glyphs[i].advance
            if i + 1 < glyphs.count, !glyphs[i].isSpace, !glyphs[i + 1].isSpace {
                contentWidth += charSpacing
            }
        }

        let width = max(minWidth, leading + contentWidth + trailing)
        var rows = [[Bool]](repeating: [Bool](repeating: false, count: width), count: geometry.rows)

        let vOffset = verticalOffset(font: font, geometry: geometry)
        var x = leading
        for i in 0..<glyphs.count {
            let g = glyphs[i]
            if !g.isSpace {
                blit(glyph: g, x0: x, verticalOffset: vOffset, geometry: geometry, into: &rows, width: width)
            }
            x += g.advance
            if i + 1 < glyphs.count, !g.isSpace, !glyphs[i + 1].isSpace {
                x += charSpacing
            }
        }

        return ScrollBitmap(rows: rows, width: width)
    }

    /// `blitGlyphBitmap(bitmap, x0, glyph)` (app.js ~12238). JS `Math.round`
    /// rounds half toward +Infinity, hence `(x + 0.5).rounded(.down)`.
    private static func blit(
        glyph g: ArkGlyph, x0: Int, verticalOffset: Int, geometry: MatrixGeometry.Type,
        into rows: inout [[Bool]], width: Int
    ) {
        let baseY = verticalOffset + g.dstY + g.yOffset
        let baseX = Int((Double(x0) + Double(g.xOffset) + 0.5).rounded(.down))
        for gy in 0..<g.height {
            let y = baseY + gy
            guard y >= 0 && y < geometry.rows else { continue }
            guard gy < g.rows.count else { continue }
            let glyphRow = g.rows[gy]
            for gx in 0..<g.width {
                guard gx < glyphRow.count, glyphRow[gx] else { continue }
                let x = baseX + gx
                if x >= 0 && x < width {
                    rows[y][x] = true
                }
            }
        }
    }

    /// `extractFrameFromTextImage(source, offset)` (app.js ~12255).
    ///
    /// Per-LED, this used to call `geometry.ledIndex(x:y:)`, which internally
    /// re-derives `validXRange(row:)` and re-sums `rowLengths[0..<y]` on every
    /// call (O(rows) work per LED, O(rows^2) per frame). `MatrixGeometry` itself
    /// is out of scope for this change, so instead we hoist the row's valid
    /// range (already done) and the row's cumulative LED-index base out of the
    /// per-column loop, computing the same index MatrixGeometry.ledIndex would
    /// return without calling it. See `ScrollRasterizerPR10Tests`
    /// for the equality check against the original per-LED lookup.
    public static func frame(
        from bitmap: ScrollBitmap, offset: Int, geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> PackedFrame {
        var frame = PackedFrame()
        let start = max(0, offset)
        var rowBase = 0
        for y in 0..<geometry.rows {
            defer { rowBase += geometry.rowLengths[y] }
            guard let range = geometry.validXRange(row: y) else { continue }
            let srcRow = bitmap.rows[y]
            for x in range {
                let idx = rowBase + (x - range.lowerBound)
                let srcX = start + x
                frame[idx] = srcX < bitmap.width && srcRow[srcX]
            }
        }
        return frame
    }

    /// `maxOffset = max(1, width - COLS); frameCount = maxOffset + 1` (app.js ~11538).
    public static func projectedFrameCount(
        forBitmapWidth width: Int, geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> Int {
        max(1, width - geometry.cols) + 1
    }

    /// Cheap pre-rasterisation guard (app.js ~11527): `scalarCount - COLS + 1`.
    public static func cheapFrameEstimate(
        text: String, geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> Int {
        text.unicodeScalars.count - geometry.cols + 1
    }

    /// `rotateScrollTimelineToFirstLitFrame(frames)` (app.js ~4319).
    static func rotatedToFirstLitFrame(_ frames: [PackedFrame]) -> [PackedFrame] {
        guard let index = frames.firstIndex(where: { !$0.isEmpty }), index > 0 else {
            return frames
        }
        return Array(frames[index...] + frames[..<index])
    }

    /// `fps -> intervalMs`: `max(1, round(1000/fps))` (app.js ~10908).
    public static func intervalMs(forFps fps: Int) -> Int {
        guard fps > 0 else { return 1000 }
        return max(1, Int((1000.0 / Double(fps) + 0.5).rounded(.down)))
    }

    /// `makeScrollTimelineId()` (app.js ~10884): `"scroll-" + base36(now) + "-" + 4 random base36 chars`.
    public static func makeTimelineId() -> String {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let timePart = String(millis, radix: 36)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let randPart = String((0..<4).map { _ in alphabet.randomElement()! })
        return "scroll-\(timePart)-\(randPart)"
    }

    /// Full pipeline: normalise -> truncate -> byte check -> build -> cap
    /// check -> extract -> rotate to first lit frame (app.js
    /// `prepareTextScrollTimeline`, ~11494-11556).
    public static func makeTimeline(
        text: String,
        font: ArkPixelFont,
        fps: Int,
        geometry: MatrixGeometry.Type = MatrixGeometry.self,
        maxFrames: Int = ScrollRasterizer.maxFrames
    ) throws -> ScrollTimeline {
        let normalized = ScrollText.normalizeEmojiPresentation(text)
        let truncated = ScrollText.truncate(normalized, maxVisibleChars: maxTextChars)

        guard !truncated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RasterizerError.emptyText
        }
        guard !ScrollText.exceedsByteLimit(truncated, limit: maxTextBytes) else {
            throw RasterizerError.textTooLong
        }

        let cheapEstimate = cheapFrameEstimate(text: truncated, geometry: geometry)
        guard cheapEstimate <= maxFrames else {
            throw RasterizerError.tooManyFrames(projected: cheapEstimate)
        }

        let bitmap = buildBitmap(text: truncated, font: font, geometry: geometry)
        let maxOffset = max(1, bitmap.width - geometry.cols)
        let projected = maxOffset + 1
        guard projected <= maxFrames else {
            throw RasterizerError.tooManyFrames(projected: projected)
        }

        var frames: [PackedFrame] = []
        frames.reserveCapacity(projected)
        for offset in 0...maxOffset {
            frames.append(frame(from: bitmap, offset: offset, geometry: geometry))
        }
        let rotation = frames.firstIndex(where: { !$0.isEmpty }) ?? 0
        frames = rotatedToFirstLitFrame(frames)

        return ScrollTimeline(
            frames: frames,
            bitmap: bitmap,
            bitmapWidth: bitmap.width,
            frameCount: frames.count,
            text: truncated,
            timelineId: makeTimelineId(),
            fps: fps,
            intervalMs: intervalMs(forFps: fps),
            rotation: rotation
        )
    }
}
