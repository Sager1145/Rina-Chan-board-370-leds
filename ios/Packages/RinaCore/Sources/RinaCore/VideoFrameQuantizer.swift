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

    /// Mean luminance (0…1) of every grid cell, row-major over
    /// `MatrixGeometry.cols × rows`, or `nil` for cells the picture does not
    /// cover (only possible with `.fit`). Mirroring is applied here so every
    /// later step sees the final orientation.
    public static func cellLuminance(of image: LumaImage, fit: Fit, mirror: Bool) -> [Float?] {
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

        var result = [Float?](repeating: nil, count: cols * rows)
        let n = samplesPerAxis
        for gy in 0..<rows {
            for gx in 0..<cols {
                let sourceColumn = mirror ? cols - 1 - gx : gx
                var sum = 0
                var count = 0
                for sy in 0..<n {
                    let cellY = Double(gy) + (Double(sy) + 0.5) / Double(n)
                    let py = Int(((cellY - originY) * scaleY).rounded(.down))
                    guard py >= 0, py < image.height else { continue }
                    let rowStart = py * image.width
                    for sx in 0..<n {
                        let cellX = Double(sourceColumn) + (Double(sx) + 0.5) / Double(n)
                        let px = Int(((cellX - originX) * scaleX).rounded(.down))
                        guard px >= 0, px < image.width else { continue }
                        sum += Int(image.pixels[rowStart + px])
                        count += 1
                    }
                }
                if count > 0 {
                    result[gy * cols + gx] = Float(sum) / Float(count * 255)
                }
            }
        }
        return result
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
        frame(fromCells: cellLuminance(of: image, fit: settings.fit, mirror: settings.mirror),
              settings: settings)
    }

    /// Quantizes pre-sampled cells (see `cellLuminance`). Cells outside the
    /// picture stay off even when inverted, so letterbox bars never light up.
    public static func frame(fromCells cells: [Float?], settings: Settings) -> PackedFrame {
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
                guard let (x, y) = MatrixGeometry.xy(ofLed: led), let value = cells[y * cols + x] else { continue }
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
            guard let (x, y) = MatrixGeometry.xy(ofLed: led), let value = cells[y * cols + x] else { continue }
            var lit: Bool
            switch settings.mode {
            case .threshold:
                lit = value > threshold
            case .dither:
                // Shift the picture so the chosen threshold sits at the
                // dither pattern's midpoint, then compare against the pattern.
                lit = value + (0.5 - threshold) > bayer4[(y % 4) * 4 + x % 4]
            }
            if settings.invert { lit.toggle() }
            if lit { frame.set(led) }
        }
        return frame
    }
}
