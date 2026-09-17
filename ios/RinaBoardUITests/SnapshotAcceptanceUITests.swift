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
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-initialTab", tab, "-disableStarAnimation", "YES"]
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

    /// No accessibility hook exposes the boot loader overlay's state, so we
    /// wait for the tab bar to become hittable and give the outro a further
    /// margin to finish before capturing the reference frame.
    func testRinaBackgroundStarReferenceFrame() {
        launch("control")
        let tabBar = app.tabBars.firstMatch
        var isHittable = false
        for _ in 0..<20 {
            if tabBar.isHittable { isHittable = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(isHittable, "Tab bar should become hittable once the boot loader clears")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "RinaBackgroundStarReferenceFrame"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOfflineSaveRemainsAvailable() {
        launch("control")
        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "保存")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "Offline editing must offer local save without requiring a panel")
    }

    func testLocalLibraryLocationRemainsAvailableOffline() {
        launch("control")
        // "管理表情" was removed from BoardControlCenterView in 6658c34
        // (2026-09-12); the face library is now reached from the Control
        // tab's own「保存列表」chip instead of the control center.
        XCTAssertTrue(FaceLibraryUITestPath.openFaceLibrary(in: app),
                      "The face library was not reachable from the Control tab")
        XCTAssertTrue(app.staticTexts["本机"].firstMatch.waitForExistence(timeout: 3),
                      "The local ('本机') library location must be shown when no board is connected")
        // `FaceLibraryView` puts the thumbnail, name and caption inside a
        // `Button`'s label, so SwiftUI collapses that subtree into a single
        // element carrying the button trait — "预设" is a fragment of the
        // button's accessibility label, never a standalone `staticText`.
        let presetRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "预设")).firstMatch
        XCTAssertTrue(presetRow.waitForExistence(timeout: 3),
                      "Bundled preset faces must be available offline")
        XCTAssertFalse(app.staticTexts["暂无"].exists,
                       "Library must provide its own local content even without a connected board")
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
        // The standalone "发送到面板" button was deliberately removed from the
        // tab-bar accessory in 9d9cdb1 (2026-09-12, BoardControlCenterAccessory.swift):
        // sending the editor's draft now lives on the Control tab itself. The
        // loop above already leaves the Control tab ("表情显示") selected, so
        // the offline send gate is checked on its own "发送" chip
        // (ControlView.swift), which stays disabled without a connected
        // board. `CommandChip` combines its icon and title into one
        // accessibility label, which SwiftUI then doubles (e.g. "发送、发送"),
        // hence `CONTAINS` rather than an exact label match.
        let send = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "发送")).firstMatch
        reach(send)
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Sending must stay gated while offline")
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
        // The boot replay is not a UIKit alert — it is `BootLoaderOverlay`,
        // a full-screen ZStack overlay (RootTabView.swift) marked
        // `.accessibilityAddTraits(.isModal)` (BootLoaderOverlay.swift),
        // which older toolchains surfaced as an alert but this one does not.
        // Wait on the overlay's own label instead, which flips from "页面
        // 加载中" to "页面加载完成" when its outro starts
        // (BootLoaderOverlay.swift).
        let bootOverlay = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label == %@", "页面加载中", "页面加载完成"))
            .firstMatch
        XCTAssertTrue(bootOverlay.waitForExistence(timeout: 3))
        XCTAssertTrue(bootOverlay.waitForNonExistence(timeout: 12))
        XCTAssertTrue(app.navigationBars["调试"].exists)
    }
}
