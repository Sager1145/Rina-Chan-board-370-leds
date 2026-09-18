import Foundation

/// Builds and samples the stitched "group" scroll bitmap
/// (BOARD_GROUP_SPEC.md §1.4/§2): `[V dark columns][text bitmap, no
/// single-board padding][V dark columns]`, windowed per board with the same
/// `f + X + x` rule the firmware uses for `scroll_bitmap` viewport frames.
public enum GroupScrollBitmap {
    /// `W` upper bound: `scroll_bitmap` BEGIN width bound (RINALINK_PROTOCOL_V1 §7.1).
    public static let maxWidth = 3093
    /// `frameCount` upper bound (RINALINK_PROTOCOL_V1 §7.1 / BOARD_GROUP_SPEC §1.4).
    public static let maxFrameCount = 3072

    public enum BuildError: Error, Equatable, Sendable {
        case emptyText
        case textTooLong
        /// The assembled `[V dark][text][V dark]` bitmap would be wider than `maxWidth`.
        case widthExceedsLimit(width: Int, limit: Int)
        /// `frameCount = max(1, W - V) + 1` would exceed `maxFrameCount`.
        case tooManyFrames(frameCount: Int, limit: Int)
    }

    /// `frameCount = max(1, W - V) + 1` (BOARD_GROUP_SPEC.md §1.4).
    public static func frameCount(bitmapWidth: Int, virtualWidth: Int) -> Int {
        max(1, bitmapWidth - virtualWidth) + 1
    }

    /// Builds the padded group bitmap for a stitched screen of width `virtualWidth`
    /// (V): normalises/truncates `text` the same way `ScrollRasterizer.makeTimeline`
    /// does, rasterises it with no single-board leading/trailing blank
    /// (`ScrollRasterizer.buildRawTextBitmap`), then pads `[V dark][text][V dark]`.
    /// Throws instead of silently truncating when the resulting width or frame
    /// count would exceed the wire limits.
    public static func build(
        text: String,
        font: ArkPixelFont,
        virtualWidth: Int,
        geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) throws -> ScrollBitmap {
        let normalized = ScrollText.normalizeEmojiPresentation(text)
        let truncated = ScrollText.truncate(normalized, maxVisibleChars: ScrollRasterizer.maxTextChars)
        guard !truncated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuildError.emptyText
        }
        guard !ScrollText.exceedsByteLimit(truncated, limit: ScrollRasterizer.maxTextBytes) else {
            throw BuildError.textTooLong
        }

        let textBitmap = ScrollRasterizer.buildRawTextBitmap(text: truncated, font: font, geometry: geometry)
        let width = virtualWidth + textBitmap.width + virtualWidth
        guard width <= maxWidth else {
            throw BuildError.widthExceedsLimit(width: width, limit: maxWidth)
        }
        let count = frameCount(bitmapWidth: width, virtualWidth: virtualWidth)
        guard count <= maxFrameCount else {
            throw BuildError.tooManyFrames(frameCount: count, limit: maxFrameCount)
        }

        var rows = [[Bool]](repeating: [Bool](repeating: false, count: width), count: geometry.rows)
        for y in 0..<geometry.rows {
            for x in 0..<textBitmap.width {
                rows[y][virtualWidth + x] = textBitmap.rows[y][x]
            }
        }
        return ScrollBitmap(rows: rows, width: width)
    }

    /// Pure window sampler (BOARD_GROUP_SPEC.md §1.4/§2): frame `frameIndex` at
    /// `viewportX` shows, at board cell `(x, y)`, bitmap pixel
    /// `(frameIndex + viewportX + x, y)`; columns `>= width` **or negative**
    /// are dark. Implemented with its own loop rather than delegating to
    /// `ScrollRasterizer.frame(from:offset:)`: that helper clamps its offset
    /// to `>= 0` (`start = max(0, offset)`), which is the wrong rule here —
    /// §1.4 says the *column* (`frameIndex + viewportX + x`), not the
    /// offset, must be checked against `0..<width`. Uses the same LED
    /// index/packing as the single-board path (`MatrixGeometry.validXRange` +
    /// row-length prefix sum, matching `ScrollRasterizer.frame`'s index math).
    public static func frame(
        bitmap: ScrollBitmap, viewportX: Int, frameIndex: Int,
        geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> PackedFrame {
        var result = PackedFrame()
        var rowBase = 0
        for y in 0..<geometry.rows {
            defer { rowBase += geometry.rowLengths[y] }
            guard let range = geometry.validXRange(row: y) else { continue }
            let srcRow = bitmap.rows[y]
            for x in range {
                let idx = rowBase + (x - range.lowerBound)
                let srcX = frameIndex + viewportX + x
                result[idx] = srcX >= 0 && srcX < bitmap.width && srcRow[srcX]
            }
        }
        return result
    }

    /// Reference `virtualWidth × 18` canvas at `frameIndex`: virtual column `c`
    /// shows bitmap pixel `(frameIndex + c, y)`; out-of-range columns are dark.
    /// Used by tests (each board's window frame must equal the crop of this
    /// canvas at its own `viewportX`, masked to the physical LED set) and by
    /// the app's group preview.
    public static func virtualCanvasFrame(
        bitmap: ScrollBitmap, layout: StitchedScreenLayout, frameIndex: Int,
        geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> ScrollBitmap {
        let width = layout.virtualWidth
        var rows = [[Bool]](repeating: [Bool](repeating: false, count: width), count: geometry.rows)
        for y in 0..<geometry.rows {
            for c in 0..<width {
                let srcX = frameIndex + c
                rows[y][c] = srcX >= 0 && srcX < bitmap.width && bitmap.rows[y][srcX]
            }
        }
        return ScrollBitmap(rows: rows, width: width)
    }
}
