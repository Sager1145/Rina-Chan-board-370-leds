import XCTest
import RinaCore

/// The LED at `(x, y)` and the one reflected across the board's vertical
/// centre line on the same row — the pair the Draw「镜像」 keeps in step.
func mirrorPair(x: Int, y: Int) throws -> (left: Int, right: Int) {
    let left = try XCTUnwrap(MatrixGeometry.ledIndex(x: x, y: y))
    let right = try XCTUnwrap(MatrixGeometry.ledIndex(x: MatrixGeometry.cols - 1 - x, y: y))
    return (left, right)
}
