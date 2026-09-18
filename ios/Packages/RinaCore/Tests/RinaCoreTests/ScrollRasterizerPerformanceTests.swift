import XCTest
@testable import RinaCore

/// PR-10 performance gate: pre-PR-10 (per-LED `MatrixGeometry.ledIndex(x:y:)`
/// lookup, `litCount`-based rotation) vs the PR-10 implementation (hoisted
/// row-base index, `isEmpty`-based rotation) for the longest producible
/// timeline (3072 frames). Skipped unless `RINA_PERF_GATE=1`; ratio is only
/// asserted in release builds, following `LipSyncDSPEnginePerformanceTests`.
final class ScrollRasterizerPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["RINA_PERF_GATE"] == "1" else {
            throw XCTSkip("set RINA_PERF_GATE=1 to run")
        }
    }

    private static let fontURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("RinaBoard/Resources/ark12.json")
    }()

    private func loadFont() throws -> ArkPixelFont {
        try TestResources.requireFile(Self.fontURL)
        return try ArkPixelFont.loadBundled(url: Self.fontURL)
    }

    /// Old `extractFrameFromTextImage`: per-LED `geometry.ledIndex(x:y:)` call.
    private func referenceFrame(
        from bitmap: ScrollBitmap, offset: Int, geometry: MatrixGeometry.Type = MatrixGeometry.self
    ) -> PackedFrame {
        var frame = PackedFrame()
        let start = max(0, offset)
        for y in 0..<geometry.rows {
            guard let range = geometry.validXRange(row: y) else { continue }
            let srcRow = bitmap.rows[y]
            for x in range {
                guard let idx = geometry.ledIndex(x: x, y: y) else { continue }
                let srcX = start + x
                frame[idx] = srcX < bitmap.width && srcRow[srcX]
            }
        }
        return frame
    }

    private func referenceRotatedToFirstLitFrame(_ frames: [PackedFrame]) -> [PackedFrame] {
        guard let index = frames.firstIndex(where: { $0.litCount > 0 }), index > 0 else {
            return frames
        }
        return Array(frames[index...] + frames[..<index])
    }

    private func referenceMakeTimeline(bitmap: ScrollBitmap, geometry: MatrixGeometry.Type = MatrixGeometry.self) -> [PackedFrame] {
        let maxOffset = max(1, bitmap.width - geometry.cols)
        var frames: [PackedFrame] = []
        frames.reserveCapacity(maxOffset + 1)
        for offset in 0...maxOffset {
            frames.append(referenceFrame(from: bitmap, offset: offset, geometry: geometry))
        }
        return referenceRotatedToFirstLitFrame(frames)
    }

    private func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double) {
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }

    private func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    /// Finds the longest run of "A" whose projected frame count stays <=
    /// `ScrollRasterizer.maxFrames` (3072).
    private func longestBitmap(font: ArkPixelFont) -> ScrollBitmap {
        var longest = ScrollRasterizer.buildBitmap(text: "A", font: font)
        var count = 1
        while true {
            let candidate = String(repeating: "A", count: count)
            let bitmap = ScrollRasterizer.buildBitmap(text: candidate, font: font)
            let projected = ScrollRasterizer.projectedFrameCount(forBitmapWidth: bitmap.width)
            if projected > ScrollRasterizer.maxFrames { break }
            longest = bitmap
            count += 1
        }
        return longest
    }

    func testLongestTimelineExtractionRatio() throws {
        let font = try loadFont()
        let bitmap = longestBitmap(font: font)
        let clock = ContinuousClock()

        var referenceSamples: [Double] = []
        var fastSamples: [Double] = []
        let iterations = 5
        let maxOffsetWarmup = max(1, bitmap.width - MatrixGeometry.cols)
        for _ in 0..<2 {
            _ = referenceMakeTimeline(bitmap: bitmap)
            var warmupFrames: [PackedFrame] = []
            for offset in 0...maxOffsetWarmup {
                warmupFrames.append(ScrollRasterizer.frame(from: bitmap, offset: offset))
            }
            _ = ScrollRasterizer.rotatedToFirstLitFrame(warmupFrames)
        }
        for _ in 0..<iterations {
            referenceSamples.append(millis(clock.measure { _ = referenceMakeTimeline(bitmap: bitmap) }))
            let maxOffset = max(1, bitmap.width - MatrixGeometry.cols)
            fastSamples.append(millis(clock.measure {
                var frames: [PackedFrame] = []
                frames.reserveCapacity(maxOffset + 1)
                for offset in 0...maxOffset {
                    frames.append(ScrollRasterizer.frame(from: bitmap, offset: offset))
                }
                _ = ScrollRasterizer.rotatedToFirstLitFrame(frames)
            }))
        }

        let reference = percentiles(referenceSamples)
        let fast = percentiles(fastSamples)
        let ratioP50 = fast.p50 / reference.p50
        print("[ScrollRasterizerBench] frameCount=\(max(1, bitmap.width - MatrixGeometry.cols) + 1) reference p50=\(String(format: "%.4f", reference.p50))ms fast p50=\(String(format: "%.4f", fast.p50))ms ratioP50=\(String(format: "%.4f", ratioP50))")

        #if !DEBUG
        XCTAssertLessThanOrEqual(fast.p50, reference.p50)
        #endif
    }
}
