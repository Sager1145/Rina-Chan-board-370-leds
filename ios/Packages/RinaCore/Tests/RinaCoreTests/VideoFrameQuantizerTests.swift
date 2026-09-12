import XCTest
@testable import RinaCore

final class VideoFrameQuantizerTests: XCTestCase {
    private func solid(_ value: UInt8, width: Int = 44, height: Int = 36) -> VideoFrameQuantizer.LumaImage {
        VideoFrameQuantizer.LumaImage(width: width, height: height,
                                      pixels: [UInt8](repeating: value, count: width * height))!
    }

    private func manual(_ mode: VideoFrameQuantizer.Mode = .threshold,
                        fit: VideoFrameQuantizer.Fit = .fill) -> VideoFrameQuantizer.Settings {
        VideoFrameQuantizer.Settings(fit: fit, mode: mode, threshold: 0.5, autoThreshold: false)
    }

    func testRejectsMismatchedPixelCount() {
        XCTAssertNil(VideoFrameQuantizer.LumaImage(width: 4, height: 4, pixels: [0, 0, 0]))
    }

    func testWhiteLightsEveryLedAndBlackNone() {
        XCTAssertEqual(VideoFrameQuantizer.frame(from: solid(255), settings: manual()).litCount,
                       MatrixGeometry.ledCount)
        XCTAssertEqual(VideoFrameQuantizer.frame(from: solid(0), settings: manual()).litCount, 0)
    }

    func testInvertFlipsEveryCoveredLed() {
        var settings = manual()
        settings.invert = true
        XCTAssertEqual(VideoFrameQuantizer.frame(from: solid(0), settings: settings).litCount,
                       MatrixGeometry.ledCount)
    }

    func testFitLeavesLetterboxBarsOffEvenWhenInverted() {
        // Very wide picture: with .fit it covers only a band in the middle rows.
        var settings = manual(fit: .fit)
        settings.invert = true
        let wide = solid(0, width: 220, height: 20)
        let cells = VideoFrameQuantizer.cellLuminance(of: wide, fit: .fit, mirror: false)
        XCTAssertNil(cells[0], "top row is outside the picture")
        XCTAssertNotNil(cells[9 * MatrixGeometry.cols + 11], "centre is inside the picture")

        let frame = VideoFrameQuantizer.frame(from: wide, settings: settings)
        XCTAssertGreaterThan(frame.litCount, 0)
        XCTAssertLessThan(frame.litCount, MatrixGeometry.ledCount)
        XCTAssertFalse(frame[MatrixGeometry.ledIndex(x: 11, y: 0)!])
        XCTAssertTrue(frame[MatrixGeometry.ledIndex(x: 11, y: 9)!])
    }

    func testFillAndStretchCoverEveryCell() {
        let tall = solid(128, width: 20, height: 200)
        for fit in [VideoFrameQuantizer.Fit.fill, .stretch] {
            let cells = VideoFrameQuantizer.cellLuminance(of: tall, fit: fit, mirror: false)
            XCTAssertFalse(cells.contains { $0 == nil }, "\(fit) must cover the grid")
        }
    }

    func testMirrorSwapsLeftAndRight() {
        // Left half white, right half black.
        let width = 44, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<(width / 2) { pixels[y * width + x] = 255 } }
        let image = VideoFrameQuantizer.LumaImage(width: width, height: height, pixels: pixels)!

        let left = MatrixGeometry.ledIndex(x: 2, y: 9)!
        let right = MatrixGeometry.ledIndex(x: 19, y: 9)!

        let plain = VideoFrameQuantizer.frame(from: image, settings: manual(fit: .stretch))
        XCTAssertTrue(plain[left])
        XCTAssertFalse(plain[right])

        var mirrored = manual(fit: .stretch)
        mirrored.mirror = true
        let flipped = VideoFrameQuantizer.frame(from: image, settings: mirrored)
        XCTAssertFalse(flipped[left])
        XCTAssertTrue(flipped[right])
    }

    func testAutoThresholdSeparatesAFrameThatManualThresholdWouldNot() {
        // A dim picture: everything is under 0.5, but the left half is brighter.
        let width = 44, height = 36
        var pixels = [UInt8](repeating: 20, count: width * height)
        for y in 0..<height { for x in 0..<(width / 2) { pixels[y * width + x] = 90 } }
        let image = VideoFrameQuantizer.LumaImage(width: width, height: height, pixels: pixels)!

        XCTAssertEqual(VideoFrameQuantizer.frame(from: image, settings: manual(fit: .stretch)).litCount, 0)

        var auto = manual(fit: .stretch)
        auto.autoThreshold = true
        let frame = VideoFrameQuantizer.frame(from: image, settings: auto)
        XCTAssertTrue(frame[MatrixGeometry.ledIndex(x: 2, y: 9)!])
        XCTAssertFalse(frame[MatrixGeometry.ledIndex(x: 19, y: 9)!])
    }

    func testAutoThresholdOnUniformFramesFallsBackToMidpoint() {
        var auto = manual()
        auto.autoThreshold = true
        XCTAssertEqual(VideoFrameQuantizer.frame(from: solid(255), settings: auto).litCount,
                       MatrixGeometry.ledCount, "a white frame must not go blank")
        XCTAssertEqual(VideoFrameQuantizer.frame(from: solid(0), settings: auto).litCount, 0)
        auto.mode = .dither
        XCTAssertEqual(VideoFrameQuantizer.frame(from: solid(0), settings: auto).litCount, 0,
                       "a black frame must not dither into half-lit speckle")
    }

    func testTopOfTheImageLandsOnTheTopOfTheBoard() {
        let width = 44, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<(height / 4) { for x in 0..<width { pixels[y * width + x] = 255 } }
        let image = VideoFrameQuantizer.LumaImage(width: width, height: height, pixels: pixels)!

        let frame = VideoFrameQuantizer.frame(from: image, settings: manual(fit: .stretch))
        XCTAssertTrue(frame[MatrixGeometry.ledIndex(x: 11, y: 0)!])
        XCTAssertFalse(frame[MatrixGeometry.ledIndex(x: 11, y: 17)!])
    }

    func testFillCropsTheSidesOfAWideImage() {
        // 88×18 with the left fifth white. Filling the 22×18 grid crops the
        // sides away; stretching keeps the white edge.
        let width = 88, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<18 { pixels[y * width + x] = 255 } }
        let image = VideoFrameQuantizer.LumaImage(width: width, height: height, pixels: pixels)!
        let led = MatrixGeometry.ledIndex(x: 3, y: 9)!

        XCTAssertFalse(VideoFrameQuantizer.frame(from: image, settings: manual(fit: .fill))[led])
        XCTAssertTrue(VideoFrameQuantizer.frame(from: image, settings: manual(fit: .stretch))[led])
    }

    func testDitherOnMidGreyLightsRoughlyHalf() {
        let frame = VideoFrameQuantizer.frame(from: solid(128), settings: manual(.dither))
        let ratio = Double(frame.litCount) / Double(MatrixGeometry.ledCount)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.1)
    }

    func testDitherIsDeterministicForTheSameInput() {
        let a = VideoFrameQuantizer.frame(from: solid(100), settings: manual(.dither))
        let b = VideoFrameQuantizer.frame(from: solid(100), settings: manual(.dither))
        XCTAssertEqual(a, b)
    }
}
