import XCTest
@testable import RinaCore

final class ScrollRasterizerTests: XCTestCase {
    /// `../../../../RinaBoard/Resources/ark12.json` relative to this test file
    /// (Tests/RinaCoreTests -> Tests -> RinaCore -> Packages -> ios).
    private static let fontURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // ScrollRasterizerTests.swift -> RinaCoreTests
        for _ in 0..<4 { url.deleteLastPathComponent() } // -> Tests -> RinaCore -> Packages -> ios
        return url.appendingPathComponent("RinaBoard/Resources/ark12.json")
    }()

    private func loadFont() throws -> ArkPixelFont {
        guard FileManager.default.fileExists(atPath: Self.fontURL.path) else {
            throw XCTSkip("ark12.json not found at \(Self.fontURL.path)")
        }
        return try ArkPixelFont.loadBundled(url: Self.fontURL)
    }

    func testGlyphADecodesExpectedBitmap() throws {
        let font = try loadFont()
        let glyph = font.glyph(for: Unicode.Scalar(0x0041)!)
        XCTAssertFalse(glyph.isSpace)
        XCTAssertEqual(glyph.width, 6)
        XCTAssertEqual(glyph.height, 12)
        XCTAssertEqual(glyph.advance, 6)
        XCTAssertEqual(glyph.xOffset, 0)
        XCTAssertEqual(glyph.yOffset, -2)
        XCTAssertEqual(glyph.dstY, 0)

        // rowsHex "00/00/20/20/50/50/70/88/88/88/00/00"
        let expectedRows: [[Bool]] = [
            "000000", "000000", "001000", "001000", "010100", "010100",
            "011100", "100010", "100010", "100010", "000000", "000000",
        ].map { row in row.map { $0 == "1" } }
        XCTAssertEqual(glyph.rows.count, expectedRows.count)
        for (i, expected) in expectedRows.enumerated() {
            XCTAssertEqual(glyph.rows[i], expected, "row \(i)")
        }
        // Spot-check the rows called out in the spec explicitly.
        XCTAssertEqual(glyph.rows[2], "001000".map { $0 == "1" })
        XCTAssertEqual(glyph.rows[4], "010100".map { $0 == "1" })
        XCTAssertEqual(glyph.rows[7], "100010".map { $0 == "1" })
    }

    func testSpaceGlyphAdvance() throws {
        let font = try loadFont()
        let glyph = font.glyph(for: Unicode.Scalar(0x0020)!)
        XCTAssertTrue(glyph.isSpace)
        XCTAssertEqual(glyph.advance, ScrollRasterizer.spaceColumns)
        XCTAssertEqual(glyph.advance, 6)
    }

    func testMissingGlyphFallsBackToWhiteSquare() throws {
        let font = try loadFont()
        // A private-use codepoint that is very unlikely to be present in the table.
        let missing = font.glyph(for: Unicode.Scalar(0x10FFFD)!)
        let fallback = font.glyph(for: ArkPixelFont.missingGlyphScalar)
        XCTAssertEqual(missing.width, fallback.width)
        XCTAssertEqual(missing.height, fallback.height)
        XCTAssertEqual(missing.rows, fallback.rows)
    }

    func testBitmapWidthAndFrameCountForSingleCharacter() throws {
        let font = try loadFont()
        let bitmap = ScrollRasterizer.buildBitmap(text: "A", font: font)
        // width = max(52, 26 + 6 + 26) = 58
        XCTAssertEqual(bitmap.width, 58)
        let projected = ScrollRasterizer.projectedFrameCount(forBitmapWidth: bitmap.width)
        // frameCount = maxOffset + 1 = (58 - 22) + 1 = 37 (before rotation)
        XCTAssertEqual(projected, 37)
    }

    func testVerticalOffsetPlacesInkInExpectedMatrixRows() throws {
        let font = try loadFont()
        let bitmap = ScrollRasterizer.buildBitmap(text: "A", font: font)
        // baseY = verticalOffset(5) + dstY(0) + yOffset(-2) = 3.
        // Glyph ink rows 2..9 (0-indexed) -> matrix rows 5..12.
        let litRows = Set((0..<MatrixGeometry.rows).filter { y in bitmap.rows[y].contains(true) })
        XCTAssertEqual(litRows, Set(5...12))
    }

    func testFramesAreValidAndFirstFrameAfterRotationIsLit() throws {
        let font = try loadFont()
        let timeline = try ScrollRasterizer.makeTimeline(text: "A", font: font, fps: 10)
        XCTAssertFalse(timeline.frames.isEmpty)
        for frame in timeline.frames {
            XCTAssertTrue(frame.validate())
        }
        XCTAssertGreaterThan(timeline.frames[0].litCount, 0)
    }

    func testEmojiPresentationNormalisation() {
        XCTAssertEqual(ScrollText.normalizeEmojiPresentation("\u{1F600}"), "\u{1F600}\u{FE0E}")
        XCTAssertEqual(ScrollText.normalizeEmojiPresentation("\u{00A9}\u{FE0F}"), "\u{00A9}\u{FE0E}")
        XCTAssertEqual(ScrollText.normalizeEmojiPresentation("a"), "a")
    }

    func testTruncateIgnoresFormatControls() {
        let visible = String(repeating: "a", count: 1000)
        let withControls = String(repeating: "a\u{FE0F}", count: 1000) // 1000 visible 'a' + 1000 VS
        let truncated = ScrollText.truncate(withControls, maxVisibleChars: 1000)
        XCTAssertEqual(ScrollText.visibleCharCount(truncated), 1000)
        XCTAssertEqual(truncated.unicodeScalars.filter { !ScrollText.isEmojiFormatControl($0) }.count, visible.count)
    }

    func testDefaultTextTimelineWithinFrameBounds() throws {
        let font = try loadFont()
        let text = "RinaChanBoard 370 LED こんにちは 璃奈ちゃんボード"
        let start = Date()
        let timeline = try ScrollRasterizer.makeTimeline(text: text, font: font, fps: 10)
        let elapsed = Date().timeIntervalSince(start)
        print("[ScrollRasterizerTests] default-text rasterisation took \(elapsed * 1000) ms, frameCount=\(timeline.frameCount)")
        XCTAssertGreaterThan(timeline.frameCount, 100)
        XCTAssertLessThanOrEqual(timeline.frameCount, ScrollRasterizer.maxFrames)
        for frame in timeline.frames {
            XCTAssertTrue(frame.validate())
        }
    }

    func testBitmapPackedBytesRoundTripsOnePixel() {
        let width = 30
        let stride = (width + 7) / 8 // 4
        var rows = [[Bool]](repeating: [Bool](repeating: false, count: width), count: MatrixGeometry.rows)
        rows[5][25] = true
        let bitmap = ScrollBitmap(rows: rows, width: width)
        let packed = bitmap.packedBytes()
        XCTAssertEqual(packed.count, stride * MatrixGeometry.rows)

        // Unpack and verify only (25, 5) is lit.
        var unpacked = [[Bool]](repeating: [Bool](repeating: false, count: width), count: MatrixGeometry.rows)
        let bytes = [UInt8](packed)
        for y in 0..<MatrixGeometry.rows {
            for x in 0..<width {
                let byte = bytes[y * stride + (x >> 3)]
                unpacked[y][x] = (byte & (1 << (x & 7))) != 0
            }
        }
        for y in 0..<MatrixGeometry.rows {
            for x in 0..<width {
                XCTAssertEqual(unpacked[y][x], (x == 25 && y == 5), "pixel (\(x),\(y))")
            }
        }
    }

    func testTimelineRotationMatchesFirstLitFrameIndex() throws {
        let font = try loadFont()
        let text = "A"
        let bitmap = ScrollRasterizer.buildBitmap(text: text, font: font)
        let maxOffset = max(1, bitmap.width - MatrixGeometry.cols)
        var unrotatedFrames: [PackedFrame] = []
        for offset in 0...maxOffset {
            unrotatedFrames.append(ScrollRasterizer.frame(from: bitmap, offset: offset))
        }
        let expectedRotation = unrotatedFrames.firstIndex(where: { $0.litCount > 0 }) ?? 0

        let timeline = try ScrollRasterizer.makeTimeline(text: text, font: font, fps: 10)
        XCTAssertEqual(timeline.rotation, expectedRotation)
        XCTAssertGreaterThan(timeline.rotation, 0)
        XCTAssertEqual(timeline.frames[0].litCount, unrotatedFrames[expectedRotation].litCount)
    }

    func testVeryLongTextThrowsTooManyFrames() throws {
        let font = try loadFont()
        let longText = String(repeating: "璃", count: 3100)
        XCTAssertThrowsError(try ScrollRasterizer.makeTimeline(text: longText, font: font, fps: 10)) { error in
            guard case ScrollRasterizer.RasterizerError.tooManyFrames = error else {
                XCTFail("expected tooManyFrames, got \(error)")
                return
            }
        }
    }
}
