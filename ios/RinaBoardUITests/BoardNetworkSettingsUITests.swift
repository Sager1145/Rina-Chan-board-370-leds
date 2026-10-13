import XCTest

final class BoardNetworkSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBoardNetworkPageOffersScanWithoutPersonalHotspotSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-initialTab", "settings", "-disableStarAnimation", "YES"]
        app.launch()
        // The boot overlay is modal and appears as an XCTest alert. Wait for
        // its transition before tapping the settings row beneath it.
        let bootOverlay = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label == %@", "页面加载中", "页面加载完成"))
            .firstMatch
        XCTAssertTrue(bootOverlay.waitForNonExistence(timeout: 20))
        let networkPage = app.buttons["settings.category.network"]
        XCTAssertTrue(networkPage.waitForExistence(timeout: 20))
        networkPage.tap()
        XCTAssertTrue(app.buttons["network.scan"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["network.mode"].exists)
        for _ in 0..<5 {
            XCTAssertFalse(app.staticTexts["iPhone 热点"].exists)
            XCTAssertFalse(app.buttons["发送到板子并连接"].exists)
            if app.staticTexts["热点名称与密码"].isHittable { return }
            app.swipeUp()
        }
        XCTFail("The board's own hotspot settings were not reached")
    }
}
