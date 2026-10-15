import XCTest
import UIKit

@MainActor
final class BootAnimationRotationUITests: XCTestCase {
    func testLoaderCoversWindowAcrossRotations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-initialTab", "control", "-bootMinimumDisplay", "45",
                               "-disableStarAnimation", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let loader = app.descendants(matching: .any)["boot.loader"].firstMatch
        XCTAssertTrue(loader.waitForExistence(timeout: 10))
        let initialWindow = app.windows.firstMatch.frame
        // Duo's closed outer display intentionally remains portrait.
        let canRotate = UIDevice.current.userInterfaceIdiom == .pad
            || min(initialWindow.width, initialWindow.height) >= 600
        var orientations: [UIDeviceOrientation] = [.landscapeLeft, .landscapeRight]
        // This Duo runtime leaves the window landscape for an upside-down
        // sensor request. iPad supports that additional interface direction.
        if UIDevice.current.userInterfaceIdiom == .pad { orientations.append(.portraitUpsideDown) }
        orientations.append(.portrait)
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let coversWindow = NSPredicate { _, _ in
                guard loader.exists else { return false }
                let window = app.windows.firstMatch.frame
                let frame = loader.frame
                let expectsLandscape = canRotate && (orientation == .landscapeLeft || orientation == .landscapeRight)
                guard (window.width > window.height) == expectsLandscape else { return false }
                return abs(frame.width - window.width) < 2 && abs(frame.height - window.height) < 2
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: coversWindow, object: app)],
                                         timeout: 5), .completed,
                           "orientation=\(orientation.rawValue), window=\(app.windows.firstMatch.frame), loader=\(loader.frame)")
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "Boot-\(orientation.rawValue)"
            capture.lifetime = .keepAlways
            add(capture)
        }
    }

    func testDebugCanExtendAndReplayLoader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-initialTab", "debug", "-AppleLanguages", "(zh-Hans)",
                               "-disableStarAnimation", "YES"]
        app.launch()
        defer { app.terminate() }
        let loader = app.descendants(matching: .any)["boot.loader"].firstMatch
        XCTAssertTrue(loader.waitForNonExistence(timeout: 15))
        let workspace = app.segmentedControls["debug.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.buttons["测试"].tap()
        let tools = app.buttons["App 工具"]
        for _ in 0..<6 {
            if tools.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35)))
        }
        XCTAssertTrue(tools.isHittable)
        tools.tap()
        let slider = app.sliders["debug.boot.minimumDisplay"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.25)
        let replay = app.buttons["debug.boot.replay"]
        for _ in 0..<4 {
            if replay.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        }
        replay.tap()
        XCTAssertTrue(loader.waitForExistence(timeout: 3))
        XCTAssertFalse(loader.waitForNonExistence(timeout: 5), "The Debug option must extend playback")
        XCTAssertTrue(loader.waitForNonExistence(timeout: 25))
        slider.adjust(toNormalizedSliderPosition: 0)
    }

}
