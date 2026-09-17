import Foundation

/// Turns one decoded video frame into a 370-LED on/off face.
///
/// The pipeline follows n2048-creative-technology/video-to-LED-matrix
/// (`ofApp.cpp` `update` → `buildPayload`): downsample the whole picture to
/// the matrix grid, then apply per-frame corrections, then map grid cells to
/// LED indices. That project drives full-RGB LEDs and simply stretches the
/// video onto the grid; this board is monochrome on/off, so two things are
/// added on top — an aspect-correct fit/fill option, and a threshold or
/// ordered-dither step in place of its brightness multiply.
///
/// Ordered (Bayer) dithering is used rather than error diffusion on purpose:
/// its pattern depends only on the cell position, so a static region of the
/// video stays static on the board instead of shimmering frame to frame.
public enum VideoFrameQuantizer {
    /// How the video's aspect ratio is reconciled with the 22×18 grid.
    public enum Fit: String, CaseIterable, Sendable {
        /// Scale to cover the whole grid, cropping the overflow.
        case fill
        /// Scale to fit inside the grid; uncovered cells stay off.
        case fit
        /// Stretch both axes independently (the reference project's behaviour).
        case stretch
    }

    public enum Mode: String, CaseIterable, Sendable {
        /// Each cell is lit when its luminance is above the threshold.
        case threshold
        /// 4×4 ordered dithering, biased by the threshold.
        case dither
    }

    public struct Settings: Equatable, Sendable {
        public var fit: Fit
        public var mode: Mode
        /// 0…1. Ignored while `autoThreshold` is on.
        public var threshold: Double
        /// Use the frame's own mean luminance as the threshold, so dark and
        /// bright videos both produce a readable face without tuning.
        public var autoThreshold: Bool
        public var invert: Bool
        public var mirror: Bool

        public init(fit: Fit = .fill, mode: Mode = .threshold, threshold: Double = 0.5,
                    autoThreshold: Bool = true, invert: Bool = false, mirror: Bool = false) {
            self.fit = fit
            self.mode = mode
            self.threshold = threshold
            self.autoThreshold = autoThreshold
            self.invert = invert
            self.mirror = mirror
        }
    }

