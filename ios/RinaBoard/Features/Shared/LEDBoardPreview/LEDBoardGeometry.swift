import CoreGraphics
import RinaCore

/// One physically existing LED, resolved to a rectangle in view space.
///
/// `id` / `ledIndex` is the *logical* LED index used by `PackedFrame` and the
/// RinaLink wire format (`MatrixGeometry.ledIndex(x:y:)`), which is what the
/// firmware frame is addressed by — `MatrixGeometry.logicalToPhysicalIndex`
/// exists for strip wiring order only and is deliberately not used here.
struct LEDCell: Identifiable, Hashable {
    let id: Int
    let gridX: Int
    let gridY: Int

    var ledIndex: Int { id }
}

/// Physical board topology, independent of any SwiftUI view (design guide §12:
/// "the physical mapping must come from the existing board layout, not from a
/// rectangular 370-cell approximation").
///
/// The 22×18 grid is masked by `MatrixGeometry.rowLengths`, so rows are 16…22
/// cells wide and centred — only the 370 cells enumerated here exist.
enum LEDBoardGeometry {
    static let cols = MatrixGeometry.cols
    static let rows = MatrixGeometry.rows

    /// Every physically valid cell, in logical LED order.
    static let cells: [LEDCell] = {
        var result: [LEDCell] = []
        result.reserveCapacity(MatrixGeometry.ledCount)
        for y in 0..<MatrixGeometry.rows {
            guard let xRange = MatrixGeometry.validXRange(row: y) else { continue }
            for x in xRange {
                guard let led = MatrixGeometry.ledIndex(x: x, y: y) else { continue }
                result.append(LEDCell(id: led, gridX: x, gridY: y))
            }
        }
        return result
    }()

    /// `[y][x]` → logical LED index, or `nil` where no LED exists. Used by the
    /// bloom renderer's neighbour lookups and by hit testing.
    static let indexGrid: [[Int?]] = {
        var grid = [[Int?]](repeating: [Int?](repeating: nil, count: MatrixGeometry.cols),
                            count: MatrixGeometry.rows)
        for cell in cells {
            grid[cell.gridY][cell.gridX] = cell.id
        }
        return grid
    }()

    /// The logical LED at grid position, or `nil` if that position has no LED.
    static func ledIndex(gridX: Int, gridY: Int) -> Int? {
        guard gridY >= 0, gridY < rows, gridX >= 0, gridX < cols else { return nil }
        return indexGrid[gridY][gridX]
    }
}

/// A rectangular window onto the grid, in grid coordinates. Used to draw one
/// face region (an eye, the mouth) on its own rather than shrinking the whole
/// board into a thumbnail.
struct LEDBoardRegion: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    static let wholeBoard = LEDBoardRegion(x: 0, y: 0,
                                           width: LEDBoardGeometry.cols,
                                           height: LEDBoardGeometry.rows)

    /// A fixed-size square window centred on one layout box, clamped to the
    /// board. Every part thumbnail uses the same window size regardless of how
    /// big the part's own box is, matching the WebUI, which draws every option
    /// — eyes, mouth and the 4×4 cheek alike — into one 8×8 mini grid
    /// (`miniPreviewHtml`). A group with two boxes (the cheeks) shows its first
    /// box; the two sides sit 14 columns apart and cannot share a window.
    static func window(around box: (x: Int, y: Int, w: Int, h: Int), side: Int) -> LEDBoardRegion {
        let side = min(side, min(LEDBoardGeometry.cols, LEDBoardGeometry.rows))
        let x = min(max(0, box.x + box.w / 2 - side / 2), LEDBoardGeometry.cols - side)
        let y = min(max(0, box.y + box.h / 2 - side / 2), LEDBoardGeometry.rows - side)
        return LEDBoardRegion(x: x, y: y, width: side, height: side)
    }
}

/// Maps the 22×18 grid into a concrete view rectangle.
///
/// Two modes, matching the WebUI stylesheet (`.rinaboard-stage`):
/// - `usePhoto`: the board photo is laid out to fill the available size, and
///   the grid is pinned to the photo's own LED window so the drawn LEDs sit
///   exactly on the physical ones in the picture.
/// - otherwise: a bare centred grid on a dark surface (thumbnails, Text/Live
///   Video previews).
struct LEDBoardLayout: Equatable {
    /// Side of one grid cell, gaps included.
    let cell: CGFloat
    /// Top-left of grid position (0, 0), in view space.
    let origin: CGPoint
    /// Where the board photo is drawn; `.zero` when no photo is used.
    let stage: CGRect
    /// The window of the grid this layout actually draws. Hit testing is
    /// clamped to it, so a cropped preview can never report a tap on a cell
    /// that isn't visible in it.
    let region: LEDBoardRegion

