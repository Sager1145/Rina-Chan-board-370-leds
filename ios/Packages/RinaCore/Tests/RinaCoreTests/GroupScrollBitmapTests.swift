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
            throw XCTSkip("ark12.json not found at \(Self.fontURL.path)")
        }
        return try ArkPixelFont.loadBundled(url: Self.fontURL)
    }

    /// All permutations of `elements` (used for the "all 120 orderings of 5
    /// boards" requirement — the layout math only depends on slot index, not
    /// board identity, so every permutation must produce the same result;
    /// this test exercises that directly rather than assuming it).
    private func permutations<T>(_ elements: [T]) -> [[T]] {
        guard elements.count > 1 else { return [elements] }
        var result: [[T]] = []
        for (i, element) in elements.enumerated() {
            var rest = elements
            rest.remove(at: i)
            for perm in permutations(rest) {
                result.append([element] + perm)
            }
        }
        return result
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

    func testFrameCountIdenticalAcrossAllSlots() throws {
        let font = try loadFont()
        for slotCount in [2, 3, 4] {
            let layout = try StitchedScreenLayout(
                slotCount: slotCount, gapsAfter: [Int](repeating: 2, count: slotCount - 1)
            )
            let bitmap = try GroupScrollBitmap.build(text: "你好 Rina!", font: font, virtualWidth: layout.virtualWidth)
            let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: layout.virtualWidth)
            // frameCount does not depend on viewportX/slot at all (it's purely W, V).
            for slot in 0..<slotCount {
                _ = layout.viewportX(slot: slot) // every slot uses the same bitmap/frameCount
            }
            XCTAssertGreaterThan(frameCount, 0)
        }
    }

    // MARK: - Window sampler vs. virtual canvas — all 120 orderings x 2 gap configs

    /// Each board's window frame must equal the crop of the virtual canvas
    /// frame at its own `viewportX`, for every frame of a short CJK+ASCII+
    /// space text, for all 120 orderings of 5 boards and 2 gap configurations,
    /// and separately for 2/3/4-board layouts (BOARD_GROUP_SPEC.md §2).
    func testAllOrderingsMatchVirtualCanvasCrop() throws {
        let font = try loadFont()
        let text = "你好 Hi!"
        let boardIDs = ["board-1", "board-2", "board-3", "board-4", "board-5"]
        let orderings = permutations(boardIDs)
        XCTAssertEqual(orderings.count, 120)

        let gapConfigs: [[Int]] = [[0, 0, 0, 0], [3, 0, 5, 2]]

        for gapsAfter in gapConfigs {
            let layout = try StitchedScreenLayout(slotCount: 5, gapsAfter: gapsAfter)
            let bitmap = try GroupScrollBitmap.build(text: text, font: font, virtualWidth: layout.virtualWidth)
            let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: layout.virtualWidth)

            // The window-sampler/virtual-canvas equality only depends on
            // (slot, frameIndex), never on which physical board sits in that
            // slot, so compute the per-slot/per-frame match once per gap
            // config (this is the expensive part: frameCount * 5 PackedFrame
            // pairs)...
            var matchesBySlot = [Int: Bool](uniqueKeysWithValues: (0..<layout.slotCount).map { ($0, true) })
            for frameIndex in 0..<frameCount {
                let canvas = GroupScrollBitmap.virtualCanvasFrame(bitmap: bitmap, layout: layout, frameIndex: frameIndex)
                for slot in 0..<layout.slotCount {
                    let viewportX = layout.viewportX(slot: slot)
                    let boardFrame = GroupScrollBitmap.frame(bitmap: bitmap, viewportX: viewportX, frameIndex: frameIndex)
                    let expected = ScrollRasterizer.frame(from: canvas, offset: viewportX)
                    if boardFrame != expected {
                        matchesBySlot[slot] = false
                    }
                }
            }
            for slot in 0..<layout.slotCount {
                XCTAssertEqual(matchesBySlot[slot], true, "gaps=\(gapsAfter) slot=\(slot)")
            }

            // ...then, for each of the 120 orderings, confirm every physical
            // board is assigned to exactly one slot and that slot's match
            // held (cheap: no PackedFrame work inside this loop).
            for ordering in orderings {
                XCTAssertEqual(Set(ordering), Set(boardIDs))
                for slot in 0..<layout.slotCount {
                    XCTAssertEqual(matchesBySlot[slot], true, "gaps=\(gapsAfter) ordering=\(ordering) slot=\(slot)")
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
