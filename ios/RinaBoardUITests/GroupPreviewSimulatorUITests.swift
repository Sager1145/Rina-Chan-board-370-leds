import XCTest

#if targetEnvironment(simulator)
@MainActor
final class GroupPreviewSimulatorUITests: XCTestCase {
    func testConnectedGroupsDragInBothDirectionsAndKeepLivePreview() throws {
        try checkGroups([("Test · 2 boards", 2, false),
                                      ("Test · 3 boards", 3, true),
                                      ("Test · 5 boards", 5, true),
                                      ("Test · 3 mirrors", 3, true)])
    }

    func testFiveBoardPreviewCanScrollAndDragBack() throws {
        try checkGroups([("Test · 5 boards", 5, true)])
    }

    func testFiveBoardPreviewCanDragInLandscape() throws {
        try checkGroups([("Test · 5 boards", 5, true)], landscape: true)
    }

    private func checkGroups(_ configurations: [(String, Int, Bool)], landscape: Bool = false) throws {
        continueAfterFailure = false
        for (name, count, paused) in configurations {
            let app = XCUIApplication()
            app.launchArguments = ["-initialTab", "text", "-disableStarAnimation", "YES",
                "-seedTestGroups", "YES", "-connectTestBoards", "YES", "-testBoardPort", "15370",
                "-testGroupName", name, "-playTestGroup", "YES", "-pauseTestGroup", paused ? "YES" : "NO"]
            app.launch()
            defer { app.terminate() }
            let cells = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "group.preview.member."))
            let ready = NSPredicate { _, _ in
                let previews = cells.allElementsBoundByIndex
                return previews.count == count && previews.allSatisfy {
                    $0.label.contains("Playing") || $0.label.contains("播放中") || $0.label.contains("Ready") || $0.label.contains("就绪")
                }
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 30), .completed,
                           "Requires the local TCP board emulator on port 15370: \(name)")
            for label in ["Page loading", "Page loaded", "页面加载中", "页面加载完成"] {
                let overlay = app.descendants(matching: .any)[label].firstMatch
                if overlay.exists { XCTAssertTrue(overlay.waitForNonExistence(timeout: 15)) }
            }
            if landscape {
                let rotated = NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    return frame.width > frame.height
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: app)], timeout: 10), .completed,
                               "Landscape regression requires Duo's inner display")
            }
            let initial = cells.allElementsBoundByIndex.sorted { $0.frame.midX < $1.frame.midX }
            XCTAssertEqual(initial.count, count)
            for cell in initial {
                XCTAssertGreaterThanOrEqual(cell.frame.width, 65)
                XCTAssertGreaterThan(cell.frame.height, 44)
                XCTAssertFalse(cell.label.contains("Offline"))
            }
            // Freeze identities before dragging: index-bound XCUIElements
            // resolve again after reorder and would otherwise change the expected order.
            let initialIDs = initial.map(\.identifier)
            let firstID = initialIDs[0]
            let lastID = initialIDs[count - 1]
            let scroller = app.scrollViews["group.preview.scroll"].firstMatch
            if scroller.exists {
                let last = app.descendants(matching: .any)[lastID].firstMatch
                let before = last.frame.midX
                shortSwipe(scroller, left: true)
                XCTAssertLessThan(last.frame.midX, before - 5, "A short swipe must scroll the narrow preview")
                shortSwipe(scroller, left: false)
            }
            assertLitPreview(cells)
            if name.contains("mirrors") {
                let values = cells.allElementsBoundByIndex.compactMap { $0.value as? String }
                XCTAssertEqual(Set(values).count, 1, "Mirror members must display the same held LED frame")
            }
            attach(app, "\(name)-before")
            drag(app, source: firstID, target: lastID)
            waitForOrder(cells, expected: Array(initialIDs.dropFirst()) + [firstID])
            assertLitPreview(cells)
            attach(app, "\(name)-forward")
            drag(app, source: firstID, target: initialIDs[1])
            waitForOrder(cells, expected: initialIDs)
            assertLitPreview(cells)
            attach(app, "\(name)-restored")
            // Hold/release in place must not change membership or playback.
            revealSource(app, identifier: firstID)
            let point = app.descendants(matching: .any)[firstID].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            point.press(forDuration: 0.4, thenDragTo: point)
            waitForOrder(cells, expected: initialIDs)
            assertLitPreview(cells)
            app.terminate()
        }
    }

    private func shortSwipe(_ scroller: XCUIElement, left: Bool) {
        let start = scroller.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.8 : 0.2, dy: 0.25))
        let end = scroller.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.2 : 0.8, dy: 0.25))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func revealSource(_ app: XCUIApplication, identifier: String) {
        let scroller = app.scrollViews["group.preview.scroll"].firstMatch
        let source = app.descendants(matching: .any)[identifier].firstMatch
        guard scroller.exists else { return }
        if source.frame.midX > scroller.frame.maxX - 4 { shortSwipe(scroller, left: true) }
        if source.frame.midX < scroller.frame.minX + 4 { shortSwipe(scroller, left: false) }
        XCTAssertTrue(source.isHittable, "Scroll must expose the board before dragging")
    }

    private func drag(_ app: XCUIApplication, source: String, target: String) {
        revealSource(app, identifier: source)
        let start = app.descendants(matching: .any)[source].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let targetCell = app.descendants(matching: .any)[target].firstMatch
        let scroller = app.scrollViews["group.preview.scroll"].firstMatch
        let end: XCUICoordinate
        if scroller.exists {
            // A partially visible target can have its centre outside the
            // viewport. Release within its visible portion, as a user would.
            XCTAssertTrue(targetCell.frame.intersects(scroller.frame))
            let x = min(max(targetCell.frame.midX, scroller.frame.minX + 8), scroller.frame.maxX - 8)
            let y = targetCell.frame.minY + targetCell.frame.height * 0.25
            end = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        } else {
            end = targetCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        }
        start.press(forDuration: 0.4, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    private func waitForOrder(_ cells: XCUIElementQuery, expected: [String]) {
        let ordered = NSPredicate { _, _ in
            cells.allElementsBoundByIndex.sorted { $0.frame.midX < $1.frame.midX }.map(\.identifier) == expected
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ordered, object: nil)], timeout: 15), .completed)
    }

    private func assertLitPreview(_ cells: XCUIElementQuery) {
        let lit = NSPredicate { _, _ in
            cells.allElementsBoundByIndex.contains { cell in
                let count = (cell.value as? String)?.split(separator: "/").first?.trimmingCharacters(in: .whitespaces)
                return (count.flatMap(Int.init) ?? 0) > 0
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: lit, object: nil)], timeout: 10), .completed,
                       "Confirmed playback must display lit LED frames")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#endif
