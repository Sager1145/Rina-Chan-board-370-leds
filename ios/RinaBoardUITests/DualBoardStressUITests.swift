import XCTest

// MARK: - Deterministic RNG

/// SplitMix64: a small, fast, seedable PRNG. Used instead of `SystemRandomNumberGenerator`
/// so a stress run can be reproduced byte-for-byte from `STRESS_SEED`
/// (docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md §0.1 R4, §5).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Step logging

/// Appends one CSV row per test step, mirrors it to the xcodebuild log via
/// `NSLog` (so a host-side tail can correlate it with board serial logs), and
/// attaches the full CSV to the test at teardown (plan §3.2, §5).
final class StepLogger {
    private struct Row {
        let tsStart: Double
        let tsEnd: Double
        let step: Int
        let seed: UInt64
        let entry: String
        let action: String
        let activeBoard: String
        let expectedBoards: String
        let flashWrite: Bool
    }

    private var rows: [Row] = []
    private let seed: UInt64

    init(seed: UInt64) { self.seed = seed }

    /// Logs one step. `start`/`end` should bracket the actual UI action as
    /// tightly as possible so the host-side oracle can align it with board
    /// serial timestamps (plan §3.2).
    func log(step: Int, entry: String, action: String, activeBoard: String,
              expectedBoards: String, flashWrite: Bool = false,
              start: Date = Date(), end: Date = Date()) {
        let row = Row(tsStart: start.timeIntervalSince1970, tsEnd: end.timeIntervalSince1970,
                      step: step, seed: seed, entry: entry, action: action,
                      activeBoard: activeBoard, expectedBoards: expectedBoards, flashWrite: flashWrite)
        rows.append(row)
        NSLog("STRESS_STEP %.3f,%.3f,%d,%llu,%@,%@,%@,%@,%d",
              row.tsStart, row.tsEnd, row.step, row.seed, entry, action,
              activeBoard, expectedBoards, flashWrite ? 1 : 0)
    }

    /// Records an entry that could not complete within its timeout budget
    /// (e.g. R1's per-board connect retry). Not a hard test failure by
    /// itself; the plan treats these as BLOCKED, not FAIL.
    func logBlocked(step: Int, entry: String, action: String) {
        NSLog("STRESS_STEP BLOCKED step=%d entry=%@ action=%@", step, entry, action)
    }

