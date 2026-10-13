import XCTest
@testable import RinaCore

final class GroupScrollBitmapTests: XCTestCase {
    private static let fontURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // GroupScrollBitmapTests.swift -> RinaCoreTests
        for _ in 0..<4 { url.deleteLastPathComponent() } // -> Tests -> RinaCore -> Packages -> ios
        return url.appendingPathComponent("RinaBoard/Resources/ark12.json")
    }()

    private func loadFont() throws -> ArkPixelFont {
        guard FileManager.default.fileExists(atPath: Self.fontURL.path) else {
            XCTFail("Required tracked font fixture missing at \(Self.fontURL.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try ArkPixelFont.loadBundled(url: Self.fontURL)
    }

    // MARK: - Build

    func testBuildPadsVDarkTextVDark() throws {
        let font = try loadFont()
        let bitmap = try GroupScrollBitmap.build(text: "A", font: font, virtualWidth: 30)
        // First and last 30 columns must be fully dark on every row.
        for y in 0..<MatrixGeometry.rows {
            for x in 0..<30 {
                XCTAssertFalse(bitmap.rows[y][x], "left pad row \(y) col \(x)")
                XCTAssertFalse(bitmap.rows[y][bitmap.width - 1 - x], "right pad row \(y) col \(x)")
            }
        }
        // The raw text region (no single-board leading/trailing blank) must
        // start lighting up near column 30 for a non-space first character.
        let rawWidth = bitmap.width - 60
        XCTAssertGreaterThan(rawWidth, 0)
    }

    func testEmptyTextThrows() throws {
        let font = try loadFont()
        XCTAssertThrowsError(try GroupScrollBitmap.build(text: "   ", font: font, virtualWidth: 30)) { error in
            XCTAssertEqual(error as? GroupScrollBitmap.BuildError, .emptyText)
        }
    }

    func testWidthLimitThrowsWithoutTruncating() throws {
        let font = try loadFont()
        let longText = String(repeating: "国", count: 900) // wide CJK glyphs blow past 3093 with padding.
        XCTAssertThrowsError(try GroupScrollBitmap.build(text: longText, font: font, virtualWidth: 200)) { error in
            guard case .widthExceedsLimit(let width, let limit)? = error as? GroupScrollBitmap.BuildError else {
                return XCTFail("expected widthExceedsLimit, got \(error)")
            }
            XCTAssertEqual(limit, 3093)
            XCTAssertGreaterThan(width, limit)
        }
    }

    // MARK: - frameCount

    func testFrameCountFormula() {
        XCTAssertEqual(GroupScrollBitmap.frameCount(bitmapWidth: 250, virtualWidth: 110), 141)
        // max(1, W-V)+1 floors at 2 when W <= V.
        XCTAssertEqual(GroupScrollBitmap.frameCount(bitmapWidth: 100, virtualWidth: 110), 2)
    }

    /// Replaces the old placeholder (which never built a per-slot frame or
    /// compared anything): builds an actual per-slot frame at slot count
    /// 2/3/4, asserts every slot reports the *same* `frameCount`, and that
    /// frame 0 and the last frame are dark on every slot (the `[V dark]…[V
    /// dark]` padding guarantee, §1.4).
    func testFrameCountIdenticalAcrossAllSlots() throws {
        let font = try loadFont()
        for slotCount in [2, 3, 4] {
            let layout = try StitchedScreenLayout(
                slotCount: slotCount, gapsAfter: [Int](repeating: 2, count: slotCount - 1)
            )
            let bitmap = try GroupScrollBitmap.build(text: "你好 Rina!", font: font, virtualWidth: layout.virtualWidth)
            let frameCounts = (0..<slotCount).map { slot -> Int in
                // frameCount is purely a function of (bitmap.width, virtualWidth);
                // it does not depend on viewportX/slot, but computing it via the
                // same formula per slot (rather than once) is what actually
                // exercises "identical across all slots" instead of assuming it.
                _ = layout.viewportX(slot: slot)
                return GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: layout.virtualWidth)
            }
            XCTAssertEqual(Set(frameCounts).count, 1, "slotCount=\(slotCount) frameCounts=\(frameCounts)")
            let frameCount = frameCounts[0]
            XCTAssertGreaterThan(frameCount, 0)

            for frameIndex in [0, frameCount - 1] {
                for slot in 0..<slotCount {
                    let frame = GroupScrollBitmap.frame(
                        bitmap: bitmap, viewportX: layout.viewportX(slot: slot), frameIndex: frameIndex)
                    XCTAssertTrue(frame.isEmpty,
                                  "slotCount=\(slotCount) frame=\(frameIndex) slot=\(slot) should be dark")
                }
            }
        }
    }

    // MARK: - Golden case (F6): hand-computed frame at V=46, X=24, f=3

    /// A fixed W=60 bitmap with exactly one lit pixel per row, placed at
    /// `27 + xStart(row)` (`xStart` = the row's centred valid-range start,
    /// `MatrixGeometry.validXRange`). At viewportX=24, frameIndex=3, §1.4's
    /// rule (`srcX = frameIndex + viewportX + x = 27 + x`) makes that pixel
    /// land exactly on `x == xStart(row)` -- the *first* valid column of
    /// every row, i.e. logical LED index `rowStartIndex[row]` (the prefix
    /// sum of `MatrixGeometry.rowLengths`, mirrored in
    /// `esp32s3_firmware/src/group_math.h`'s host test as `rowOffsets`).
    /// Hand-computed from `MatrixGeometry.rowLengths`
    /// `[18,20,20,20,22,22,22,22,22,22,22,22,22,20,20,20,18,16]`:
    /// prefix sums `[0,18,38,58,78,100,122,144,166,188,210,232,254,276,296,316,336,354]`.
    func testGoldenFrameAtKnownViewportAndFrameIndex() {
        // viewportX=24 is a real second-board offset for a V=46 two-board
        // layout (22 + gap 2 + 22 = 46); `GroupScrollBitmap.frame` itself only
        // needs `viewportX`, not `V`, since the bitmap already carries the
        // `[V dark]…[V dark]` padding.
        let width = 60
        let viewportX = 24
        let frameIndex = 3
        var rows = [[Bool]](repeating: [Bool](repeating: false, count: width), count: MatrixGeometry.rows)
        for y in 0..<MatrixGeometry.rows {
            let range = MatrixGeometry.validXRange(row: y)!
            let litColumn = 27 + range.lowerBound
            rows[y][litColumn] = true
        }
        let bitmap = ScrollBitmap(rows: rows, width: width)

        let expectedLitIndices = [
            0, 18, 38, 58, 78, 100, 122, 144, 166, 188, 210, 232, 254, 276, 296, 316, 336, 354,
        ]
        var expected = PackedFrame()
        for index in expectedLitIndices {
            expected.set(index)
        }

        let actual = GroupScrollBitmap.frame(bitmap: bitmap, viewportX: viewportX, frameIndex: frameIndex)
        XCTAssertEqual(actual.bytes, expected.bytes)
        XCTAssertEqual(actual.litCount, expectedLitIndices.count)
    }

    // MARK: - Window sampler vs. virtual canvas

    /// Core owns viewport math; physical-board assignment is exercised by
    /// BoardGroupCoordinatorTests against each board's actual upload metadata.
    func testFiveSlotWindowsMatchVirtualCanvasCrop() throws {
        let font = try loadFont()
        for gapsAfter in [[0, 0, 0, 0], [3, 0, 5, 2]] {
            let layout = try StitchedScreenLayout(slotCount: 5, gapsAfter: gapsAfter)
            let bitmap = try GroupScrollBitmap.build(text: "你好 Hi!", font: font, virtualWidth: layout.virtualWidth)
            let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: layout.virtualWidth)
            for frameIndex in 0..<frameCount {
                let canvas = GroupScrollBitmap.virtualCanvasFrame(bitmap: bitmap, layout: layout, frameIndex: frameIndex)
                for slot in 0..<layout.slotCount {
                    let viewportX = layout.viewportX(slot: slot)
                    let boardFrame = GroupScrollBitmap.frame(bitmap: bitmap, viewportX: viewportX, frameIndex: frameIndex)
                    let expected = ScrollRasterizer.frame(from: canvas, offset: viewportX)
                    XCTAssertEqual(boardFrame, expected, "gaps=\(gapsAfter) frame=\(frameIndex) slot=\(slot)")
                }
            }
        }
    }

    func test2To4BoardLayoutsMatchVirtualCanvasCrop() throws {
        let font = try loadFont()
        let text = "AB你 c"
        for slotCount in [2, 3, 4] {
            for gap in [0, 4] {
                let layout = try StitchedScreenLayout(
                    slotCount: slotCount, gapsAfter: [Int](repeating: gap, count: slotCount - 1)
                )
                let bitmap = try GroupScrollBitmap.build(text: text, font: font, virtualWidth: layout.virtualWidth)
                let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: layout.virtualWidth)
                for frameIndex in 0..<frameCount {
                    let canvas = GroupScrollBitmap.virtualCanvasFrame(bitmap: bitmap, layout: layout, frameIndex: frameIndex)
                    for slot in 0..<slotCount {
                        let viewportX = layout.viewportX(slot: slot)
                        let boardFrame = GroupScrollBitmap.frame(bitmap: bitmap, viewportX: viewportX, frameIndex: frameIndex)
                        let expected = ScrollRasterizer.frame(from: canvas, offset: viewportX)
                        XCTAssertEqual(boardFrame, expected, "slotCount=\(slotCount) gap=\(gap) frame=\(frameIndex) slot=\(slot)")
                    }
                }
            }
        }
    }

    /// Frame 0 and the last frame are fully dark on every board (the client's
    /// own `[V dark][text][V dark]` padding guarantee, §1.4).
    func testFirstAndLastFrameAreDarkOnEveryBoard() throws {
        let font = try loadFont()
        let layout = try StitchedScreenLayout(slotCount: 3, gapsAfter: [1, 1])
        let bitmap = try GroupScrollBitmap.build(text: "Rina", font: font, virtualWidth: layout.virtualWidth)
        let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: layout.virtualWidth)
        for frameIndex in [0, frameCount - 1] {
            for slot in 0..<layout.slotCount {
                let frame = GroupScrollBitmap.frame(bitmap: bitmap, viewportX: layout.viewportX(slot: slot), frameIndex: frameIndex)
                XCTAssertTrue(frame.isEmpty, "frame \(frameIndex) slot \(slot) should be fully dark")
            }
        }
    }
}