    // Board photo geometry in picture space: the picture is 4000×3351 px and
    // the 22×18 LED window starts at (597.66, 850.71) with a 127.43 px pitch.
    static let photoWidth: CGFloat = 4000
    static let photoHeight: CGFloat = 3351
    private static let photoGridLeft: CGFloat = 597.66
    private static let photoGridTop: CGFloat = 850.71
    private static let photoCell: CGFloat = 127.43

    /// Aspect ratio the preview should be constrained to.
    static func aspectRatio(usePhoto: Bool, region: LEDBoardRegion) -> CGFloat {
        if usePhoto { return photoWidth / photoHeight }
        return CGFloat(region.width) / CGFloat(region.height)
    }

    /// Lays out just `region`, filling the available size. The origin still
    /// refers to grid (0, 0), so every cell-addressing helper keeps working —
    /// cells outside the region simply fall outside the view and are clipped.
    static func make(in size: CGSize, region: LEDBoardRegion) -> LEDBoardLayout {
        guard size.width > 0, size.height > 0, region.width > 0, region.height > 0 else {
            return LEDBoardLayout(cell: 0, origin: .zero, stage: .zero, region: .wholeBoard)
        }
        let cell = min(size.width / CGFloat(region.width), size.height / CGFloat(region.height))
        let drawnSize = CGSize(width: cell * CGFloat(region.width), height: cell * CGFloat(region.height))
        return LEDBoardLayout(
            cell: cell,
            origin: CGPoint(x: (size.width - drawnSize.width) / 2 - CGFloat(region.x) * cell,
                            y: (size.height - drawnSize.height) / 2 - CGFloat(region.y) * cell),
            stage: .zero,
            region: region
        )
    }

    static func make(in size: CGSize, usePhoto: Bool) -> LEDBoardLayout {
        guard size.width > 0, size.height > 0 else {
            return LEDBoardLayout(cell: 0, origin: .zero, stage: .zero, region: .wholeBoard)
        }
        if usePhoto {
            let scale = min(size.width / photoWidth, size.height / photoHeight)
            let stageSize = CGSize(width: photoWidth * scale, height: photoHeight * scale)
            let stage = CGRect(x: (size.width - stageSize.width) / 2,
                               y: (size.height - stageSize.height) / 2,
                               width: stageSize.width,
                               height: stageSize.height)
            return LEDBoardLayout(
                cell: photoCell * scale,
                origin: CGPoint(x: stage.minX + photoGridLeft * scale,
                                y: stage.minY + photoGridTop * scale),
                stage: stage,
                region: .wholeBoard
            )
        }
        let cell = min(size.width / CGFloat(LEDBoardGeometry.cols),
                       size.height / CGFloat(LEDBoardGeometry.rows))
        let gridSize = CGSize(width: cell * CGFloat(LEDBoardGeometry.cols),
                              height: cell * CGFloat(LEDBoardGeometry.rows))
        return LEDBoardLayout(
            cell: cell,
            origin: CGPoint(x: (size.width - gridSize.width) / 2,
                            y: (size.height - gridSize.height) / 2),
            stage: .zero,
            region: .wholeBoard
        )
    }

    /// The full cell, gaps included. Lit cells that are 4-neighbours share an
    /// edge here, which is what lets the bloom renderer treat them as one
    /// connected luminous region (design guide §14.1).
    func cellRect(gridX: Int, gridY: Int) -> CGRect {
        CGRect(x: origin.x + CGFloat(gridX) * cell,
               y: origin.y + CGFloat(gridY) * cell,
               width: cell,
               height: cell)
    }

    /// The drawn LED square: the cell inset by a very small gap so the matrix
    /// still reads as a dense physical grid (design guide §13).
    func ledRect(gridX: Int, gridY: Int, gapRatio: CGFloat) -> CGRect {
        cellRect(gridX: gridX, gridY: gridY).insetBy(dx: cell * gapRatio / 2,
                                                     dy: cell * gapRatio / 2)
    }

    /// Hit testing by physical LED geometry (design guide §17): returns the
    /// logical LED index the point falls on, or `nil` for positions where no
    /// LED physically exists — those must never respond to taps.
    func ledIndex(at point: CGPoint) -> Int? {
        guard cell > 0 else { return nil }
        let fx = (point.x - origin.x) / cell
        let fy = (point.y - origin.y) / cell
        // `Int` truncates toward zero, so a point just left of/above the grid
        // would otherwise land on row/column 0.
        guard fx >= 0, fy >= 0 else { return nil }
        let gridX = Int(fx)
        let gridY = Int(fy)
        guard gridX >= region.x, gridX < region.x + region.width,
              gridY >= region.y, gridY < region.y + region.height else { return nil }
        return LEDBoardGeometry.ledIndex(gridX: gridX, gridY: gridY)
    }
}
