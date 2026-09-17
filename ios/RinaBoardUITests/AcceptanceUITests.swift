import XCTest
import UIKit

/// Run only in the dedicated RinaAcceptance simulators. No hardware output.
@MainActor
final class AcceptanceUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Page hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(tab: String = "control", language: String = "zh-Hans", extra: [String] = []) {
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-initialTab", tab] + extra
        app.launch()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            app.tabBars.firstMatch.exists || app.buttons["lightbulb.fill"].firstMatch.exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 10),
                      "Boot overlay must finish before interacting with the tabs")
    }

    private func reach(_ element: XCUIElement) -> Bool {
        for _ in 0..<16 {
            if element.exists && element.isHittable && element.frame.midY < app.frame.maxY - 110 && element.frame.midY > 85 { return true }
            let up = !(element.exists && element.frame.midY < 85)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: up ? 0.68 : 0.32))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: up ? 0.35 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return element.exists && element.isHittable
    }

    private func keepScreen(_ label: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func mainTab(at index: Int) -> XCUIElement {
        if !app.tabBars.firstMatch.exists {
            let identifiers = ["lightbulb.fill", "t.square.fill", "waveform", "music.note", "gearshape.fill"]
            return app.buttons[identifiers[index]].firstMatch
        }
        return app.tabBars.buttons.element(boundBy: index)
    }

    func testFiveTabsRemainReachableOfflineAndAfterBackgroundReturn() {
        launch()
        for tab in ["文字滚动", "嘴形识别", "演出", "设定", "表情显示"] {
            let item = app.tabBars.buttons[tab]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
            XCTAssertTrue(item.isSelected, "The \(tab) tab did not become selected")
        }
        let clearFrame = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "清空"))
            .firstMatch
        XCTAssertTrue(reach(clearFrame), "The restored Control commands were not reachable")
        XCUIDevice.shared.press(.home)
        app.activate()
        let control = app.tabBars.buttons["表情显示"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(control.isSelected)
    }

    func testTextDraftSurvivesTerminationWithMultilingualContent() {
        launch(tab: "text")
        let text = "验收-a1-English-日本語-😀\n第二行"
        let editor = app.textViews["滚动文字内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        editor.tap()
        editor.typeText(text)
        let expectedDraft = editor.value as? String
        XCTAssertTrue(expectedDraft?.contains(text) == true)
        // No keyboard dismissal needed: the draft is persisted on
        // `scenePhase != .active` (see RootTabView.swift), not on the
        // keyboard's own "完成" key. That key's automation type disagreed
        // between the legacy and modern accessibility attributes on this
        // Xcode beta (`UIAccessibilityElementKBKey`: legacy computed Button,
        // modern reported Key), so an `app.buttons` query could never match
        // it — dropping the tap keeps the test's real assertion (the draft
        // survives termination) intact without depending on that element.
        XCUIDevice.shared.press(.home)
        app.activate()
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, expectedDraft)
        XCTAssertFalse(app.buttons["发送并播放"].isEnabled)
    }

    func testSettingsRestoreLastTabAcrossLaunch() {
        launch(tab: "settings")
        let restore = app.switches["记住上次的标签页"]
        XCTAssertTrue(reach(restore))
        if restore.value as? String == "0" {
            let control = restore.switches.firstMatch
            if control.exists { control.tap() } else { restore.tap() }
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: restore)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        let performance = app.tabBars.buttons["演出"]
        performance.tap()
        XCTAssertTrue(performance.isSelected)
        XCUIDevice.shared.press(.home)
        app.activate()
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let restoredPerformance = app.tabBars.buttons["演出"]
        XCTAssertTrue(restoredPerformance.waitForExistence(timeout: 15))
        XCTAssertTrue(restoredPerformance.isSelected)
    }

    func testLocalizedTabsLargeTextLandscape() {
        for language in ["zh-Hant", "en", "ja"] {
            launch(language: language, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
            if app.tabBars.firstMatch.exists { XCTAssertEqual(app.tabBars.buttons.count, 5) }
            XCUIDevice.shared.orientation = .landscapeLeft
            for index in 0..<5 {
                let tab = mainTab(at: index)
                XCTAssertTrue(tab.isHittable)
                tab.tap()
                keepScreen("\(language)-AXXXL-tab-\(index)")
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(language)-AXXXL-landscape"
            shot.lifetime = .keepAlways
            add(shot)
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testAllTabsPortraitAndSupportedRotationScreenshots() {
        launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for index in 0..<5 {
                let tab = mainTab(at: index)
                XCTAssertTrue(tab.waitForExistence(timeout: 3))
                tab.tap()
                XCTAssertTrue(tab.isSelected)
                keepScreen("layout-\(orientation.rawValue)-tab-\(index)")
            }
        }
    }
}
