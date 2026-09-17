import XCTest
@testable import RinaCore

/// PR-6: differential test that the O(1)-table rewrite of
/// `VideoFrameQuantizer` (integer sample lookup tables instead of per-sample
/// `Double` math) is bit-identical to the original per-sample implementation,
/// across a range of image sizes, random/constant content, and every
/// settings combination.
final class VideoFrameQuantizerDifferentialTests: XCTestCase {
    private struct Size {
        let width: Int
        let height: Int
    }

    private static let sizes: [Size] = [
        Size(width: 1, height: 1),
        Size(width: 2, height: 2),
        Size(width: 3, height: 7),
        Size(width: 22, height: 18),
        Size(width: 160, height: 90),
        Size(width: 90, height: 160),
        Size(width: 161, height: 97),
        Size(width: 7, height: 300),
    ]

    private static let thresholds: [Double] = [0, 0.3, 0.5, 1]

    private func randomImage(width: Int, height: Int, rng: inout PR6SplitMix64) -> VideoFrameQuantizer.LumaImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in 0..<pixels.count {
            pixels[index] = UInt8(rng.next() & 0xFF)
        }
        return VideoFrameQuantizer.LumaImage(width: width, height: height, pixels: pixels)!
    }

    private func constantImage(width: Int, height: Int, value: UInt8) -> VideoFrameQuantizer.LumaImage {
        VideoFrameQuantizer.LumaImage(width: width, height: height,
                                      pixels: [UInt8](repeating: value, count: width * height))!
    }

    func testMatchesReferenceAcrossAllSettingsAndImages() {
        var rng = PR6SplitMix64(seed: 0xC0FFEE)
        for size in Self.sizes {
            let images = [
                randomImage(width: size.width, height: size.height, rng: &rng),
                constantImage(width: size.width, height: size.height, value: UInt8(rng.next() & 0xFF)),
            ]
            for image in images {
                for fit in VideoFrameQuantizer.Fit.allCases {
                    for mode in VideoFrameQuantizer.Mode.allCases {
                        for invert in [false, true] {
                            for mirror in [false, true] {
                                for autoThreshold in [false, true] {
                                    let thresholds = autoThreshold ? [0.5] : Self.thresholds
                                    for threshold in thresholds {
                                        let settings = VideoFrameQuantizer.Settings(
                                            fit: fit, mode: mode, threshold: threshold,
                                            autoThreshold: autoThreshold, invert: invert, mirror: mirror
                                        )
                                        let description = "size=\(size.width)x\(size.height) fit=\(fit) mode=\(mode) " +
                                            "invert=\(invert) mirror=\(mirror) auto=\(autoThreshold) threshold=\(threshold)"

                                        let expectedCells = VideoQuantizerReferencePR6.cellLuminance(
                                            of: image, fit: settings.fit, mirror: settings.mirror)
                                        let actualCells = VideoFrameQuantizer.cellLuminance(
                                            of: image, fit: settings.fit, mirror: settings.mirror)
                                        XCTAssertEqual(actualCells.count, expectedCells.count, description)
                                        for index in 0..<expectedCells.count {
                                            XCTAssertEqual(actualCells[index], expectedCells[index], description)
                                        }

                                        let expectedFrame = VideoQuantizerReferencePR6.frame(fromCells: expectedCells, settings: settings)
                                        let actualFrame = VideoFrameQuantizer.frame(from: image, settings: settings)
                                        XCTAssertEqual(actualFrame, expectedFrame, description)

                                        let actualFrameFromCells = VideoFrameQuantizer.frame(fromCells: actualCells, settings: settings)
                                        XCTAssertEqual(actualFrameFromCells, expectedFrame, description)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testWrongCellCountProducesEmptyFrame() {
        let settings = VideoFrameQuantizer.Settings()
        let wrongCountCells: [Float?] = [0.5, 0.5, 0.5]

        let expectedFrame = VideoQuantizerReferencePR6.frame(fromCells: wrongCountCells, settings: settings)
        let actualFrame = VideoFrameQuantizer.frame(fromCells: wrongCountCells, settings: settings)

        XCTAssertEqual(expectedFrame, PackedFrame())
        XCTAssertEqual(actualFrame, PackedFrame())
    }
}

/// Deterministic, dependency-free PRNG (SplitMix64) used only to generate
/// reproducible pseudo-random pixel data for this stage's differential test.
private struct PR6SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Verbatim copy of the pre-PR-6 `VideoFrameQuantizer.cellLuminance` and
/// `frame(fromCells:)` (per-sample `Double` math, no lookup tables), kept
/// only as a differential-testing reference for the O(1) rewrite.
private enum VideoQuantizerReferencePR6 {
    static func cellLuminance(of image: VideoFrameQuantizer.LumaImage, fit: VideoFrameQuantizer.Fit, mirror: Bool) -> [Float?] {
        let cols = MatrixGeometry.cols
        let rows = MatrixGeometry.rows
        let width = Double(image.width)
        let height = Double(image.height)

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
        let n = VideoFrameQuantizer.samplesPerAxis
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

    static func frame(fromCells cells: [Float?], settings: VideoFrameQuantizer.Settings) -> PackedFrame {
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
            threshold = count > 0 && high - low >= VideoFrameQuantizer.minimumAutoSpread ? sum / Float(count) : 0.5
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
                lit = value + (0.5 - threshold) > VideoFrameQuantizer.bayer4[(y % 4) * 4 + x % 4]
            }
            if settings.invert { lit.toggle() }
            if lit { frame.set(led) }
        }
        return frame
    }
}
