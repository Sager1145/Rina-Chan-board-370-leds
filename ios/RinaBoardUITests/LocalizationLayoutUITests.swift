import XCTest

/// Navigation and screenshot matrix. Screenshots require visual review for glyph
/// clipping: accessibility labels alone do not reveal rendered truncation.
@MainActor
final class LocalizationLayoutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSimplifiedChineseLayout() { inspect(language: "zh-Hans", locale: "zh_CN", tabs: ["表情显示", "文字滚动", "口型识别", "演出", "设定"]) }
    func testTraditionalChineseLayout() { inspect(language: "zh-Hant", locale: "zh_TW", tabs: ["表情顯示", "文字滾動", "嘴型辨識", "演出", "設定"]) }
    func testJapaneseLayout() { inspect(language: "ja", locale: "ja_JP", tabs: ["表情表示", "文字スクロール", "口形認識", "ライブ", "設定"]) }
    func testEnglishLayout() { inspect(language: "en", locale: "en_US", tabs: ["Expressions", "Text", "Speak", "Live", "Settings"]) }

    private func inspect(language: String, locale: String, tabs: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-initialTab", "control", "-disableStarAnimation", "YES"]
        app.launch()
        defer { app.terminate() }
        let first = app.buttons[tabs[0]].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        for label in ["页面加载中", "页面加载完成", "Page loading", "Page loaded", "ページを読み込み中", "ページの読み込み完了", "頁面載入中", "頁面載入完成"] {
            let overlay = app.descendants(matching: .any)[label].firstMatch
            if overlay.exists { _ = overlay.waitForNonExistence(timeout: 15) }
        }
        for (index, title) in tabs.enumerated() {
            let tab = app.buttons[title].firstMatch
            XCTAssertTrue(tab.exists, "Missing translated destination: \(language) \(title)")
            XCTAssertTrue(tab.isHittable, "Unreachable destination: \(language) \(title)")
            tab.tap()
            capture(app, name: "\(language)-tab-\(index)")
            if index < 4 {
                scrollContent(app)
                scrollContent(app)
                capture(app, name: "\(language)-tab-\(index)-scrolled")
            }
        }
        // Both stack and expanded sidebar layouts use these stable routes.
        for category in ["connection", "addBoard", "groups", "board", "network", "application", "debug", "about"] {
            let row = app.buttons["settings.category.\(category)"].firstMatch
            for _ in 0..<5 {
                if row.exists && row.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(row.isHittable, "Settings route unavailable: \(category)")
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.detail.\(category)"].firstMatch.waitForExistence(timeout: 5))
            capture(app, name: "\(language)-settings-\(category)")
            if category == "network" {
                let detail = app.descendants(matching: .any)["settings.detail.network"].firstMatch
                detail.swipeUp()
                detail.swipeUp()
                capture(app, name: "\(language)-settings-network-scrolled")
            }
            if !app.descendants(matching: .any)["settings.sidebar"].exists {
                // Duo places native navigation controls beside the content;
                // the stack's edge-pop gesture works in every language.
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
                XCTAssertTrue(app.buttons["settings.category.connection"].firstMatch.waitForExistence(timeout: 5))
            }
        }
    }

    private func scrollContent(_ app: XCUIApplication) {
        let pane = app.collectionViews["board.workspace.tabControls"].firstMatch
        if pane.exists { pane.swipeUp() } else { app.swipeUp() }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        // Retain every display: Duo's main screen can be the inactive outer
        // display, while its application-cropped inner image can be black.
        let images = XCUIScreen.screens.map { $0.screenshot() }
        for (index, image) in images.enumerated() {
            let screenshot = XCTAttachment(screenshot: image)
            screenshot.name = name + "-display-\(index)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        let description = app.debugDescription
        let tree = XCTAttachment(string: description)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
        // Keep review artifacts available even when Xcode's result-bundle
        // finalization stalls on a preview simulator runtime.
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalizationScreenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, image) in images.enumerated() {
                try image.pngRepresentation.write(to: directory.appendingPathComponent(name + "-display-\(index).png"))
            }
            try description.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Could not save layout review artifacts: \(error)")
        }
    }
}
