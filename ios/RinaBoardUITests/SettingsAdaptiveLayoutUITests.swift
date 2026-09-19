import XCTest

/// Settings switches between a stack and two columns as its width changes. The
/// page, the unsent input and the Debug workspace must come through each
/// switch unchanged.
///
/// Needs a device whose two orientations fall on opposite sides of
/// `SettingsLayoutPolicy` — iPad mini: 744 pt portrait (stack) and 1133 pt
/// landscape (two columns). Elsewhere it still checks that rotating keeps the
/// state, without asserting a layout change.
final class SettingsAdaptiveLayoutUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPhone runs portrait only; there is no width change to cross.")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(initialTab: String) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-initialTab", initialTab]
        app.launch()
        for label in ["页面加载中", "页面加载完成"] {
            let overlay = app.descendants(matching: .any)[label]
            if overlay.exists { _ = overlay.waitForNonExistence(timeout: 15) }
        }
    }

    private var isSplit: Bool { app.descendants(matching: .any)["settings.sidebar"].exists }

    private func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        // Let the rotation and any layout switch settle.
        _ = app.wait(for: .runningForeground, timeout: 1)
        Thread.sleep(forTimeInterval: 1.5)
    }

    func testDebugTerminalSurvivesLayoutChanges() {
        launch(initialTab: "debug")
        let workspace = app.segmentedControls["debug.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.buttons["终端"].tap()
        let input = app.textFields["debug.monitor.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("PING")
        let typed = input.value as? String
        XCTAssertNotNil(typed)

        let startedSplit = isSplit
        var sawOtherLayout = false
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            rotate(orientation)
            if isSplit != startedSplit { sawOtherLayout = true }
            XCTAssertTrue(workspace.waitForExistence(timeout: 3), "left Debug after rotating to \(orientation.rawValue)")
            XCTAssertTrue(workspace.buttons["终端"].isSelected, "Debug workspace reset after rotating")
            XCTAssertEqual(input.value as? String, typed, "terminal input lost after rotating")
        }
        if min(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) < 770 {
            XCTAssertTrue(sawOtherLayout, "iPad mini portrait/landscape should cross the split threshold")
        }
    }

    func testConnectionFilterAndPageSurviveLayoutChanges() {
        launch(initialTab: "add-board")
        let filter = app.textFields["bluetooth.deviceFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.tap()
        filter.typeText("rina-draft")
        app.keyboards.buttons.matching(NSPredicate(format: "label IN {'Return', 'return', '换行', 'Done', '完成'}")).firstMatch.tapIfExists()

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            rotate(orientation)
            // The split layout shows its pages without a navigation bar.
            XCTAssertTrue(app.descendants(matching: .any)["settings.detail.addBoard"].waitForExistence(timeout: 3),
                          "left Add Board after rotating to \(orientation.rawValue)")
            XCTAssertEqual(filter.value as? String, "rina-draft", "Bluetooth filter lost after rotating")
        }
    }

    func testCategoryListStaysAListAcrossLayoutChanges() {
        launch(initialTab: "settings")
        XCTAssertTrue(app.buttons["settings.category.application"].waitForExistence(timeout: 10))
        let startedSplit = isSplit
        rotate(.landscapeLeft)
        rotate(.portrait)
        // Back where it started: no page was pushed by the round trip.
        XCTAssertEqual(isSplit, startedSplit)
        if !startedSplit {
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["settings.category.application"].isHittable)
        }
    }
}

private extension XCUIElement {
    func tapIfExists() { if exists { tap() } }
}
