import UIKit
import XCTest
@testable import RinaBoard

@MainActor
final class BootAnimationResizeTests: XCTestCase {
    // Drives the actual UIKit/CA stage, including an outro scheduled before
    // its first layout, then the outer/inner Duo and iPad rotation sizes.
    func testRevealUsesFirstValidBoundsWithoutRestartingItsClock() throws {
        try assertResizeSequence(startingAt: .zero)
    }

    func testRevealKeepsItsFeatherWhenFoldedAndRotatedMidOutro() throws {
        try assertResizeSequence(startingAt: CGSize(width: 466, height: 678))
    }

    private func assertResizeSequence(startingAt size: CGSize) throws {
        let stage = BootStageView(frame: CGRect(origin: .zero, size: size))
        stage.setNeedsLayout()
        stage.layoutIfNeeded()
        stage.breathe(period: 1.62, since: Date())
        stage.runOutro(since: Date())
        let blur = try XCTUnwrap(stage.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        let mask = try XCTUnwrap(blur.mask)
        let gradient = try XCTUnwrap(mask.layer as? CAGradientLayer)
        let original = try XCTUnwrap(gradient.animation(forKey: "reveal") as? CAKeyframeAnimation)
        for size in [CGSize(width: 466, height: 678), CGSize(width: 668, height: 950),
                     CGSize(width: 950, height: 668), CGSize(width: 834, height: 1194),
                     CGSize(width: 1194, height: 834), CGSize(width: 466, height: 678)] {
            stage.bounds.size = size
            stage.setNeedsLayout()
            stage.layoutIfNeeded()
            let animation = try XCTUnwrap(gradient.animation(forKey: "reveal") as? CAKeyframeAnimation)
            XCTAssertEqual(animation.beginTime, original.beginTime, accuracy: 0.001)
            XCTAssertEqual(animation.duration, original.duration)
            let stops = try XCTUnwrap(animation.values?.last as? [NSNumber])
            let extentX = (gradient.endPoint.x - 0.5) * size.width
            let extentY = (gradient.endPoint.y - 0.5) * size.height
            XCTAssertEqual(extentX, extentY, accuracy: 0.001, "Reveal must stay circular")
            XCTAssertEqual((stops[2].doubleValue - stops[1].doubleValue) * extentX,
                           100, accuracy: 0.001, "Resize must retain a 100 pt feather")
            XCTAssertGreaterThan(stops[1].doubleValue * extentX,
                                 hypot(size.width / 2, size.height / 2), "Reveal must clear every corner")
            XCTAssertEqual(blur.frame.size, size)
            XCTAssertEqual(mask.frame.size, size)
            let avatar = try XCTUnwrap(stage.subviews.first { $0.layer.cornerRadius == 53 })
            XCTAssertEqual(avatar.bounds.size, CGSize(width: 106, height: 106))
            XCTAssertEqual(avatar.center, CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }
}
