import XCTest

/// Shared navigation to the face library sheet, used by tests in both
/// `SnapshotAcceptanceUITests` and `RinaBoardUITests`.
///
/// `管理表情` (the old entry point inside `BoardControlCenterView`) was removed
/// in `6658c34` (2026-09-12). The face library is still reachable, but only
/// from the Control tab now: the「保存列表」chip in `ControlView.swift` presents
/// `FaceLibraryView` as a sheet.
@MainActor
enum FaceLibraryUITestPath {
    /// Taps the Control tab's「保存列表」chip and waits for the face library
    /// sheet's navigation bar. The caller must already be on the Control tab
    /// (`-initialTab control`).
    @discardableResult
    static func openFaceLibrary(in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        // `CommandChip` combines its icon and title into one accessibility
        // label, which SwiftUI then doubles (e.g. "保存列表、保存列表") — the
        // same reason existing call sites in this suite match with
        // `CONTAINS` rather than an exact label.
        let saveList = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "保存列表")).firstMatch
        for _ in 0..<12 {
            if saveList.exists && saveList.isHittable { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        guard saveList.exists, saveList.isHittable else { return false }
        saveList.tap()
        return app.navigationBars["表情库"].waitForExistence(timeout: timeout)
    }
}
