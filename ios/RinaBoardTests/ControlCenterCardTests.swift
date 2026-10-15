import XCTest
@testable import RinaBoard

final class ControlCenterCardTests: XCTestCase {
    func testDragCanExpandThroughAllThreeStopsAndCollapseAgain() {
        XCTAssertEqual(ControlCenterCardStop.nearest(to: 80, availableHeight: 800), .collapsed)
        XCTAssertEqual(ControlCenterCardStop.nearest(to: 380, availableHeight: 800), .half)
        XCTAssertEqual(ControlCenterCardStop.nearest(to: 770, availableHeight: 800), .full)
        XCTAssertEqual(ControlCenterCardStop.nearest(to: -100, availableHeight: 800), .collapsed)
        XCTAssertEqual(ControlCenterCardStop.nearest(to: 1200, availableHeight: 800), .full)
    }

    func testResizingNeverLetsTheCardExtendIntoTheTabBar() {
        for availableHeight in [CGFloat(60), 200, 600, 900] {
            for stop in ControlCenterCardStop.allCases {
                XCTAssertLessThanOrEqual(stop.height(in: availableHeight), availableHeight)
                XCTAssertGreaterThan(stop.height(in: availableHeight), 0)
            }
        }
    }
}
