import XCTest

final class RinaBoardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testLegacyControlCenterAndFaceLibraryAreReachable() throws {
        launch(initialTab: "control")

        let clearFrame = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "清空"))
            .firstMatch
        XCTAssertTrue(scrollToElement(clearFrame), "The restored Control commands were not reachable")

        let accessory = app.buttons["面板控制"]
        if accessory.waitForExistence(timeout: 3) {
            accessory.tap()
        } else {
            // iOS 17–25 exposes the same control center from Settings rather
            // than through the iOS 26 tab-bar accessory.
            app.tabBars.buttons["设置"].tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
            let controlCenter = app.buttons["面板控制中心"]
            XCTAssertTrue(scrollToElement(controlCenter))
            controlCenter.tap()
        }

        XCTAssertTrue(app.navigationBars["面板控制"].waitForExistence(timeout: 4))
        let manageFaces = app.buttons["管理表情"]
        XCTAssertTrue(scrollToElement(manageFaces), "The face library entry was not reachable")
        manageFaces.tap()
        XCTAssertTrue(app.navigationBars["表情库"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["默认表情"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["我的表情"].waitForExistence(timeout: 2))
    }

    func testDebugWorkspacesAreReachable() throws {
        launch(initialTab: "settings")
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 6))

        let debugTools = app.buttons["调试工具"]
        XCTAssertTrue(scrollToElement(debugTools))
        debugTools.tap()
        XCTAssertTrue(app.navigationBars["调试"].waitForExistence(timeout: 3))

        let workspace = app.segmentedControls["debug.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 2))
        let destinations = [
            ("概览", "复制诊断摘要"),
            ("日志", "开始接收固件日志"),
            ("测试", "测试图案"),
            ("原始数据", "原始命令控制台")
        ]
        for (segment, expectedContent) in destinations {
            workspace.buttons[segment].tap()
            XCTAssertTrue(app.buttons[expectedContent].waitForExistence(timeout: 2),
                          "Debug workspace \(segment) did not reveal its content")
        }
    }

    private func launch(initialTab: String) {
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-initialTab", initialTab
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 8),
                      "The boot animation did not reveal the app tabs")
    }

    @discardableResult
    private func scrollToElement(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        _ = element.waitForExistence(timeout: 1)
        for _ in 0..<attempts {
            if isSafelyHittable(element) { return true }
            let targetIsAboveViewport = element.exists && element.frame.midY < 150
            shortSwipe(up: !targetIsAboveViewport)
        }
        let visible = isSafelyHittable(element)
        if !visible {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Unreachable control"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return visible
    }

    private func isSafelyHittable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let isNestedPresentation = app.sheets.firstMatch.exists || app.navigationBars.count > 1
        let bottom = isNestedPresentation ? app.frame.maxY - 60 : 650
        return (150...bottom).contains(element.frame.midY)
    }

    private func shortSwipe(up: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.68 : 0.36))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.44 : 0.60))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

}
