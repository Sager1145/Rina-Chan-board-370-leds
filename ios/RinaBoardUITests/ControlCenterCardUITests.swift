import XCTest
import UIKit

final class ControlCenterCardUITests: XCTestCase {
    @MainActor
    func testCardDragsThroughThreeStopsWithoutCoveringNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-initialTab", "control", "-disableStarAnimation", "YES"]
        app.launch()
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone
                          && app.windows.firstMatch.frame.width < 600,
                          "Requires an ordinary iPhone or single-column phone window")
        let card = app.otherElements["controlCenter.card"].firstMatch
        let handle = app.buttons["controlCenter.card.handle"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        XCTAssertEqual(handle.value as? String, "已收起")
        for id in ["mode", "previous", "next", "color"] {
            XCTAssertTrue(app.buttons["controlCenter.toolbar." + id].exists)
        }
        XCTAssertTrue(app.buttons["controlCenter.statusButton"].exists)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(card.frame.maxY, tabBar.frame.minY + 1)

        drag(handle, by: -180)
        expect(handle, value: "半屏")
        let halfHeight = card.frame.height
        XCTAssertGreaterThan(halfHeight, 200)
        drag(handle, by: -300)
        expect(handle, value: "全屏")
        XCTAssertGreaterThan(card.frame.height, halfHeight + 100)
        XCTAssertTrue(tabBar.buttons.element(boundBy: 1).isHittable)
        tabBar.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        drag(handle, by: 700)
        expect(handle, value: "已收起")
        XCTAssertLessThan(card.frame.height, 120)
        XCTAssertTrue(tabBar.buttons.element(boundBy: 4).isHittable)
    }

    @MainActor
    private func drag(_ handle: XCUIElement, by distance: CGFloat) {
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    @MainActor
    private func expect(_ handle: XCUIElement, value: String) {
        let predicate = NSPredicate(format: "value == %@", value)
        expectation(for: predicate, evaluatedWith: handle)
        waitForExpectations(timeout: 5)
    }
}
