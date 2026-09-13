import XCTest

/// Acceptance assertions independent of whether a tab renders a navigation title.
@MainActor
final class SnapshotAcceptanceUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        for attachment in [XCTAttachment(screenshot: app.screenshot()), XCTAttachment(string: app.debugDescription)] {
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func launch(_ tab: String) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-initialTab", tab]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 10))
    }

    private func reach(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.midY < app.frame.maxY - 150 && element.frame.midY > 90 { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.67))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.37))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }

    func testOfflineSaveRemainsAvailable() {
        launch("control")
        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "保存")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "Offline editing must offer local save without requiring a panel")
    }

    func testLocalLibraryLocationRemainsAvailableOffline() {
        launch("control")
        app.buttons["面板控制"].tap()
        XCTAssertTrue(app.navigationBars["面板控制"].waitForExistence(timeout: 5))
        let manage = app.buttons["管理表情"]
        reach(manage)
        manage.tap()
        XCTAssertTrue(app.navigationBars["表情库"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "本机")).firstMatch.exists,
                      "Library must provide its local location even without a connected board")
    }

    func testTextDraftRestoresAfterBackgroundAndRelaunch() {
        launch("text")
        let editor = app.textViews["滚动文字内容"]
        reach(editor)
        editor.tap()
        let marker = "验收-a1-\(UUID().uuidString.prefix(6))-Hello-日本語-😀\n多行"
        editor.typeText(marker)
        let expected = editor.value as? String
        XCTAssertTrue(expected?.contains(marker) == true)
        XCUIDevice.shared.press(.home)
        app.activate()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 10))
        reach(editor)
        XCTAssertEqual(editor.value as? String, expected)
    }

    func testFiveTabsAndOfflineSendGate() {
        launch("control")
        for label in ["文字滚动", "嘴形识别", "演出", "设定", "表情显示"] {
            let tab = app.tabBars.buttons[label]
            tab.tap()
            XCTAssertTrue(tab.isSelected)
        }
        let send = app.buttons["发送到面板"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["表情显示"].isSelected)
    }

    func testDebugCancelDestructiveDialogAndReplayBootLocally() {
        launch("settings")
        let debug = app.buttons["调试工具"]
        reach(debug); debug.tap()
        XCTAssertTrue(app.navigationBars["调试"].waitForExistence(timeout: 5))
        app.segmentedControls["debug.workspace"].buttons["测试"].tap()
        let danger = app.buttons["危险操作"]
        reach(danger); danger.tap()
        let clear = app.buttons["清空用户表情"]
        reach(clear); clear.tap()
        XCTAssertTrue(app.alerts["清空用户表情"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["输入 CLEAR 以确认"].exists)
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 3))
        let appTools = app.buttons["App 工具"]
        // The group precedes the danger group. Scroll back toward the top if necessary.
        if appTools.exists && !appTools.isHittable { app.swipeDown() }
        reach(appTools); appTools.tap()
        let replay = app.buttons["重新播放启动动画"]
        reach(replay); replay.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 12))
        XCTAssertTrue(app.navigationBars["调试"].exists)
    }
}
