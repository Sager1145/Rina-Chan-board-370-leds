import XCTest
@testable import RinaCore

/// PR-10: `ScrollRasterizer.frame(from:offset:geometry:)` stopped calling
/// `MatrixGeometry.ledIndex(x:y:)` per LED (hoisting the per-row cumulative
/// index instead), and `rotatedToFirstLitFrame`/`makeTimeline`'s rotation
/// switched from `litCount > 0` to `!isEmpty`. These tests hold private
/// reference implementations of the pre-PR-10 code and check bit-identical
/// output against the new implementation.
final class ScrollRasterizerPR10Tests: XCTestCase {
    private static let fontURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // ScrollRasterizerPR10Tests.swift -> RinaCoreTests
        for _ in 0..<4 { url.deleteLastPathComponent() } // -> Tests -> RinaCore -> Packages -> ios
        return url.appendingPathComponent("RinaBoard/Resources/ark12.json")
    }()

    private func loadFont() throws -> ArkPixelFont {
        try TestResources.requireFile(Self.fontURL)
        return try ArkPixelFont.loadBundled(url: Self.fontURL)
    }

    // MARK: - Pre-PR-10 reference implementations

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

    /// Old `rotateScrollTimelineToFirstLitFrame`: `litCount > 0` gate.
    private func referenceRotatedToFirstLitFrame(_ frames: [PackedFrame]) -> [PackedFrame] {
        guard let index = frames.firstIndex(where: { $0.litCount > 0 }), index > 0 else {
            return frames
        }
        return Array(frames[index...] + frames[..<index])
    }

    /// Old `prepareTextScrollTimeline` pipeline, reusing the (unchanged)
    /// validation/build/cap-check steps and only reimplementing the
    /// frame-extraction and rotation steps the old way.
    private func referenceMakeTimeline(
        text: String, font: ArkPixelFont, fps: Int,
        geometry: MatrixGeometry.Type = MatrixGeometry.self,
        maxFrames: Int = ScrollRasterizer.maxFrames
    ) throws -> (frames: [PackedFrame], rotation: Int) {
        let normalized = ScrollText.normalizeEmojiPresentation(text)
        let truncated = ScrollText.truncate(normalized, maxVisibleChars: ScrollRasterizer.maxTextChars)
        guard !truncated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScrollRasterizer.RasterizerError.emptyText
        }
        guard !ScrollText.exceedsByteLimit(truncated, limit: ScrollRasterizer.maxTextBytes) else {
            throw ScrollRasterizer.RasterizerError.textTooLong
        }
        let cheapEstimate = ScrollRasterizer.cheapFrameEstimate(text: truncated, geometry: geometry)
        guard cheapEstimate <= maxFrames else {
            throw ScrollRasterizer.RasterizerError.tooManyFrames(projected: cheapEstimate)
        }
        let bitmap = ScrollRasterizer.buildBitmap(text: truncated, font: font, geometry: geometry)
        let maxOffset = max(1, bitmap.width - geometry.cols)
        let projected = maxOffset + 1
        guard projected <= maxFrames else {
            throw ScrollRasterizer.RasterizerError.tooManyFrames(projected: projected)
        }
        var frames: [PackedFrame] = []
        frames.reserveCapacity(projected)
        for offset in 0...maxOffset {
            frames.append(referenceFrame(from: bitmap, offset: offset, geometry: geometry))
        }
        let rotation = frames.firstIndex(where: { $0.litCount > 0 }) ?? 0
        frames = referenceRotatedToFirstLitFrame(frames)
        return (frames, rotation)
    }

    // MARK: - frame(from:offset:geometry:) equivalence

    func testFrameExtractionMatchesPerLEDGeometryLookupAcrossOffsets() throws {
        let font = try loadFont()
        let bitmap = ScrollRasterizer.buildBitmap(text: "Hello, Rina! 璃奈ちゃん 123", font: font)
        let maxOffset = max(1, bitmap.width - MatrixGeometry.cols)
        for offset in stride(from: 0, through: maxOffset, by: max(1, maxOffset / 200)) {
            let fast = ScrollRasterizer.frame(from: bitmap, offset: offset)
            let reference = referenceFrame(from: bitmap, offset: offset)
            XCTAssertEqual(fast, reference, "offset \(offset)")
        }
        // Always check the exact boundary offsets too.
        for offset in [0, maxOffset] {
            XCTAssertEqual(ScrollRasterizer.frame(from: bitmap, offset: offset), referenceFrame(from: bitmap, offset: offset))
        }
    }

    func testFrameExtractionMatchesForBlankSpaceBitmap() {
        // buildBitmap(text: "") substitutes a single space glyph internally;
        // exercise the extraction directly on a hand-built all-blank bitmap.
        let width = 40
        let rows = [[Bool]](repeating: [Bool](repeating: false, count: width), count: MatrixGeometry.rows)
        let bitmap = ScrollBitmap(rows: rows, width: width)
        for offset in [0, 5, width - 1] {
            let fast = ScrollRasterizer.frame(from: bitmap, offset: offset)
            let reference = referenceFrame(from: bitmap, offset: offset)
            XCTAssertEqual(fast, reference)
            XCTAssertTrue(fast.isEmpty)
        }
    }

    // MARK: - makeTimeline equivalence

    private func assertTimelinesMatch(text: String, font: ArkPixelFont, fps: Int = 10, file: StaticString = #filePath, line: UInt = #line) throws {
        let fastResult = Result { try ScrollRasterizer.makeTimeline(text: text, font: font, fps: fps) }
        let referenceResult = Result { try referenceMakeTimeline(text: text, font: font, fps: fps) }

        switch (fastResult, referenceResult) {
        case let (.success(fast), .success(reference)):
            XCTAssertEqual(fast.rotation, reference.rotation, file: file, line: line)
            XCTAssertEqual(fast.frames.count, reference.frames.count, file: file, line: line)
            for (i, pair) in zip(fast.frames, reference.frames).enumerated() {
                XCTAssertEqual(pair.0, pair.1, "frame \(i) mismatch for text \(text.prefix(20))...", file: file, line: line)
            }
        case let (.failure(fastError), .failure(referenceError)):
            XCTAssertEqual(
                fastError as? ScrollRasterizer.RasterizerError,
                referenceError as? ScrollRasterizer.RasterizerError,
                file: file, line: line
            )
        default:
            XCTFail("fast/reference disagreed on throwing for text \(text.prefix(20))...: fast=\(fastResult), reference=\(referenceResult)", file: file, line: line)
        }
    }

    func testMakeTimelineMatchesReferenceForVariousTexts() throws {
        let font = try loadFont()
        let texts = [
            "A",
            "Hi",
            "RinaChanBoard 370 LED",
            "こんにちは 璃奈ちゃんボード",
            "!@#$%^&*()",
            "   leading and trailing spaces   ",
            String(repeating: "A", count: 5),
            String(repeating: "璃", count: 5),
        ]
        for text in texts {
            try assertTimelinesMatch(text: text, font: font)
        }
    }

    func testMakeTimelineMatchesReferenceForBlankAndEmptyText() throws {
        let font = try loadFont()
        // Both are expected to throw .emptyText identically old vs new.
        try assertTimelinesMatch(text: "", font: font)
        try assertTimelinesMatch(text: "   ", font: font)
        try assertTimelinesMatch(text: "\n\t  \n", font: font)
    }

    func testMakeTimelineMatchesReferenceForLongestTimeline() throws {
        let font = try loadFont()
        // Find the longest run of repeated "A" whose projected frame count is
        // still <= maxFrames (3072), to exercise the largest timeline this
        // rasterizer can produce without throwing .tooManyFrames.
        var longestText = "A"
        var count = 1
        while true {
            let candidate = String(repeating: "A", count: count)
            let bitmap = ScrollRasterizer.buildBitmap(text: candidate, font: font)
            let projected = ScrollRasterizer.projectedFrameCount(forBitmapWidth: bitmap.width)
            if projected > ScrollRasterizer.maxFrames { break }
            longestText = candidate
            count += 1
        }

        let timeline = try ScrollRasterizer.makeTimeline(text: longestText, font: font, fps: 10)
        XCTAssertGreaterThan(timeline.frameCount, ScrollRasterizer.maxFrames - 50, "expected to be near the 3072-frame cap")
        XCTAssertLessThanOrEqual(timeline.frameCount, ScrollRasterizer.maxFrames)

        try assertTimelinesMatch(text: longestText, font: font)
    }
}