    /// An 8-bit single-channel luminance image, row-major, top row first.
    public struct LumaImage: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]

        public init?(width: Int, height: Int, pixels: [UInt8]) {
            guard width > 0, height > 0, pixels.count == width * height else { return nil }
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    /// Samples per cell axis. A cell is the average of up to 5×5 evenly spaced
    /// source pixels, which is enough to stop thin details from aliasing in
    /// and out while staying cheap at any source resolution.
    static let samplesPerAxis = 5

    /// Sentinel stored in place of `nil` in the internal `[Float]` cell table
    /// (valid means are 0...1, so -1 is unambiguous).
    private static let uncoveredCell: Float = -1

    /// Source-pixel lookup table for one grid axis: `table[g * n + s]` is the
    /// source pixel index for grid cell `g`, sub-sample `s`, or -1 when that
    /// sample falls outside the source image.
    private static func sampleTable(gridCount: Int, sourceExtent: Int, origin: Double, scale: Double) -> [Int] {
        let n = samplesPerAxis
        var table = [Int](repeating: -1, count: gridCount * n)
        for g in 0..<gridCount {
            for s in 0..<n {
                let cellCoordinate = Double(g) + (Double(s) + 0.5) / Double(n)
                let sample = Int(((cellCoordinate - origin) * scale).rounded(.down))
                guard sample >= 0, sample < sourceExtent else { continue }
                table[g * n + s] = sample
            }
        }
        return table
    }

    /// Mean luminance (0...1, `uncoveredCell` where the picture does not
    /// cover the cell) of every grid cell, row-major over
    /// `MatrixGeometry.cols × rows`. Mirroring is applied by choosing which
    /// column of the x sample table to read, so every later step sees the
    /// final orientation.
    private static func cellMeans(of image: LumaImage, fit: Fit, mirror: Bool) -> [Float] {
        let cols = MatrixGeometry.cols
        let rows = MatrixGeometry.rows
        let width = Double(image.width)
        let height = Double(image.height)

        // Source pixels per grid cell on each axis, and where the picture's
        // top-left lands in grid coordinates.
        let scaleX: Double
        let scaleY: Double
        switch fit {
        case .stretch:
            scaleX = width / Double(cols)
            scaleY = height / Double(rows)
        case .fill:
            let s = min(width / Double(cols), height / Double(rows))
            scaleX = s
            scaleY = s
        case .fit:
            let s = max(width / Double(cols), height / Double(rows))
            scaleX = s
            scaleY = s
        }
        let originX = (Double(cols) - width / scaleX) / 2
        let originY = (Double(rows) - height / scaleY) / 2

        let n = samplesPerAxis
        let pxTable = sampleTable(gridCount: cols, sourceExtent: image.width, origin: originX, scale: scaleX)
        let pyTable = sampleTable(gridCount: rows, sourceExtent: image.height, origin: originY, scale: scaleY)

        var result = [Float](repeating: uncoveredCell, count: cols * rows)
        image.pixels.withUnsafeBufferPointer { pixels in
            for gy in 0..<rows {
                let yBase = gy * n
                for gx in 0..<cols {
                    let sourceColumn = mirror ? cols - 1 - gx : gx
                    let xBase = sourceColumn * n
                    var sum = 0
                    var count = 0
                    for sy in 0..<n {
                        let py = pyTable[yBase + sy]
                        guard py >= 0 else { continue }
                        let rowStart = py * image.width
                        for sx in 0..<n {
                            let px = pxTable[xBase + sx]
                            guard px >= 0 else { continue }
                            sum += Int(pixels[rowStart + px])
                            count += 1
                        }
                    }
                    if count > 0 {
                        result[gy * cols + gx] = Float(sum) / Float(count * 255)
                    }
                }
            }
        }
        return result
    }

    /// Mean luminance (0…1) of every grid cell, row-major over
    /// `MatrixGeometry.cols × rows`, or `nil` for cells the picture does not
    /// cover (only possible with `.fit`). Mirroring is applied here so every
    /// later step sees the final orientation.
    ///
    /// Every non-`nil` element is expected to be in 0…1; `nil` marks an
    /// uncovered cell. Values outside that range are unspecified (internally,
    /// -1 is reserved as the uncovered-cell sentinel — see `frame(fromCells:settings:)`).
    public static func cellLuminance(of image: LumaImage, fit: Fit, mirror: Bool) -> [Float?] {
        cellMeans(of: image, fit: fit, mirror: mirror).map { $0 == uncoveredCell ? nil : $0 }
    }

    /// Below this luminance range across the board, auto threshold falls back
    /// to 0.5.
    static let minimumAutoSpread: Float = 0.08

    static let bayer4: [Float] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ].map { (Float($0) + 0.5) / 16 }

    public static func frame(from image: LumaImage, settings: Settings) -> PackedFrame {
        quantize(cells: cellMeans(of: image, fit: settings.fit, mirror: settings.mirror), settings: settings)
    }

    /// Quantizes pre-sampled cells (see `cellLuminance`). Cells outside the
    /// picture stay off even when inverted, so letterbox bars never light up.
    ///
    /// Every non-`nil` element of `cells` is expected to be in 0…1; `nil`
    /// marks an uncovered cell. Values outside that range are unspecified
    /// (internally, -1 is reserved as the uncovered-cell sentinel).
    public static func frame(fromCells cells: [Float?], settings: Settings) -> PackedFrame {
        let cols = MatrixGeometry.cols
        guard cells.count == cols * MatrixGeometry.rows else { return PackedFrame() }
        let means = cells.map { $0 ?? uncoveredCell }
        return quantize(cells: means, settings: settings)
    }

    /// Quantizes the internal `[Float]` cell table (see `cellMeans`) into a
    /// `PackedFrame`, iterating LEDs in logical order so Float accumulation
    /// order (for the auto threshold) matches the original implementation.
    private static func quantize(cells: [Float], settings: Settings) -> PackedFrame {
        let cols = MatrixGeometry.cols
        var frame = PackedFrame()
        guard cells.count == cols * MatrixGeometry.rows else { return frame }

        let threshold: Float
        if settings.autoThreshold {
            var sum: Float = 0
            var count = 0
            var low: Float = 1
            var high: Float = 0
            for led in 0..<MatrixGeometry.ledCount {
                let value = cells[MatrixGeometry.ledCellIndex[led]]
                guard value != uncoveredCell else { continue }
                sum += value
                count += 1
                low = min(low, value)
                high = max(high, value)
            }
            // A near-uniform frame (a fade, a title card, a blank shot) has
            // nothing to split: its own mean would blank a white frame and
            // turn compression noise into speckle. Use the midpoint instead.
            threshold = count > 0 && high - low >= minimumAutoSpread ? sum / Float(count) : 0.5
        } else {
            threshold = Float(min(1, max(0, settings.threshold)))
        }

        for led in 0..<MatrixGeometry.ledCount {
            let cell = MatrixGeometry.ledCellIndex[led]
            let value = cells[cell]
            guard value != uncoveredCell else { continue }
            var lit: Bool
            switch settings.mode {
            case .threshold:
                lit = value > threshold
            case .dither:
                // Shift the picture so the chosen threshold sits at the
                // dither pattern's midpoint, then compare against the pattern.
                let x = cell % cols
                let y = cell / cols
                lit = value + (0.5 - threshold) > bayer4[(y % 4) * 4 + x % 4]
            }
            if settings.invert { lit.toggle() }
            if lit { frame.set(led) }
        }
        return frame
    }
}
