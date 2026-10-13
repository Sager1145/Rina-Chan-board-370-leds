import XCTest

/// Regression: Duo used the phone list instead of its expanded workspace.
final class DuoWorkspaceUITests: XCTestCase {
    @MainActor
    func testLandscapeKeepsTheSelectedTabAndExposesBothControlPanes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-initialTab", "text", "-disableStarAnimation", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let window = app.windows.firstMatch.frame
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone && min(window.width, window.height) >= 600,
                          "Requires Duo's open inner display; set Open in Device Hub")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: app)],
                                     timeout: 10), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["board.workspace.controlCenter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["board.workspace.tabControls"].exists)
        let preview = app.otherElements["board.workspace.preview"].firstMatch
        let boardControls = app.collectionViews["board.workspace.controlCenter"]
        let tabControls = app.collectionViews["board.workspace.tabControls"]
        XCTAssertTrue(preview.exists)
        XCTAssertLessThanOrEqual(preview.frame.maxX, tabControls.frame.minX)
        XCTAssertLessThanOrEqual(boardControls.frame.maxX, tabControls.frame.minX)
        XCTAssertLessThanOrEqual(preview.frame.maxY, boardControls.frame.minY)
        XCTAssertTrue(app.textViews["滚动文字内容"].exists, "The selected Text tab must survive rotation")
    }
    @MainActor
    func testSettingsColumnsShareTheActualPageWidth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-initialTab", "debug", "-disableStarAnimation", "YES"]
        app.launch()
        let window = app.windows.firstMatch.frame
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone && min(window.width, window.height) >= 600,
                          "Requires Duo's open inner display")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let sidebar = app.collectionViews["settings.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        let detail = app.otherElements["settings.detail.debug"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let sidebarCard = sidebar.cells.firstMatch
        let detailCard = detail.collectionViews.firstMatch.cells.firstMatch
        XCTAssertTrue(sidebarCard.exists)
        XCTAssertTrue(detailCard.exists)
        // The detail's container also includes the vertical system bar;
        // compare the actual content cards, not that container's full frame.
        XCTAssertEqual(sidebarCard.frame.width, detailCard.frame.width, accuracy: 2)
        XCTAssertLessThanOrEqual(sidebar.frame.maxX, detail.frame.minX + 2)
    }

    @MainActor
    func testFoldedStatusOpensControlCenterBesideTheSidebar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-initialTab", "control", "-disableStarAnimation", "YES"]
        app.launch()
        let status = app.buttons["controlCenter.statusButton"]
        try XCTSkipUnless(status.waitForExistence(timeout: 10), "Requires Duo's closed outer display")
        // The startup announcement briefly covers toolbar controls.
        for label in ["Page loading", "Page loaded", "页面加载中", "页面加载完成"] {
            let overlay = app.descendants(matching: .any)[label].firstMatch
            if overlay.exists { XCTAssertTrue(overlay.waitForNonExistence(timeout: 15)) }
        }
        status.tap()
        let popup = app.otherElements["controlCenter.popup"].firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(popup.frame.maxX, status.frame.minX)
    }

    @MainActor
    func testExpandedControlsAndPanesSurviveRepeatedRotations() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-initialTab", "text", "-disableStarAnimation", "YES"]
        app.launch()
        let frame = app.windows.firstMatch.frame
        try XCTSkipUnless(min(frame.width, frame.height) >= 600, "Requires Duo's open display")
        defer { XCUIDevice.shared.orientation = .portrait }
        for label in ["Page loading", "Page loaded", "页面加载中", "页面加载完成"] {
            let overlay = app.descendants(matching: .any)[label].firstMatch
            if overlay.exists { XCTAssertTrue(overlay.waitForNonExistence(timeout: 15)) }
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            // Duo's AX window uses display coordinates; check the actual
            // page and controls after the device's rotation action settles.
            XCTAssertTrue(app.collectionViews["board.workspace.tabControls"].exists)
            XCTAssertTrue(app.textViews["滚动文字内容"].exists)
            for id in ["mode", "previous", "next", "color"] {
                let control = app.descendants(matching: .any)["controlCenter.toolbar." + id].firstMatch
                XCTAssertTrue(control.exists)
                XCTAssertEqual(control.frame.width, control.frame.height, accuracy: 4,
                               "Toolbar control must remain circular: " + id)
            }
        }
        let status = app.buttons["controlCenter.statusButton"]
        XCTAssertTrue(status.exists)
        status.tap()
        let popup = app.otherElements["controlCenter.popup"].firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 10))
        if status.frame.midY < app.windows.firstMatch.frame.height / 4 {
            XCTAssertGreaterThanOrEqual(popup.frame.minY, status.frame.maxY)
        } else {
            XCTAssertLessThanOrEqual(popup.frame.maxX, status.frame.minX)
        }
    }

}
