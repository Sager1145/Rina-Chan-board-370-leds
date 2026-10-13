import SwiftUI
import XCTest
@testable import RinaBoard

#if targetEnvironment(macCatalyst)
@MainActor
final class MacWindowLayoutTests: XCTestCase {
    private func settingsLayout(width: CGFloat,
                                previous: SettingsLayoutMode?) -> SettingsLayoutMode {
        SettingsLayoutPolicy.resolve(
            width: width,
            horizontalSizeClass: MacWindowLayoutPolicy.sizeClass(forWidth: width),
            dynamicTypeSize: .large,
            previous: previous
        )
    }

    func testNarrowMacWindowCollapsesBoardAndSettingsDespiteRegularSystemClass() {
        // Catalyst's regular system class cannot describe a resized Mac window.
        // 785 is also inside Settings' split hysteresis band, so a width class
        // derived from the actual window must override the previous split mode.
        for width: CGFloat in [600, 785, 1000] {
            let sizeClass = MacWindowLayoutPolicy.sizeClass(forWidth: width)
            XCTAssertEqual(sizeClass, .compact)
            XCTAssertFalse(BoardPageColumns.isSplit(.regular, windowWidth: width), "width \(width)")
            XCTAssertEqual(settingsLayout(width: width, previous: .split), .compact)
        }
        XCTAssertEqual(SettingsLayoutPolicy.resolve(
            width: 785, horizontalSizeClass: .regular,
            dynamicTypeSize: .large, previous: .split
        ), .split)
    }

    func testWideMacWindowRestoresBoardAndSettingsColumns() {
        let sizeClass = MacWindowLayoutPolicy.sizeClass(forWidth: 1200)
        XCTAssertEqual(sizeClass, .regular)
        XCTAssertTrue(BoardPageColumns.isSplit(.compact, windowWidth: 1200))
        XCTAssertEqual(settingsLayout(width: 1200, previous: .compact), .split)
    }

    func testResizeRoundTripPreservesSettingsRouteAndUnsavedConnectionDraft() {
        let workspace = SettingsWorkspace(initialSelection: .connection)
        workspace.apSSID = "RinaBoard-AP"
        workspace.apPassword = "unsaved password"
        workspace.apIP = "10.244.142.9"
        workspace.debugWorkspace = 4

        let layouts: [(CGFloat, SettingsLayoutMode)] = [
            (1200, .split), (600, .compact), (1200, .split)
        ]
        for (width, expected) in layouts {
            workspace.layoutMode = settingsLayout(width: width, previous: workspace.layoutMode)
            XCTAssertEqual(workspace.layoutMode, expected)
            XCTAssertEqual(workspace.selection, .connection)
            XCTAssertEqual(workspace.apSSID, "RinaBoard-AP")
            XCTAssertEqual(workspace.apPassword, "unsaved password")
            XCTAssertEqual(workspace.apIP, "10.244.142.9")
            XCTAssertEqual(workspace.debugWorkspace, 4)
        }
    }

    func testControlCenterRemainsInlineAcrossMacResize() {
        for width: CGFloat in [600, 1200] {
            let split = BoardPageColumns.isSplit(MacWindowLayoutPolicy.sizeClass(forWidth: width))
            XCTAssertEqual(ControlCenterPlacement.resolve(splitLayout: split), .previewColumn,
                           "Mac controls must stay inline at width \(width)")
        }
    }

    func testWindowCanBeResizedIntoCompactLayout() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let restrictions = try XCTUnwrap(scene.sizeRestrictions)
        print("Mac window sceneWidth=\(scene.coordinateSpace.bounds.width) minimumSize=\(restrictions.minimumSize)")
        XCTAssertLessThan(restrictions.minimumSize.width, MacWindowLayoutPolicy.splitMinimumWidth)
    }
}
#endif
