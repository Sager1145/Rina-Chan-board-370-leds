import XCTest

#if targetEnvironment(simulator)
/// Requires five local tools/rinalink_board_emulator.py processes on ports
/// 16370...16374, with board IDs EMU-127.0.0.1...EMU-127.0.0.5.
/// Uses the normal TCP handshake and actual save UI; never submits a save.
@MainActor
final class SaveDestinationsUITests: XCTestCase {
    override func record(_ issue: XCTIssue) {
        let app = XCUIApplication()
        if app.state == .runningForeground {
            attachHierarchy(app, name: "Save destination failure accessibility hierarchy")
        }
        super.record(issue)
    }

    func testFirstSaveHasConnectedDestinationsAndFreshNamingSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-initialTab", "text", "-disableStarAnimation", "YES",
            "-seedTestGroups", "YES", "-connectTestBoards", "YES",
            "-testBoardPort", "16370", "-testGroupName", "Test · 5 boards",
            "-playTestGroup", "NO"
        ]
        app.launch()
        defer { app.terminate() }

        // Readiness comes from the connected production sessions, before the
        // first Save tap. Reopening the sheet must not be needed to hydrate it.
        let previews = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "group.preview.member."))
        let connected = NSPredicate { _, _ in
            let members = previews.allElementsBoundByIndex
            return members.count == 5 && members.allSatisfy {
                !$0.label.contains("Offline") && !$0.label.contains("离线")
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: connected, object: nil)],
                                     timeout: 40), .completed,
                       "All five local TCP emulators must complete their real handshakes")
        for label in ["Page loading", "Page loaded", "页面加载中", "页面加载完成"] {
            let overlay = app.descendants(matching: .any)[label].firstMatch
            if overlay.exists { XCTAssertTrue(overlay.waitForNonExistence(timeout: 15)) }
        }
        let controlTab = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "tab.control", "表情显示")).firstMatch
        XCTAssertTrue(controlTab.waitForExistence(timeout: 10))
        controlTab.tap()

        // CommandChip exposes both its symbol and text in the button label.
        let save = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "保存", "保存、保存")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let all = app.switches["faces.saveTargets.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        attachHierarchy(app, name: "First save destination picker accessibility hierarchy")
        let destinations = (1...5).map { app.switches["faces.saveTargets.board:EMU-127.0.0.\($0)"] }
        XCTAssertEqual(app.switches.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@",
            "faces.saveTargets.", "faces.saveTargets.all")).count, 5,
            "The very first presentation must contain every connected board")
        for destination in destinations { XCTAssertTrue(destination.exists) }
        assertSelected(destinations, indices: [0])
        assertCount(app, selected: 1)
        XCTAssertEqual(all.value as? String, "0")

        try tapToggle(all, to: "1")
        assertSelected(destinations, indices: Set(0..<5))
        assertCount(app, selected: 5)
        XCTAssertEqual(all.value as? String, "1")
        try tapToggle(all, to: "0")
        assertSelected(destinations, indices: [])
        assertCount(app, selected: 0)
        XCTAssertFalse(app.buttons["继续"].isEnabled)

        try tapToggle(destinations[1], to: "1")
        try tapToggle(destinations[3], to: "1")
        assertSelected(destinations, indices: [1, 3])
        assertCount(app, selected: 2)
        XCTAssertEqual(all.value as? String, "0")
        app.buttons["继续"].tap()

        let naming = app.navigationBars["保存到 2 个面板"]
        XCTAssertTrue(naming.waitForExistence(timeout: 10),
                      "Continue must present a fresh naming payload with the selected count")
        XCTAssertTrue(app.textFields.firstMatch.exists)
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(naming.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["保存结果"].exists)

        // Cancelling the naming form must discard that presentation's two
        // targets; a new save starts from the current board again.
        save.tap()
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        assertSelected(destinations, indices: [0])
        assertCount(app, selected: 1)
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(all.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["保存结果"].exists)
    }

    private func attachHierarchy(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapToggle(_ row: XCUIElement, to value: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        // SwiftUI can expose the labelled row as a Switch with the actual
        // UISwitch beneath it. Only use that child when the live AX tree has it.
        let child = row.switches.firstMatch
        let control = try XCTUnwrap(child.exists ? child : nil,
                                   "Expected a nested switch control: \(row.debugDescription)",
                                   file: file, line: line)
        control.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed,
                       "Toggle did not reach value \(value): \(row.identifier)", file: file, line: line)
    }

    private func assertSelected(_ destinations: [XCUIElement], indices: Set<Int>,
                                file: StaticString = #filePath, line: UInt = #line) {
        for (index, destination) in destinations.enumerated() {
            XCTAssertEqual(destination.value as? String, indices.contains(index) ? "1" : "0",
                           "Unexpected destination selection: \(destination.identifier)", file: file, line: line)
        }
    }

    private func assertCount(_ app: XCUIApplication, selected: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["已选择 \(selected) / 5 个面板。稍后连接的面板不会自动加入。"].exists,
                      "Picker count must reflect the real destination selection", file: file, line: line)
    }
}
#endif
