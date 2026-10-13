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
        defer { XCUIDevice.shared.orientation = .portrait }
        let sidebar = app.collectionViews["settings.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        let detail = app.otherElements["settings.detail.debug"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let sidebarCard = sidebar.cells.firstMatch
            let detailCard = detail.collectionViews.firstMatch.cells.firstMatch
            XCTAssertTrue(sidebarCard.exists)
            XCTAssertTrue(detailCard.exists)
            // Compare visible content rather than the container extending
            // beneath the system bar, on either side of the display.
            XCTAssertEqual(sidebarCard.frame.width, detailCard.frame.width, accuracy: 2)
            XCTAssertLessThanOrEqual(sidebar.frame.maxX, detail.frame.minX + 2)
        }
    }

    @MainActor
    func testFoldedStatusOpensControlCenterBesideTheSidebar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-initialTab", "control", "-disableStarAnimation", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let status = app.buttons["controlCenter.statusButton"]
        try XCTSkipUnless(status.waitForExistence(timeout: 10), "Requires Duo's closed outer display")
        // The startup announcement briefly covers toolbar controls.
        for label in ["Page loading", "Page loaded", "页面加载中", "页面加载完成"] {
            let overlay = app.descendants(matching: .any)[label].firstMatch
            if overlay.exists { XCTAssertTrue(overlay.waitForNonExistence(timeout: 15)) }
        }
        assertSeparateToolbarControls(app, ids: ["controlCenter.toolbar.mode", "controlCenter.toolbar.color", "controlCenter.statusButton"])
        status.tap()
        let popup = app.otherElements["controlCenter.popup"].firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 10))
        if status.frame.midX < app.windows.firstMatch.frame.width / 2 {
            XCTAssertGreaterThanOrEqual(popup.frame.minX, status.frame.maxX)
        } else {
            XCTAssertLessThanOrEqual(popup.frame.maxX, status.frame.minX)
        }
        XCTAssertGreaterThan(popup.frame.midY, app.windows.firstMatch.frame.midY, "Menu belongs to the bottom of the page")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        XCTAssertTrue(status.exists, "Folded mode must keep its portrait navbar")
    }

    @MainActor
    func testNativeToolbarColorMenuUpdatesItsSwatch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-initialTab", "control", "-disableStarAnimation", "YES"]
        app.launch()
        defer { app.terminate() }
        let color = app.descendants(matching: .any)["controlCenter.toolbar.color"].firstMatch
        XCTAssertTrue(color.waitForExistence(timeout: 10))
        for label in ["Page loading", "Page loaded", "页面加载中", "页面加载完成"] {
            let overlay = app.descendants(matching: .any)[label].firstMatch
            if overlay.exists { XCTAssertTrue(overlay.waitForNonExistence(timeout: 15)) }
        }
        let original = (color.value as? String)?.lowercased()
        let presetName = original == "#ff9547" ? "Riko Sakurauchi · Sakura pink" : "Chika Takami · Mikan orange"
        let expected = original == "#ff9547" ? "#ff9eac" : "#ff9547"
        color.tap()
        let group = app.buttons["Aqours"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let preset = app.buttons[presetName].firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        let changed = NSPredicate { _, _ in
            (color.value as? String)?.lowercased() == expected
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: color)], timeout: 5), .completed)
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
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown, .portrait] {
            XCUIDevice.shared.orientation = orientation
            // Duo's AX window uses display coordinates; check the actual
            // page and controls after the device's rotation action settles.
            XCTAssertTrue(app.collectionViews["board.workspace.tabControls"].exists)
            XCTAssertTrue(app.textViews["滚动文字内容"].exists)
            assertSeparateToolbarControls(app, ids: ["mode", "previous", "next", "color"].map { "controlCenter.toolbar." + $0 })
            XCTAssertFalse(app.buttons["controlCenter.statusButton"].exists)
            XCTAssertTrue(app.collectionViews["board.workspace.controlCenter"].exists)
        }
    }

    @MainActor
    private func assertSeparateToolbarControls(_ app: XCUIApplication, ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        var previous: CGRect?
        for id in ids {
            let control = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.exists, id, file: file, line: line)
            let frame = control.frame
            XCTAssertEqual(frame.width, 44, accuracy: 2, id, file: file, line: line)
            XCTAssertEqual(frame.height, 44, accuracy: 2, id, file: file, line: line)
            let nativeTab = app.tabBars.buttons.firstMatch
            // A horizontal tab's AX frame includes its title and is wider
            // than its icon. The vertical Duo sidebar supplies the native
            // circular button width we are matching.
            if nativeTab.exists, nativeTab.frame.width <= nativeTab.frame.height {
                XCTAssertEqual(frame.width, nativeTab.frame.width, accuracy: 2,
                               "Control width should match the native Duo tab button", file: file, line: line)
            }
            if let previous {
                let gap = abs(frame.midX - previous.midX) > abs(frame.midY - previous.midY)
                    ? abs(frame.midX - previous.midX) - (frame.width + previous.width) / 2
                    : abs(frame.midY - previous.midY) - (frame.height + previous.height) / 2
                XCTAssertGreaterThanOrEqual(gap, 5, "Controls need a visible gap: " + id, file: file, line: line)
            }
            previous = frame
        }
    }

}
