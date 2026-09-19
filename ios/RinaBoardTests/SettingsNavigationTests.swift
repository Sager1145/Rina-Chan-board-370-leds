import XCTest
import SwiftUI
@testable import RinaBoard

/// The Settings layout rule and the route that must survive it.
@MainActor
final class SettingsNavigationTests: XCTestCase {
    private func resolve(_ width: CGFloat,
                         _ previous: SettingsLayoutMode?,
                         sizeClass: UserInterfaceSizeClass? = .regular,
                         typeSize: DynamicTypeSize = .large) -> SettingsLayoutMode {
        SettingsLayoutPolicy.resolve(width: width, horizontalSizeClass: sizeClass,
                                     dynamicTypeSize: typeSize, previous: previous)
    }

    func testFirstLayoutSplitsOnlyFromTheEnterWidth() {
        XCTAssertEqual(resolve(799, nil), .compact)
        XCTAssertEqual(resolve(800, nil), .split)
        XCTAssertEqual(resolve(1180, nil), .split)
    }

    func testHysteresisBandKeepsTheCurrentLayout() {
        // Inside 770..<800 the answer depends only on where it came from.
        for width: CGFloat in [770, 785, 799] {
            XCTAssertEqual(resolve(width, .split), .split, "width \(width)")
            XCTAssertEqual(resolve(width, .compact), .compact, "width \(width)")
        }
        XCTAssertEqual(resolve(769, .split), .compact)
        XCTAssertEqual(resolve(800, .compact), .split)
    }

    func testDraggingAcrossOneEdgeDoesNotFlapTheLayout() {
        var mode: SettingsLayoutMode? = nil
        var changes = 0
        for width: CGFloat in [840, 790, 775, 799, 771, 798, 780, 840] {
            let next = resolve(width, mode)
            if mode != nil, next != mode { changes += 1 }
            mode = next
        }
        XCTAssertEqual(changes, 0)
    }

    /// A device resting at one of these must land in the same layout
    /// whichever layout it rotated from.
    func testCommonDeviceWidthsDoNotDependOnHistory() {
        for width: CGFloat in [375, 390, 440, 678, 744, 768, 810, 820, 834, 1024, 1133, 1180, 1366] {
            XCTAssertEqual(resolve(width, .split), resolve(width, .compact), "width \(width)")
        }
    }

    func testCompactWidthClassNeverSplits() {
        XCTAssertEqual(resolve(1366, .split, sizeClass: .compact), .compact)
        XCTAssertEqual(resolve(1366, nil, sizeClass: nil), .compact)
        XCTAssertEqual(resolve(0, .split), .compact)
    }

    func testAccessibilityTextNeedsAWiderWindow() {
        XCTAssertEqual(resolve(900, nil, typeSize: .accessibility2), .compact)
        XCTAssertEqual(resolve(1024, nil, typeSize: .accessibility2), .split)
        XCTAssertEqual(resolve(900, .split, typeSize: .accessibility2), .compact)
    }

    func testLaunchArgumentRoutes() {
        XCTAssertEqual(SettingsCategory(launchArgument: "debug"), .debug)
        XCTAssertEqual(SettingsCategory(launchArgument: "connect"), .connection)
        XCTAssertEqual(SettingsCategory(launchArgument: "add-board"), .addBoard)
        XCTAssertNil(SettingsCategory(launchArgument: "settings"))
        XCTAssertNil(SettingsCategory(launchArgument: nil))
    }

    func testReturningToTheListKeepsTheLastVisitedPage() {
        let workspace = SettingsWorkspace(initialSelection: nil)
        workspace.selection = .debug
        workspace.selection = nil
        XCTAssertNil(workspace.selection)
        XCTAssertEqual(workspace.lastVisited, .debug)
    }

    func testLayoutChangeLeavesRouteAndDraftsAlone() {
        let workspace = SettingsWorkspace(initialSelection: .connection)
        workspace.apSSID = "RinaBoard-AP"
        workspace.apPassword = "draft"
        workspace.debugWorkspace = 4
        workspace.layoutMode = .split
        workspace.layoutMode = .compact
        workspace.layoutMode = .split
        XCTAssertEqual(workspace.selection, .connection)
        XCTAssertEqual(workspace.apSSID, "RinaBoard-AP")
        XCTAssertEqual(workspace.apPassword, "draft")
        XCTAssertEqual(workspace.debugWorkspace, 4)
    }

    func testControlCenterEntryStaysWhileOpen() {
        let workspace = SettingsWorkspace(initialSelection: nil)
        XCTAssertFalse(workspace.categories(controlCenterInSettings: false).contains(.controlCenter))
        XCTAssertTrue(workspace.categories(controlCenterInSettings: true).contains(.controlCenter))
        workspace.selection = .controlCenter
        XCTAssertTrue(workspace.categories(controlCenterInSettings: false).contains(.controlCenter))
    }

    func testOpenGroupEditorSurvivesLayoutChangeButNotAnotherCategory() {
        let workspace = SettingsWorkspace(initialSelection: .groups)
        let id = UUID()
        workspace.editingGroupID = id

        workspace.layoutMode = .split
        workspace.layoutMode = .compact
        workspace.selection = .groups
        XCTAssertEqual(workspace.editingGroupID, id)

        workspace.selection = .about
        XCTAssertNil(workspace.editingGroupID)
    }

    func testSwitchingBoardDropsItsDraftsAndConfirmations() {
        let workspace = SettingsWorkspace(initialSelection: .board)
        let boardA = BoardConnection()
        let boardB = BoardConnection()
        workspace.boardChanged(to: boardA)
        workspace.apSSID = "A-net"
        workspace.bluetoothFilter = "rina"
        workspace.confirmBoardReboot = true

        // Re-announcing the same board (a page rebuilt by a resize) keeps all.
        workspace.boardChanged(to: boardA)
        XCTAssertEqual(workspace.apSSID, "A-net")
        XCTAssertTrue(workspace.confirmBoardReboot)

        workspace.boardChanged(to: boardB)
        XCTAssertEqual(workspace.apSSID, "")
        XCTAssertFalse(workspace.confirmBoardReboot)
        // Not tied to a board.
        XCTAssertEqual(workspace.bluetoothFilter, "rina")
    }

    func testConnectionErrorAlertsOnlyOnThePageThatActed() {
        let workspace = SettingsWorkspace(initialSelection: .connection)
        workspace.connection.lastErrorMessage = "boom"
        // An error no page claimed belongs to 连接.
        XCTAssertEqual(workspace.connectionError(for: .connection).wrappedValue, "boom")
        XCTAssertNil(workspace.connectionError(for: .network).wrappedValue)

        workspace.markConnectionAction(from: .addBoard)
        XCTAssertEqual(workspace.connectionError(for: .addBoard).wrappedValue, "boom")
        XCTAssertNil(workspace.connectionError(for: .connection).wrappedValue)

        workspace.connectionError(for: .addBoard).wrappedValue = nil
        XCTAssertNil(workspace.connection.lastErrorMessage)
    }
}

