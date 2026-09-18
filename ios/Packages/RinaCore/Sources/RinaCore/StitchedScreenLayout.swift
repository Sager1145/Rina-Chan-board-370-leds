import Foundation

/// Left-to-right layout of 1...5 boards stitched into one virtual screen
/// (BOARD_GROUP_SPEC.md §2). Board width is always `MatrixGeometry.cols`
/// (22); a "gap" is the number of blank virtual columns between one board's
/// right edge and the next board's left edge.
///
/// Given `slotCount` in `1...5` and `gapsAfter` each in `0...8`,
/// `virtualWidth` is always in `22...200`, matching the `get_info`/
/// `scroll_bitmap` `virtualWidth` bound (BOARD_GROUP_SPEC.md §1.1/§1.4) — no
/// extra clamping is needed here.
public struct StitchedScreenLayout: Sendable, Equatable {
    /// Number of boards in the stitched screen.
    public let slotCount: Int
    /// Gap (in virtual columns) after slot `i`, for `i` in `0..<slotCount-1`.
    public let gapsAfter: [Int]
    /// Total width of the stitched virtual screen, in virtual columns.
    public let virtualWidth: Int

    private let offsets: [Int]

    public enum LayoutError: Error, Equatable, Sendable {
        case invalidSlotCount(Int)
        case invalidGapsCount(expected: Int, got: Int)
        case invalidGap(index: Int, value: Int)
    }

    public init(slotCount: Int, gapsAfter: [Int]) throws {
        guard (1...5).contains(slotCount) else {
            throw LayoutError.invalidSlotCount(slotCount)
        }
        guard gapsAfter.count == slotCount - 1 else {
            throw LayoutError.invalidGapsCount(expected: slotCount - 1, got: gapsAfter.count)
        }
        for (index, gap) in gapsAfter.enumerated() where !(0...8).contains(gap) {
            throw LayoutError.invalidGap(index: index, value: gap)
        }

        var offsets = [Int](repeating: 0, count: slotCount)
        var x = 0
        for slot in 0..<slotCount {
            offsets[slot] = x
            x += MatrixGeometry.cols
            if slot < gapsAfter.count {
                x += gapsAfter[slot]
            }
        }

        self.slotCount = slotCount
        self.gapsAfter = gapsAfter
        self.offsets = offsets
        self.virtualWidth = x
    }

    /// This slot's left edge inside the virtual screen (`viewportX`,
    /// BOARD_GROUP_SPEC.md §1.4). `slot` must be `0..<slotCount`.
    public func viewportX(slot: Int) -> Int {
        precondition(slot >= 0 && slot < slotCount, "slot \(slot) out of range 0..<\(slotCount)")
        return offsets[slot]
    }
}
