import XCTest

/// Opt-in, fixture-backed stress matrix. Physical hinge changes are supplied
/// through Device Hub when RINA_STRESS_REQUEST is printed by the runner.
@MainActor
final class DuoMenuStressUITests: XCTestCase {
    private let tabs = ["Expressions", "Text", "Speak", "Live", "Settings"]
    private let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]
    private var selected = "Expressions"
    private var tabEdges = Set<String>()
    private var orientationEdges = Set<String>()
    private var toolbarFrames: [String: CGRect] = [:]
    private var boardPanelTop: CGFloat?
    private var physicalSequence = 0
    private let physicalRun = UUID().uuidString
    private var currentHinge = "open"
    private var lastDirection = 0
    private var diagnoseSwitchers = false
    private var activeApplication: XCUIApplication?
    private var expandsSwitcherForLegacyProbe = false
    private var requestURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RinaMenuStressRequest.json")
    }

    func testBootAnimationSurvivesClosingAndOpening() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] != nil, "Opt-in physical boot animation regression")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-disableStarAnimation", "YES", "-bootMinimumDisplay", "300"]
        app.launch()
        activeApplication = app
        defer { finishPhysicalRun(); app.terminate() }
        for (hinge, index) in [("folded", 0), ("open", 1), ("folded", 0), ("half", 0)] {
            currentHinge = hinge
            physicalPose(hinge: hinge, direction: index)
            let loading = app.descendants(matching: .any)["boot.loader"].firstMatch
            XCTAssertTrue(loading.exists, "Hinge transition must occur while the boot animation is still playing")
            let state = capture(app)
            XCTAssertTrue(hinge == "open" ? state.window.width > state.window.height : state.window.height > state.window.width)
            print("RINA_BOOT_HINGE_PASS hinge=\(hinge) direction=\(index) loaderVisible=true")
            fflush(stdout)
        }
        print("RINA_BOOT_HINGE_RESULT PASS")
        fflush(stdout)
    }

    func testGroupActionsStayInsideMenu() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] != nil, "Opt-in Duo menu actions regression")
        let app = launch()
        defer { finishPhysicalRun(); app.terminate() }
        currentHinge = ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] ?? "open"
        let direction: UIDeviceOrientation = currentHinge == "folded" ? .portrait : .landscapeLeft
        rotate(app, to: direction, folded: currentHinge == "folded")
        select(app, "Settings")
        tap(app, identifier: "settings.category.groups")
        let groups = waitForSnapshot(app, timeout: 10, message: "Group creation must be a menu row") {
            $0.first(.button, identifier: "groups.create") != nil
        }
        let create = groups.first(.button, identifier: "groups.create")!
        let menu = groups.elements.first { node in
            node.elementType == .collectionView && node.frame.contains(CGPoint(x: create.frame.midX, y: create.frame.midY))
        }
        XCTAssertNotNil(menu, "Create belongs inside the scrollable menu, not the camera rail")
        if currentHinge != "folded" { assertMenu(groups, hinge: currentHinge, direction: direction) }
        tap(app, identifier: "groups.create")
        XCTAssertTrue(app.textFields["groups.create.name"].waitForExistence(timeout: 5))
        tap(app, label: "Cancel")
        let list = capture(app)
        let group = try XCTUnwrap(list.first(.button, labelPrefix: "Test · 3 mirrors"))
        tap(app, label: group.label)
        let editor = waitForSnapshot(app, timeout: 10, message: "Group edit must remain inside its menu") {
            $0.first(.button, identifier: "groups.editMode") != nil
        }
        let edit = editor.first(.button, identifier: "groups.editMode")!
        if currentHinge != "folded" { assertMenu(editor, hinge: currentHinge, direction: direction) }
        XCTAssertTrue(editor.elements.contains { node in
            node.elementType == .collectionView && node.frame.contains(CGPoint(x: edit.frame.midX, y: edit.frame.midY))
        }, "Edit belongs inside the scrollable menu, not the camera rail")
        if currentHinge == "open" {
            // A nested editor must remain in Settings' detail pane when the
            // native screen changes; its route survives folded stack layout.
            for (hinge, index) in [("open", 0), ("half", 0), ("folded", 0),
                                   ("open", 1), ("half", 1), ("open", 2),
                                   ("half", 2), ("open", 3), ("half", 3)] {
                currentHinge = hinge
                let state = rotate(app, to: orientations[index], folded: hinge == "folded")
                XCTAssertNotNil(state.first(.button, identifier: "groups.editMode"), "Group editor must survive posture changes")
                assertMenu(state, hinge: hinge, direction: orientations[index])
            }
        }
    }

    func testLandscapeNavbarRetainsEveryTab() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] != nil, "Opt-in physical Duo navbar regression")
        let app = launch()
        defer { finishPhysicalRun(); app.terminate() }
        expandsSwitcherForLegacyProbe = false
        currentHinge = ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] == "half" ? "half" : "open"
        for direction in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            let state = rotate(app, to: direction, folded: false)
            for name in tabs {
                let button = tabButton(app, name)
                XCTAssertTrue(button.isHittable, "Every tab must remain directly tappable without expanding navbar: " + name)
                let frame = tabSnapshot(state, name)?.frame ?? .zero
                XCTAssertFalse(frame.isEmpty)
                XCTAssertGreaterThanOrEqual(frame.minY, state.window.minY - 2)
                XCTAssertLessThanOrEqual(frame.maxY, state.window.maxY + 2)
            }
            for name in ["mode", "previous", "next"] {
                XCTAssertNotNil(state.first(.button, identifier: "controlCenter.toolbar." + name))
            }
        }
    }

    func testStressSelectorProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] != nil, "Opt-in stress selector diagnosis")
        let app = launch()
        defer { finishPhysicalRun(); app.terminate() }
        currentHinge = ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] == "half" ? "half" : "open"
        diagnoseSwitchers = true
        let probeDirection = Int(ProcessInfo.processInfo.environment["RINA_STRESS_START_DIRECTION"] ?? "0") ?? 0
        if let from = ProcessInfo.processInfo.environment["RINA_STRESS_PROBE_FROM"].flatMap(Int.init) {
            rotate(app, to: orientations[from], folded: false)
            select(app, "Settings")
            if ProcessInfo.processInfo.environment["RINA_STRESS_PROBE_COLOR"] != "0" { exerciseColor(app) }
        }
        rotate(app, to: orientations[probeDirection], folded: false)
        print("RINA_PROBE_RETAINED selected=\(selected) actual=\(actualSelection(capture(app)))")
        fflush(stdout)
        for tab in ["Expressions", "Settings", "Text"] {
            select(app, tab)
            for name in tabs {
                let button = tabButton(app, name)
                if !button.exists { print("RINA_SELECTOR missing " + name); continue }
                print("RINA_SELECTOR expected=\(tab) label=\(name) selected=\(button.isSelected) value=\(String(describing: button.value)) frame=\(button.frame)")
            }
            if tab != "Text" { print("RINA_PAGE_AX " + tab + " " + app.debugDescription) }
            print("RINA_SELECTOR_PAGE expected=\(tab) text=\(app.textViews.count) random=\(app.buttons["Random"].exists) settings=\(app.collectionViews["settings.sidebar"].exists)")
            fflush(stdout)
        }
    }

    func testAllTabPairsAndRotationPairs() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] != nil, "Opt-in physical Duo stress run")
        let requested = try XCTUnwrap(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"])
        let app = launch()
        defer { finishPhysicalRun(); app.terminate() }
        for hinge in requested == "all" ? ["open", "half", "folded"] : [requested] {
        currentHinge = hinge
        tabEdges = []
        orientationEdges = []
        let rotationsOnly = ProcessInfo.processInfo.environment["RINA_STRESS_ROTATIONS_ONLY"] == "1"
        let startDirection = hinge == "open" ? Int(ProcessInfo.processInfo.environment["RINA_STRESS_START_DIRECTION"] ?? "0") ?? 0 : 0
        let directions = hinge == "folded" ? [UIDeviceOrientation.portrait] : Array(orientations.dropFirst(startDirection))
        if !rotationsOnly {
        for direction in directions {
            let directionIndex = orientations.firstIndex(of: direction)!
            let pose = rotate(app, to: direction, folded: hinge == "folded")
            XCTAssertTrue(matches(pose, hinge: hinge, direction: direction), "Wrong physical hinge for \(hinge)")
            toolbarFrames = [:]
            boardPanelTop = nil
            for cycle in 0..<2 {
                for index in edgeWalk(5) {
                    let previous = selected
                    let state = select(app, tabs[index])
                    if previous != selected { tabEdges.insert("\(directionIndex):\(previous)>\(selected)") }
                    assertMenu(state, hinge: hinge, direction: direction)
                    assertStableTabGeometry(state)
                }
                print("RINA_STRESS_PROGRESS hinge=\(hinge) direction=\(directionIndex) cycle=\(cycle) tabEdges=\(tabEdges.count)")
                fflush(stdout)
            }
            for tab in tabs {
                select(app, tab)
                var state = exerciseColor(app)
                if hinge == "folded" { state = exerciseControlCenter(app) }
                assertStableTabGeometry(state)
            }
            attach(app, "\(hinge)-\(directionIndex)")
        }
        XCTAssertEqual(tabEdges.count, directions.count * 20)
        } else {
            print("RINA_STRESS_STATIC_SKIPPED hinge=\(hinge) previouslyVerified=true")
            fflush(stdout)
        }
        if hinge != "folded" {
            for tab in tabs {
                select(app, tab)
                for index in edgeWalk(4) {
                    let old = lastDirection
                    let state = rotate(app, to: orientations[index], folded: false)
                    if old != index {
                        orientationEdges.insert("\(tab):\(old)>\(index)")
                    }
                    assertMenu(state, hinge: hinge, direction: orientations[index])
                    XCTAssertEqual(selected, tab)
                }
            }
            XCTAssertEqual(orientationEdges.count, 60)
        } else {
            // Closed mode stays portrait even when the hardware is rotated.
            for direction in orientations {
                let state = rotate(app, to: direction, folded: true)
                assertMenu(state, hinge: hinge, direction: .portrait)
            }
        }
        print("RINA_STRESS_RESULT hinge=\(hinge) tabEdges=\(tabEdges.count) orientationEdges=\(orientationEdges.count) PASS")
        fflush(stdout)
        }
    }

    func testAllPhysicalHingePairsWithEveryTabSelected() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] != nil, "Opt-in physical Duo stress run")
        let resumeStep: Int?
        if let raw = ProcessInfo.processInfo.environment["RINA_STRESS_COMBINED_START_STEP"] {
            let step = try XCTUnwrap(Int(raw))
            try XCTSkipUnless((1...72).contains(step), "Checkpoint must identify a remaining directed edge")
            resumeStep = step
        } else {
            resumeStep = nil
        }
        let app = launch()
        defer { finishPhysicalRun(); app.terminate() }
        let hinges = ["open", "half", "folded"]
        var edges = Set<String>()
        var sequence = 0
        func apply(_ hinge: String, direction: UIDeviceOrientation, directionIndex: Int) {
            currentHinge = hinge
            lastDirection = directionIndex
            physicalPose(hinge: hinge, direction: directionIndex)
            print("RINA_STRESS_REQUEST seq=\(sequence) tab=\(selected) hinge=\(hinge) direction=\(directionIndex)")
            fflush(stdout)
            let state = waitForSnapshot(app, timeout: 90,
                                        message: "Device Hub must supply \(hinge), sequence \(sequence)") { state in
                self.matches(state, hinge: hinge, direction: direction)
            }
            assertMenu(state, hinge: hinge, direction: hinge == "folded" ? .portrait : direction)
            print("RINA_STRESS_SETTLED seq=\(sequence) hinge=\(hinge)")
            fflush(stdout)
            sequence += 1
        }
        // First hold every selected tab across all six directed hinge edges.
        if resumeStep == nil {
            for (tabIndex, tab) in tabs.enumerated() {
                select(app, tab)
                let direction = orientations[tabIndex % orientations.count]
                var previous: String?
                for index in edgeWalk(3) {
                    let hinge = hinges[index]
                    apply(hinge, direction: direction, directionIndex: tabIndex % 4)
                    XCTAssertEqual(selected, tab)
                    if let previous, previous != hinge { edges.insert("\(tab):\(previous)>\(hinge)") }
                    previous = hinge
                }
                attach(app, "hinge-\(tab)")
            }
        }
        // Then walk all 72 ordered pairs of the nine legal combined poses,
        // interleaving tab selection before each combined state transition.
        let poses = ["open", "half"].flatMap { hinge in orientations.enumerated().map { (hinge, $0.offset, $0.element) } }
            + [("folded", 0, UIDeviceOrientation.portrait)]
        var combinedEdges = Set<String>()
        var previousPose: Int?
        // Re-establish the preceding pose before checking a resumed edge.
        // Skipped edges are never counted as verified by this run.
        for (step, index) in edgeWalk(9).enumerated() {
            if step < max(0, (resumeStep ?? 1) - 1) { continue }
            select(app, tabs[step % tabs.count])
            let pose = poses[index]
            apply(pose.0, direction: pose.2, directionIndex: pose.1)
            if let previousPose, previousPose != index { combinedEdges.insert("\(previousPose)>\(index)") }
            previousPose = index
        }
        XCTAssertEqual(combinedEdges.count, 73 - (resumeStep ?? 1))
        print("RINA_STRESS_RESULT combinedPoseEdges=\(combinedEdges.count) firstStep=\(resumeStep ?? 1) PASS")
        fflush(stdout)
        if resumeStep == nil {
            XCTAssertEqual(edges.count, 30)
            print("RINA_STRESS_RESULT hingeEdges=\(edges.count) PASS")
            fflush(stdout)
        }
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        activeApplication = app
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-initialTab", "control",
                               "-disableStarAnimation", "YES", "-seedTestGroups", "YES", "-connectTestBoards", "YES",
                               "-testBoardPort", "15370", "-testGroupName", "Test · 3 mirrors"]
        app.launch()
        XCTAssertTrue(app.buttons["controlCenter.toolbar.mode"].firstMatch.waitForExistence(timeout: 20))
        for label in ["Page loading", "Page loaded", "页面加载中", "页面加载完成"] {
            let overlay = app.descendants(matching: .any)[label].firstMatch
            if overlay.exists { XCTAssertTrue(overlay.waitForNonExistence(timeout: 15)) }
        }
        selected = "Expressions"
        return app
    }

    /// Attributes on these nodes are read locally from one settled AX tree.
    /// Keep live XCUIElements only for actions and hittability checks.
    @MainActor
    private struct MenuSnapshot {
        let elements: [any XCUIElementSnapshot]

        init(_ root: (any XCUIElementSnapshot)?) {
            elements = root.map(Self.flatten) ?? []
        }

        private static func flatten(_ node: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
            [node] + node.children.flatMap(flatten)
        }

        func first(_ type: XCUIElement.ElementType = .any, identifier: String? = nil,
                   label: String? = nil, identifierPrefix: String? = nil,
                   labelPrefix: String? = nil) -> (any XCUIElementSnapshot)? {
            elements.first { node in
                (type == .any || node.elementType == type)
                    && (identifier == nil || node.identifier == identifier)
                    && (label == nil || node.label == label)
                    && (identifierPrefix == nil || node.identifier.hasPrefix(identifierPrefix!))
                    && (labelPrefix == nil || node.label.hasPrefix(labelPrefix!))
            }
        }

        func descendant(of node: (any XCUIElementSnapshot)?, type: XCUIElement.ElementType) -> (any XCUIElementSnapshot)? {
            node?.children.flatMap(Self.flatten).first { $0.elementType == type }
        }

        var window: CGRect { first(.window)?.frame ?? .zero }
    }

    private func capture(_ app: XCUIApplication) -> MenuSnapshot {
        do { return MenuSnapshot(try app.snapshot()) }
        catch {
            XCTFail("Unable to acquire menu AX snapshot: \(error)")
            return MenuSnapshot(nil)
        }
    }

    private func waitForSnapshot(_ app: XCUIApplication, timeout: TimeInterval, message: String,
                                 condition: @escaping (MenuSnapshot) -> Bool) -> MenuSnapshot {
        var state: MenuSnapshot?
        let ready = NSPredicate { _, _ in
            let current = self.capture(app)
            state = current
            return condition(current)
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: timeout)
        if result != .completed {
            print("RINA_WAIT_FAILURE " + message + " " + app.debugDescription)
            attach(app, "failed-transition")
            fflush(stdout)
        }
        XCTAssertEqual(result, .completed, message)
        return state ?? capture(app)
    }

    @discardableResult
    private func select(_ app: XCUIApplication, _ tab: String) -> MenuSnapshot {
        let initial = capture(app)
        if selected == tab && actualSelection(initial) { return initial }
        if ProcessInfo.processInfo.environment["RINA_STRESS_NATIVE_ACTIONS"] == "1" {
            hostAction(["action": "selectTab", "tab": tab, "currentTab": selected])
            selected = tab
            return waitForSnapshot(app, timeout: 10, message: "Actual page must be " + tab) { self.actualSelection($0) }
        }
        let window = initial.window
        let landscape = window.width > window.height
        if landscape {
            let alreadyExpanded = tabs.allSatisfy { name in
                guard let button = self.tabSnapshot(initial, name) else { return false }
                return !button.frame.isEmpty && button.frame.minY >= window.minY - 2
                    && button.frame.maxY <= window.maxY + 2 && self.tabButton(app, name).isHittable
            }
            if !alreadyExpanded {
            // Compressed child-tab frames describe the uncompressed stack.
            // Touch the real native switcher's small containing surface.
            let boxes = app.otherElements.containing(.button, identifier: selected).allElementsBoundByIndex
            let box = boxes.map { (element: $0, frame: $0.frame) }.filter {
                let f = $0.frame
                return f.width >= 35 && f.width <= 80 && f.height >= 35 && f.height <= 80 && f.midY > window.midY
            }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            XCTAssertNotNil(box, "Native compressed tab surface must be available")
            if diagnoseSwitchers {
                print("RINA_SWITCHER_BEFORE selected=\(selected) box=\(String(describing: box?.frame)) " + app.debugDescription)
                fflush(stdout)
            }
            box!.element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            _ = waitForSnapshot(app, timeout: 10,
                                message: "Native switcher must finish expanding before choosing a tab") { state in
                self.tabs.allSatisfy { name in
                    guard let button = self.tabSnapshot(state, name) else { return false }
                    let f = button.frame
                    return !f.isEmpty && f.minY >= window.minY - 2 && f.maxY <= window.maxY + 2
                        && self.tabButton(app, name).isHittable
                }
            }
            if diagnoseSwitchers { print("RINA_SWITCHER_AX " + app.debugDescription); fflush(stdout) }
        }
        let direct = tabButton(app, tab)
        XCTAssertTrue(direct.waitForExistence(timeout: 5))
        direct.tap()
        selected = tab
        let state = waitForSnapshot(app, timeout: 5, message: "Actual page must be " + tab) { self.actualSelection($0) }
        XCTAssertNotNil(state.first(.button, identifier: "controlCenter.toolbar.mode"))
        return state
    }

    // The first tab's English title changed from Faces to Expressions.
    // Match both app versions while checking the same observed page content.
    private func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let names = name == "Expressions" ? ["Expressions", "Faces"] : [name]
        return app.buttons.matching(NSPredicate(format: "label IN %@", names)).firstMatch
    }

    private func tabSnapshot(_ state: MenuSnapshot, _ name: String) -> (any XCUIElementSnapshot)? {
        state.first(.button, label: name) ?? (name == "Expressions" ? state.first(.button, label: "Faces") : nil)
    }

    private func actualSelection(_ state: MenuSnapshot) -> Bool {
        // Page content remains reliable while native compressed tab children
        // retain their uncompressed accessibility frames/selection traits.
        switch selected {
        case "Expressions": return state.first(.staticText, label: "Left eye") != nil
        case "Text": return state.first(.textView, label: "Scrolling text content") != nil
        case "Speak":
            return state.first(labelPrefix: "Lip sync preview") != nil
        case "Live":
            return state.first(labelPrefix: "Performance preview") != nil || state.first(labelPrefix: "Video preview") != nil
        case "Settings":
            return state.first(.collectionView, identifier: "settings.sidebar") != nil
                || state.first(identifierPrefix: "settings.detail.") != nil
                || state.first(.button, label: "App") != nil
        default: return false
        }
    }

    @discardableResult
    private func rotate(_ app: XCUIApplication, to direction: UIDeviceOrientation, folded: Bool) -> MenuSnapshot {
        let index = orientations.firstIndex(of: direction)!
        physicalPose(hinge: currentHinge, direction: index)
        lastDirection = index
        let portrait = folded || direction == .portrait || direction == .portraitUpsideDown
        return waitForSnapshot(app, timeout: 10, message: "Physical display must finish rotating") { state in
            let frame = state.window
            return portrait ? frame.height > frame.width : frame.width > frame.height
        }
    }

    private func physicalPose(hinge: String, direction: Int) {
        if ProcessInfo.processInfo.environment["RINA_STRESS_XCUI_ORIENTATION"] == "1", hinge != "folded" {
            // UIDevice landscape names are opposite interface-orientation names.
            let deviceDirections: [UIDeviceOrientation] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
            XCUIDevice.shared.orientation = deviceDirections[direction]
        }
        // The host still verifies the actual inner display and supplies hinge
        // changes; setting the XCTest orientation alone is not proof of pose.
        hostAction(["action": "pose", "hinge": hinge, "direction": direction,
                    "openSwitcher": expandsSwitcherForLegacyProbe && hinge != "folded" && (direction == 1 || direction == 3)])
    }

    private func hostAction(_ action: [String: Any]) {
        physicalSequence += 1
        var payload: [String: Any] = ["run": physicalRun, "seq": physicalSequence,
                                    "hinge": currentHinge, "direction": lastDirection, "tab": selected]
        payload.merge(action) { _, new in new }
        try! JSONSerialization.data(withJSONObject: payload).write(to: requestURL, options: .atomic)
        print("RINA_PHYSICAL_REQUEST path=\(requestURL.path) run=\(physicalRun) seq=\(physicalSequence) action=\(payload["action"]!) hinge=\(payload["hinge"]!) direction=\(payload["direction"]!)")
        fflush(stdout)
        let ackURL = requestURL.deletingLastPathComponent().appendingPathComponent("RinaMenuStressAck.txt")
        let expected = "\(physicalRun):\(physicalSequence)"
        let supplied = NSPredicate { _, _ in (try? String(contentsOf: ackURL)) == expected }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: supplied, object: self)], timeout: 600), .completed,
                       "Host must perform the native action before acknowledging it")
    }

    private func tap(_ app: XCUIApplication, identifier: String? = nil, label: String? = nil) {
        if ProcessInfo.processInfo.environment["RINA_STRESS_NATIVE_ACTIONS"] == "1" {
            var action: [String: Any] = ["action": "button"]
            if let identifier { action["identifier"] = identifier }
            if let label { action["label"] = label }
            hostAction(action)
        } else {
            app.buttons[identifier ?? label!].firstMatch.tap()
        }
    }

    private func finishPhysicalRun() {
        let payload: [String: Any] = ["run": physicalRun, "seq": physicalSequence, "complete": true]
        try? JSONSerialization.data(withJSONObject: payload).write(to: requestURL, options: .atomic)
    }

    private func matches(_ state: MenuSnapshot, hinge: String, direction: UIDeviceOrientation) -> Bool {
        let status = state.first(.button, identifier: "controlCenter.statusButton")
        let window = state.window
        if hinge == "folded" { return status != nil && window.height > window.width }
        guard status == nil else { return false }
        let portrait = direction == .portrait || direction == .portraitUpsideDown
        guard portrait == (window.height > window.width) else { return false }
        if selected == "Settings" {
            guard let sidebar = state.first(.collectionView, identifier: "settings.sidebar"),
                  let detail = state.first(identifierPrefix: "settings.detail.") else { return false }
            if portrait { return hinge == "half" ? detail.frame.minY >= sidebar.frame.maxY - 2 : detail.frame.minX >= sidebar.frame.maxX - 2 }
            let list = detail.elementType == .collectionView ? detail : state.descendant(of: detail, type: .collectionView)
            let right = list?.frame ?? detail.frame
            let boundary = (sidebar.frame.maxX + right.minX) / 2
            return hinge == "half" ? abs(boundary - window.midX) < 10 : abs(boundary - window.midX) > 10
        }
        guard let preview = state.first(.other, identifier: "board.workspace.preview"),
              let controls = state.first(.collectionView, identifier: "board.workspace.tabControls") else { return false }
        if portrait { return hinge == "half" ? controls.frame.minY >= preview.frame.maxY - 2 : controls.frame.minY < preview.frame.maxY / 2 }
        guard let board = state.first(.collectionView, identifier: "board.workspace.controlCenter") else { return false }
        let boundary = (board.frame.maxX + controls.frame.minX) / 2
        return hinge == "half" ? abs(boundary - window.midX) < 10 : abs(boundary - window.midX) > 10
    }

    private func assertMenu(_ state: MenuSnapshot, hinge: String, direction: UIDeviceOrientation) {
        XCTAssertTrue(actualSelection(state), "Selected tab changed across a layout transition: " + selected)
        let folded = hinge == "folded"
        let landscape = direction == .landscapeLeft || direction == .landscapeRight
        let ids = folded ? ["controlCenter.toolbar.mode", "controlCenter.toolbar.color", "controlCenter.statusButton"]
            : (landscape ? ["mode", "previous", "next"] : ["mode", "previous", "next", "color"]).map { "controlCenter.toolbar." + $0 }
        var frames: [CGRect] = []
        for id in ids {
            let button = state.first(.button, identifier: id)
            XCTAssertNotNil(button, id)
            let frame = button?.frame ?? .zero
            XCTAssertEqual(frame.width, 44, accuracy: 2, id)
            XCTAssertEqual(frame.height, 44, accuracy: 2, id)
            XCTAssertFalse(frame.isEmpty)
            frames.append(frame)
        }
        for (a,b) in zip(frames, frames.dropFirst()) {
            XCTAssertFalse(a.intersects(b), "Native controls overlap")
        }
        if folded {
            XCTAssertNil(state.first(.other, identifier: "board.workspace.preview"))
            return
        }
        XCTAssertNil(state.first(.button, identifier: "controlCenter.statusButton"))
        if landscape {
            XCTAssertNil(state.first(.button, identifier: "controlCenter.toolbar.color"))
            for name in tabs {
                let frame = tabSnapshot(state, name)?.frame ?? .zero
                XCTAssertFalse(frame.isEmpty)
                XCTAssertGreaterThanOrEqual(frame.minY, state.window.minY - 2)
                XCTAssertLessThanOrEqual(frame.maxY, state.window.maxY + 2, "Native navbar must not collapse")
                XCTAssertTrue(activeApplication.map { self.tabButton($0, name).isHittable } == true,
                              "Every native tab must remain directly tappable: " + name)
            }
        }
        XCTAssertTrue(matches(state, hinge: hinge, direction: direction), "Layout disagrees with \(hinge) and direction \(direction.rawValue) on \(selected)")
        if selected == "Settings" {
            let sidebar = state.first(.collectionView, identifier: "settings.sidebar")
            let detail = state.first(identifierPrefix: "settings.detail.")
            XCTAssertGreaterThan(sidebar?.frame.width ?? 0, 100)
            XCTAssertGreaterThan(detail?.frame.width ?? 0, 100)
            if hinge == "open" || direction == .portrait || direction == .portraitUpsideDown {
                let sidebarCell = state.descendant(of: sidebar, type: .cell)
                let detailCell = state.descendant(of: detail, type: .cell)
                XCTAssertNotNil(sidebarCell)
                XCTAssertNotNil(detailCell)
                XCTAssertEqual(sidebarCell?.frame.width ?? 0, detailCell?.frame.width ?? 0, accuracy: 2)
            }
        } else {
            let preview = state.first(.other, identifier: "board.workspace.preview")
            let board = state.first(.collectionView, identifier: "board.workspace.controlCenter")
            let tab = state.first(.collectionView, identifier: "board.workspace.tabControls")
            let previewFrame = preview?.frame ?? .zero
            let boardFrame = board?.frame ?? .zero
            let tabFrame = tab?.frame ?? .zero
            XCTAssertGreaterThan(previewFrame.width, 100)
            XCTAssertGreaterThan(boardFrame.height, 20)
            XCTAssertGreaterThan(tabFrame.width, 100)
            XCTAssertLessThanOrEqual(previewFrame.maxY, boardFrame.minY + 2)
            XCTAssertFalse(boardFrame.intersects(tabFrame.insetBy(dx: 2, dy: 2)), "Menu panes overlap")
            if hinge == "open" {
                let boardCell = state.descendant(of: board, type: .cell)
                let tabCell = state.descendant(of: tab, type: .cell)
                XCTAssertNotNil(boardCell)
                XCTAssertNotNil(tabCell)
                XCTAssertEqual(boardCell?.frame.width ?? 0, tabCell?.frame.width ?? 0, accuracy: 2)
            }
        }
    }

    private func assertStableTabGeometry(_ state: MenuSnapshot) {
        for id in ["mode", "previous", "next", "color"].map({ "controlCenter.toolbar." + $0 }) + ["controlCenter.statusButton"] {
            guard let button = state.first(.button, identifier: id) else { continue }
            let frame = button.frame
            if let baseline = toolbarFrames[id] {
                XCTAssertEqual(frame.midX, baseline.midX, accuracy: 2, id)
                XCTAssertEqual(frame.midY, baseline.midY, accuracy: 2, id)
            } else { toolbarFrames[id] = frame }
        }
        if let panel = state.first(.collectionView, identifier: "board.workspace.controlCenter") {
            if let boardPanelTop {
                XCTAssertEqual(panel.frame.minY, boardPanelTop, accuracy: 2, "Preview changes must not move the shared menu column")
            } else { boardPanelTop = panel.frame.minY }
        }
    }

    private func exerciseColor(_ app: XCUIApplication) -> MenuSnapshot {
        let before = capture(app)
        guard let initial = before.first(.button, identifier: "controlCenter.toolbar.color") else { return before }
        let original = (initial.value as? String)?.lowercased()
        let name = original == "#ff9547" ? "Riko Sakurauchi · Sakura pink" : "Chika Takami · Mikan orange"
        let expected = original == "#ff9547" ? "#ff9eac" : "#ff9547"
        let frame = initial.frame
        tap(app, identifier: "controlCenter.toolbar.color")
        let group = app.buttons["Aqours"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        tap(app, label: "Aqours")
        let preset = tabButton(app, name)
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        tap(app, label: name)
        let state = waitForSnapshot(app, timeout: 5, message: "Native color swatch must update") { state in
            (state.first(.button, identifier: "controlCenter.toolbar.color")?.value as? String)?.lowercased() == expected
        }
        let changedFrame = state.first(.button, identifier: "controlCenter.toolbar.color")?.frame ?? .zero
        XCTAssertEqual(changedFrame.midX, frame.midX, accuracy: 2)
        XCTAssertEqual(changedFrame.midY, frame.midY, accuracy: 2)
        return state
    }

    private func exerciseControlCenter(_ app: XCUIApplication) -> MenuSnapshot {
        tap(app, identifier: "controlCenter.statusButton")
        let opened = waitForSnapshot(app, timeout: 5, message: "Folded Control Center must open") { state in
            state.first(.other, identifier: "controlCenter.popup") != nil
        }
        let popupFrame = opened.first(.other, identifier: "controlCenter.popup")?.frame ?? .zero
        let statusFrame = opened.first(.button, identifier: "controlCenter.statusButton")?.frame ?? .zero
        if statusFrame.midX > opened.window.midX {
            XCTAssertLessThanOrEqual(popupFrame.maxX, statusFrame.minX)
        } else {
            XCTAssertGreaterThanOrEqual(popupFrame.minX, statusFrame.maxX)
        }
        tap(app, label: "Done")
        return waitForSnapshot(app, timeout: 5, message: "Folded Control Center must close") { state in
            state.first(.other, identifier: "controlCenter.popup") == nil
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "menu-stress-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Euler walk visits every ordered pair exactly once, without redundant
    /// source-tab taps. The final vertex returns to the initial vertex.
    private func edgeWalk(_ count: Int) -> [Int] {
        var edges = (0..<count).map { from in (0..<count).filter { $0 != from } }
        var stack = [0]
        var path: [Int] = []
        while let vertex = stack.last {
            if let next = edges[vertex].popLast() { stack.append(next) }
            else { path.append(stack.removeLast()) }
        }
        return path.reversed()
    }
}