    private var csv: String {
        var lines = ["ts_start,ts_end,step,seed,entry,action,active_board,expected_boards,flash_write"]
        for row in rows {
            let fields = [
                String(format: "%.3f", row.tsStart), String(format: "%.3f", row.tsEnd),
                String(row.step), String(row.seed), escape(row.entry), escape(row.action),
                escape(row.activeBoard), escape(row.expectedBoards), row.flashWrite ? "1" : "0"
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func attach(to testCase: XCTestCase) {
        let attachment = XCTAttachment(data: Data(csv.utf8), uniformTypeIdentifier: "public.comma-separated-values-text")
        attachment.name = "STEPS.csv"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}

/// Multi-board stress harness driving a real device against
/// docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md §0.1 (R1–R4), §3.1, §4.2, §4.3, §4.8.
///
/// The app exposes almost no `accessibilityIdentifier`s, so most lookups go
/// through visible (Simplified Chinese) labels — see the fragile-spot notes
/// on `parseSessionRow` and `scanResultRows` below for the two riskiest ones.
final class DualBoardStressUITests: XCTestCase {
    private var app: XCUIApplication!
    private var logger: StepLogger!
    private var rng = SplitMix64(seed: 0)
    private var seed: UInt64 = 0
    private var steps = 50
    private var minBoards = 2

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        seed = env["STRESS_SEED"].flatMap(UInt64.init) ?? 20260913
        steps = env["STRESS_STEPS"].flatMap(Int.init) ?? 50
        minBoards = env["STRESS_MIN_BOARDS"].flatMap(Int.init) ?? 2
        rng = SplitMix64(seed: seed)
        logger = StepLogger(seed: seed)
        app = XCUIApplication()
        // Force Simplified Chinese so the label lookups below match the
        // literal strings in the Swift sources regardless of the device's
        // own language setting.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    }

    override func tearDownWithError() throws {
        logger?.attach(to: self)
        app = nil
        logger = nil
    }

    // MARK: - Tests

    /// R1 only: launch, connect every discovered board, assert the count.
    func testConnectAllDiscoveredBoards() throws {
        launchApp()
        let online = try connectAllDiscovered(step: 0)
        logger.log(step: 0, entry: "R1", action: "connectAllDiscovered",
                   activeBoard: activeBoard() ?? "-", expectedBoards: online.joined(separator: "|"))
    }

    /// E1 random walk across all online boards (plan §4.3 DB-RT, §4.11 DB-S-01,
    /// restricted to non-flash routing actions).
    func testE1RoutingRandomWalk() throws {
        launchApp()
        _ = try connectAllDiscovered(step: 0)

        for step in 1...steps {
            try ensureActiveOnline(step: step)
            let boards = onlineBoards()
            guard let target = boards.randomElement(using: &rng) else {
                throw XCTSkip("No online boards mid-run at step \(step)")
            }

            try selectSessionRow(identifier: target)
            logger.log(step: step, entry: "E1", action: "select \(target)",
                       activeBoard: target, expectedBoards: target)

            // Return to a tab before issuing the routing command, per the
            // brief's step shape (select → return to a tab → one action).
            app.tabBars.buttons["表情显示"].tap()

            let action = RoutingAction.allCases.randomElement(using: &rng)!
            try performRoutingAction(action, activeIdentifier: target, step: step)

            let dwell = Double.random(in: 0.2...2.0, using: &rng)
            Thread.sleep(forTimeInterval: dwell)
        }
    }

    /// DB-SW-04 regression: E2 (Control Center "控制对象" menu) onto a board that
    /// already has its own online session must reuse that session, not spin
    /// up a second one (DB-BUG-1).
    func testControlCenterSwitchToOnlineBoardSelectsExistingSession() throws {
        launchApp()
        let online = try connectAllDiscovered(step: 0)
        guard online.count >= 2 else {
            throw XCTSkip("Needs >= 2 online boards for a DB-SW-04 switch")
        }
        let boardX = online[0]
        let boardY = online[1]

        try selectSessionRow(identifier: boardX)
        logger.log(step: 1, entry: "E1", action: "select \(boardX)", activeBoard: boardX, expectedBoards: boardX)

        try openControlCenter()
        let start = Date()
        let menu = controlCenterBoardMenu()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "控制对象 menu not found in Control Center")
        menu.tap()
        let boardYItem = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", boardY)).firstMatch
        XCTAssertTrue(boardYItem.waitForExistence(timeout: 5), "\(boardY) not offered in the 控制对象 menu")
        boardYItem.tap()
        let end = Date()
        closeControlCenterIfPresented()

        // Give the (buggy, pre-fix) second handshake time to happen before
        // reading the session list back.
        Thread.sleep(forTimeInterval: 5)

        XCTAssertTrue(openConnectionScreen())
        let after = onlineBoards()
        XCTAssertEqual(after.count, online.count,
                       "online count changed after an E2 switch onto an already-online board (DB-BUG-1)")
        XCTAssertEqual(Set(after).count, after.count,
                       "duplicate session names after E2 switch (DB-BUG-1)")
        XCTAssertEqual(activeBoard(), boardY, "active board did not move to \(boardY) via E2 (DB-SW-04)")

        logger.log(step: 2, entry: "E2", action: "controlCenter switch to \(boardY)",
                   activeBoard: boardY, expectedBoards: "", start: start, end: end)
    }

    /// DB-FQ / INV-8: force-quit (Q2) and relaunch must recover full
    /// connectivity via R1 within the round.
    func testForceQuitRelaunchRecovers() throws {
        launchApp()
        _ = try connectAllDiscovered(step: 0)

        let rounds = max(3, steps / 10)
        for round in 1...rounds {
            let start = Date()
            app.terminate()
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15),
                          "The app tabs did not appear after relaunch (round \(round))")
            waitForBootOverlayToFinish()
            let online = try connectAllDiscovered(step: round)
            let end = Date()
            XCTAssertGreaterThanOrEqual(online.count, minBoards,
                                        "Online count not restored after relaunch (round \(round))")
            logger.log(step: round, entry: "R1", action: "forceQuitRelaunch(Q2) round \(round)",
                       activeBoard: activeBoard() ?? "-", expectedBoards: online.joined(separator: "|"),
                       start: start, end: end)
        }
    }

    // MARK: - Navigation

    private func launchApp() {
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10),
                      "The boot animation did not reveal the app tabs")
        waitForBootOverlayToFinish()
    }

    /// The tab bar mounts while `BootLoaderOverlay` is still up. The overlay
    /// is `.isModal`, so XCTest reports it as an alert ("页面加载中", then
    /// "页面加载完成") interrupting any tap underneath, and when it finishes
    /// mid-tap the interruption handler loses the element: "No matches found
    /// for Descendants matching type Alert" on the first 设定 tap of any test
    /// in this class (2026-09-17: one of four at load 18, all four at load
    /// 234). SnapshotAcceptanceUITests waits on the same labels.
    private func waitForBootOverlayToFinish(file: StaticString = #filePath, line: UInt = #line) {
        let overlay = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label == %@", "页面加载中", "页面加载完成"))
            .firstMatch
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 15),
                      "The boot overlay was still up after 15 s", file: file, line: line)
    }

    /// 设定 → 连接设置 (SettingsView.swift connectionSection → ConnectionView).
    @discardableResult
    private func openConnectionScreen() -> Bool {
        let settingsTab = app.tabBars.buttons["设定"]
        let reachable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: settingsTab)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 10), .completed,
                       "The 设定 tab was not hittable within 10 s")
        settingsTab.tap()
        guard app.navigationBars["设置"].waitForExistence(timeout: 5) else { return false }
        let row = app.buttons["连接设置"]
        guard scrollToElement(row) else { return false }
        row.tap()
        return app.navigationBars["连接"].waitForExistence(timeout: 5)
    }

    /// Opens the Control Center, whichever surface hosts it: the iOS 26
    /// tab-bar accessory ("面板控制" button, `BoardControlCenterAccessory.swift`)
    /// or, on iOS 17–25, the pushed screen reached from Settings ("面板控制中心",
    /// `SettingsView.swift`). Both land on the same `BoardControlCenterView`
    /// (navigation title "面板控制").
    private func openControlCenter() throws {
        let accessory = app.buttons["面板控制"]
        if accessory.waitForExistence(timeout: 2) {
            accessory.tap()
        } else {
            app.tabBars.buttons["设定"].tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
            let link = app.buttons["面板控制中心"]
            XCTAssertTrue(scrollToElement(link), "面板控制中心 entry not reachable")
            link.tap()
        }
        XCTAssertTrue(app.navigationBars["面板控制"].waitForExistence(timeout: 5),
                      "Control Center did not open")
    }

    /// Dismisses the Control Center: "完成" when it's the iOS 26 sheet, the
    /// leading nav-bar back button when it's a pushed screen under Settings.
    private func closeControlCenterIfPresented() {
        let navBar = app.navigationBars["面板控制"]
        guard navBar.exists else { return }
        let done = navBar.buttons["完成"]
        if done.exists {
            done.tap()
        } else {
            navBar.buttons.firstMatch.tap()
        }
    }

    /// The "控制对象" board/group-switcher menu inside `BoardControlCenterView`
    /// (`accessibilityIdentifier("controlCenter.controlTargetSelector")`).
    /// SwiftUI exposes a `Menu` as a button-like element that isn't always
    /// reported under `app.buttons`, so this falls back to the visible label.
    private func controlCenterBoardMenu() -> XCUIElement {
        let byID = app.descendants(matching: .any).matching(identifier: "controlCenter.controlTargetSelector").firstMatch
        if byID.waitForExistence(timeout: 2) { return byID }
        return app.buttons["控制对象"]
    }

    // MARK: - R1 connect-all

    /// R1: scan, connect every discovered board not already online, assert
    /// online count == discovered count. Skips (does not fail) below
    /// `minBoards`, per the brief.
    @discardableResult
    private func connectAllDiscovered(step: Int) throws -> [String] {
        XCTAssertTrue(openConnectionScreen(), "Could not reach the connection screen")

        let scanButton = app.buttons["扫描附近的璃奈板"]
        if scanButton.waitForExistence(timeout: 3) {
            scanButton.tap()
        }

        // The scan stops itself after ~30s (ConnectionView.swift); wait for
        // that, or for the row count to settle, up to 35s.
        let scanDeadline = Date().addingTimeInterval(35)
        var lastCount = -1
        var stableTicks = 0
        while Date() < scanDeadline {
            if !app.buttons["停止扫描"].exists { break }
            let count = scanResultRows().count
            if count == lastCount {
                stableTicks += 1
                if stableTicks >= 3 { break }
            } else {
                stableTicks = 0
            }
            lastCount = count
            Thread.sleep(forTimeInterval: 1)
        }

        let discoveredCount = scanResultRows().count
        guard discoveredCount >= minBoards else {
            throw XCTSkip("Only \(discoveredCount) board(s) discovered; need >= \(minBoards)")
        }

        for index in 0..<discoveredCount {
            let rows = scanResultRows()
            guard index < rows.count else { break }
            let row = rows[index]
            guard row.exists, !row.label.contains("已连接") else { continue }

            let before = onlineBoards().count
            if row.isHittable { row.tap() }
            var connected = waitForOnlineCountIncrease(from: before, timeout: 20)
            if !connected {
                // One retry, per R1's rule.
                let retryRows = scanResultRows()
                if index < retryRows.count, retryRows[index].isHittable {
                    retryRows[index].tap()
                }
                connected = waitForOnlineCountIncrease(from: before, timeout: 20)
            }
            if !connected {
                logger.logBlocked(step: step, entry: "R1", action: "connect row \(index)")
            }
        }

        let online = onlineBoards()
        XCTAssertEqual(online.count, discoveredCount,
                       "Online count (\(online.count)) does not match discovered boards (\(discoveredCount))")
        return online
    }

    /// R3: if the active board is offline, switch to the first online board;
    /// if none are online, wait and re-run R1.
    private func ensureActiveOnline(step: Int) throws {
        XCTAssertTrue(openConnectionScreen())
        let online = onlineBoards()
        if let active = activeBoard(), online.contains(active) { return }
        if let row = sessionRows().first(where: { parseSessionRow($0.label).online }) {
            row.tap()
            return
        }
        Thread.sleep(forTimeInterval: 10)
        _ = try connectAllDiscovered(step: step)
    }

    /// E1: taps the "控制对象" row matching `identifier`.
    private func selectSessionRow(identifier: String) throws {
        XCTAssertTrue(openConnectionScreen())
        guard let row = sessionRows().first(where: { parseSessionRow($0.label).identifier == identifier }) else {
            XCTFail("Session row for \(identifier) not found")
            return
        }
        row.tap()
    }

    // MARK: - Routing actions (non-flash)

    private enum RoutingAction: CaseIterable {
        case next, previous, brightness, facesRandom

        var description: String {
            switch self {
            case .next: return "controlCenter.next"
            case .previous: return "controlCenter.previous"
            case .brightness: return "controlCenter.brightness"
            case .facesRandom: return "faces.random"
            }
        }
    }

    private func performRoutingAction(_ action: RoutingAction, activeIdentifier: String, step: Int) throws {
        let start = Date()
        switch action {
        case .next, .previous:
            try openControlCenter()
            let label = action == .next ? "下一个表情" : "上一个表情"
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(label) button not found")
            button.tap()
            closeControlCenterIfPresented()
        case .brightness:
            try openControlCenter()
            // Only one Slider is on screen in BoardControlCenterView at once
            // that isn't the auto-interval slider it sits above; `firstMatch`
            // is the brightness slider because it's declared first.
            let slider = app.sliders.firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 5), "Brightness slider not found")
            let position = Double.random(in: 0.1...0.9, using: &rng)
            slider.adjust(toNormalizedSliderPosition: position)
            closeControlCenterIfPresented()
        case .facesRandom:
            app.tabBars.buttons["表情显示"].tap()
            let livePreview = app.switches["实时预览"]
            if livePreview.waitForExistence(timeout: 3), livePreview.value as? String == "0" {
                livePreview.tap()
            }
            let randomButton = app.buttons["随机"]
            XCTAssertTrue(scrollToElement(randomButton), "随机 button not reachable")
            randomButton.tap()
        }
        let end = Date()
        logger.log(step: step, entry: "E1", action: action.description,
                   activeBoard: activeIdentifier, expectedBoards: activeIdentifier,
                   start: start, end: end)
    }

    // MARK: - Row parsing (fragile: see notes)

    /// Scan-result rows in `ConnectionView.bluetoothSection`
    /// (`ConnectionView.swift` `peripheralRow`). Each row's accessibility
    /// label is a VoiceOver-style concatenation of its child `Text`s, e.g.
    /// "RinaBoard-80B54EF48E09, ABCD1234 · -60 dBm, 连接" — there is no
    /// `accessibilityIdentifier` on the row. "· … dBm" is stable across app
    /// versions (it's the RSSI readout) so it is used as the row anchor here.
    /// FRAGILE: if the RSSI display format ever changes, this predicate must
    /// change with it.
    private func scanResultRows() -> [XCUIElement] {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "dBm")
        let query = app.buttons.matching(predicate)
        return (0..<query.count).map { query.element(boundBy: $0) }
    }

    /// "控制对象" rows in `ConnectionView.sessionsSection`. Each row is a
    /// `Button` whose label merges `Image(systemName: "checkmark.circle.fill"
    /// | "circle")` with the device name and "在线"/"未连接" — there is no
    /// `accessibilityIdentifier` here either. FRAGILE: this relies on iOS's
    /// auto-generated spoken description for SF Symbols (typically the
    /// symbol name with dots turned into spaces, e.g. "checkmark circle
    /// fill") staying stable, and on VoiceOver's default ", "-joined
    /// concatenation of a button's child `Text`/`Image` elements. Verify
    /// with Accessibility Inspector on the first real run and adjust
    /// `parseSessionRow` if the device reports a different join style.
    private func sessionRows() -> [XCUIElement] {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "在线", "未连接")
        let query = app.buttons.matching(predicate)
        var rows: [XCUIElement] = []
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            guard !element.label.contains("dBm") else { continue } // exclude scan rows
            rows.append(element)
        }
        return rows
    }

    /// Strips the leading checkmark/circle image description and the
    /// trailing 在线/未连接 status word from a session row's label, leaving a
    /// stable per-board identifier. See the fragile-spot note on
    /// `sessionRows()`.
    private func parseSessionRow(_ label: String) -> (identifier: String, online: Bool) {
        var text = label
        for prefix in ["checkmark, circle, fill, ", "checkmark circle fill, ", "checkmark circle fill",
                       "circle, ", "circle "] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        let online = text.contains("在线")
        for suffix in [", 在线", " 在线", ", 未连接", " 未连接", "在线", "未连接"] {
            if text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
                break
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), online)
    }

    private func onlineBoards() -> [String] {
        sessionRows().map { parseSessionRow($0.label) }.filter(\.online).map(\.identifier)
    }

    private func activeBoard() -> String? {
        for row in sessionRows() where row.label.lowercased().hasPrefix("checkmark") {
            let parsed = parseSessionRow(row.label)
            if parsed.online { return parsed.identifier }
        }
        return nil
    }

    private func waitForOnlineCountIncrease(from count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if onlineBoards().count > count { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: - Scrolling (same recipe as RinaBoardUITests.swift)

    @discardableResult
    private func scrollToElement(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        _ = element.waitForExistence(timeout: 1)
        for _ in 0..<attempts {
            if isSafelyHittable(element) { return true }
            let targetIsAboveViewport = element.exists && element.frame.midY < 150
            shortSwipe(up: !targetIsAboveViewport)
        }
        return isSafelyHittable(element)
    }

    private func isSafelyHittable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let isNestedPresentation = app.sheets.firstMatch.exists || app.navigationBars.count > 1
        let bottom = isNestedPresentation ? app.frame.maxY - 60 : 650
        return (150...bottom).contains(element.frame.midY)
    }

    private func shortSwipe(up: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.68 : 0.36))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.44 : 0.60))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
