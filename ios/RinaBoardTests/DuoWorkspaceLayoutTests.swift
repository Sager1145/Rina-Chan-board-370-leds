import SwiftUI
import XCTest
@testable import RinaBoard

final class DuoWorkspaceLayoutTests: XCTestCase {
    func testNativeBarReflowDoesNotMisclassifyTheInnerDisplay() {
        XCTAssertTrue(DuoWorkspaceDetection.isInnerDisplay(viewportSize: CGSize(width: 951, height: 553), displaySize: CGSize(width: 951, height: 669), isPhone: true, folded: false, hasDivision: false, previousInner: false))
        XCTAssertFalse(DuoWorkspaceDetection.isInnerDisplay(viewportSize: CGSize(width: 466, height: 562), displaySize: CGSize(width: 669, height: 951), isPhone: true, folded: true, hasDivision: false, previousInner: true))
        XCTAssertFalse(DuoWorkspaceDetection.isInnerDisplay(viewportSize: CGSize(width: 430, height: 800), displaySize: CGSize(width: 430, height: 932), isPhone: true, folded: false, hasDivision: false, previousInner: false))
    }
    func testPhoneOuterDisplaySupportsOnlyPortraitWhileInnerDisplayCanRotate() {
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: CGSize(width: 466, height: 678), idiom: .phone), .portrait)
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: CGSize(width: 678, height: 466), idiom: .phone), .portrait)
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: CGSize(width: 668, height: 950), idiom: .phone), .all)
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: CGSize(width: 950, height: 668), idiom: .phone), .all)
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: CGSize(width: 466, height: 678), idiom: .pad), .all)
    }
    func testBootAndHingeHandoffKeepClosedPhonePortrait() {
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: nil, idiom: .phone), .portrait)
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: CGSize(width: 951, height: 669), idiom: .phone, innerDisplay: true, folded: true), .portrait)
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: CGSize(width: 466, height: 678), idiom: .phone, innerDisplay: true), .all)
        XCTAssertEqual(RinaPhoneOrientationPolicy.mask(displaySize: nil, idiom: .pad), .all)
    }

    func testHorizontalFoldKeepsBothControlPanelsBelowTheReservedBand() {
        let frames = DuoWorkspaceFrames.resolve(
            size: CGSize(width: 668, height: 900),
            division: CGRect(x: 0, y: 420, width: 668, height: 24), stackLowerPanels: false)
        XCTAssertEqual(frames.preview, CGRect(x: 0, y: 0, width: 668, height: 420))
        XCTAssertEqual(frames.controlCenter, CGRect(x: 0, y: 444, width: 334, height: 456))
        XCTAssertEqual(frames.tabControls, CGRect(x: 334, y: 444, width: 334, height: 456))
    }

    func testVerticalFoldSeparatesTheTabAndLeavesRoomForBoardControls() {
        let frames = DuoWorkspaceFrames.resolve(
            size: CGSize(width: 950, height: 668),
            division: CGRect(x: 450, y: 0, width: 24, height: 668), stackLowerPanels: false)
        XCTAssertEqual(frames.preview.minX, 0)
        XCTAssertEqual(frames.preview.maxX, 450)
        XCTAssertEqual(frames.controlCenter.maxX, 450)
        XCTAssertEqual(frames.tabControls, CGRect(x: 474, y: 0, width: 476, height: 668))
        XCTAssertEqual(frames.tabControls.minX, 474)
        XCTAssertEqual(frames.preview.maxY, frames.controlCenter.minY)
        XCTAssertGreaterThan(frames.controlCenter.height, 300)
        XCTAssertEqual(frames.controlCenter.maxY, 668)
    }

    func testVerticalFoldFillsBothUsableRegionsWithSidebarOnEitherSide() {
        let size = CGSize(width: 900, height: 668)
        for hingeX in [CGFloat(410), CGFloat(470)] {
            let frames = DuoWorkspaceFrames.resolve(size: size,
                division: CGRect(x: hingeX, y: 0, width: 24, height: 668), stackLowerPanels: false)
            XCTAssertEqual(frames.preview.minX, 0)
            XCTAssertEqual(frames.preview.maxX, hingeX)
            XCTAssertEqual(frames.controlCenter.width, hingeX)
            XCTAssertEqual(frames.tabControls.minX, hingeX + 24)
            XCTAssertEqual(frames.tabControls.maxX, size.width)
        }
    }

    func testKeyboardCannotLeaveTheEditorAtZeroHeightAboveAHorizontalFold() {
        let frames = DuoWorkspaceFrames.resolve(
            size: CGSize(width: 668, height: 400),
            division: CGRect(x: 0, y: 420, width: 668, height: 24), stackLowerPanels: false)
        XCTAssertGreaterThan(frames.tabControls.height, 160)
        XCTAssertLessThanOrEqual(frames.preview.maxY, 400)
        XCTAssertLessThanOrEqual(frames.controlCenter.maxY, 400)
        XCTAssertLessThanOrEqual(frames.tabControls.maxY, 400)
    }

    func testFlatDisplayHasNoArtificialFoldGap() {
        let frames = DuoWorkspaceFrames.resolve(size: CGSize(width: 950, height: 668),
                                                division: nil, stackLowerPanels: false)
        XCTAssertEqual(frames.preview.maxX, 475)
        XCTAssertEqual(frames.controlCenter.maxX, 475)
        XCTAssertEqual(frames.tabControls.minX, 475)
        XCTAssertEqual(frames.tabControls.maxX, 950)
    }

    func testAccessibilityPanelsStackWithinTheLowerRegion() {
        let frames = DuoWorkspaceFrames.resolve(
            size: CGSize(width: 668, height: 900),
            division: CGRect(x: 0, y: 420, width: 668, height: 24), stackLowerPanels: true)
        XCTAssertEqual(frames.controlCenter, CGRect(x: 0, y: 444, width: 668, height: 228))
        XCTAssertEqual(frames.tabControls, CGRect(x: 0, y: 672, width: 668, height: 228))
    }
    func testRotationDiscardsThePreviousOrientationsDivision() {
        let landscape = CGSize(width: 950, height: 668)
        let portrait = CGSize(width: 668, height: 950)
        let oldHorizontal = CGRect(x: 0, y: 450, width: 668, height: 24)
        let oldVertical = CGRect(x: 450, y: 0, width: 24, height: 668)
        XCTAssertNil(DuoWorkspaceFrames.validDivision(oldHorizontal, in: landscape))
        XCTAssertNil(DuoWorkspaceFrames.validDivision(oldVertical, in: portrait))
        for size in [landscape, portrait, landscape, portrait] {
            let stale = size == landscape ? oldHorizontal : oldVertical
            let frames = DuoWorkspaceFrames.resolve(size: size, division: stale, stackLowerPanels: false)
            XCTAssertEqual(frames.tabControls.minY, 0)
            XCTAssertEqual(frames.tabControls.width, frames.controlCenter.width)
            XCTAssertEqual(frames.tabControls.maxX, size.width)
        }
    }

    func testRotationDiscardsOversizedBandsFromThePreviousOrientation() {
        for (size, stale) in [
            (CGSize(width: 668, height: 950), CGRect(x: 0, y: 300, width: 950, height: 24)),
            (CGSize(width: 950, height: 668), CGRect(x: 300, y: 0, width: 24, height: 950))
        ] {
            XCTAssertNil(DuoWorkspaceFrames.validDivision(stale, in: size))
            let frames = DuoWorkspaceFrames.resolve(size: size, division: stale, stackLowerPanels: false)
            XCTAssertEqual(frames.tabControls.minY, 0)
            XCTAssertEqual(frames.controlCenter.width, size.width / 2)
            XCTAssertEqual(frames.tabControls.width, size.width / 2)
        }
    }

}
