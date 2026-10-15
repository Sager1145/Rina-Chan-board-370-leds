import XCTest

#if targetEnvironment(simulator)
@MainActor
final class GroupPreviewSimulatorUITests: XCTestCase {
    private let physicalRun = UUID().uuidString
    private var physicalSequence = 0
    private var keepsPhysicalRunOpen = false
    private var physicalRequestURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RinaMenuStressRequest.json")
    }

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

    func testFastReleasePreservesMultiBoardOrderAndPreviewBounds() throws {
        try checkGroups([("Test · 3 mirrors", 3, true)], immediateRelease: true)
    }

    func testFastReleaseOfIdleGroupPreservesOrderAndPreviewBounds() throws {
        try checkGroups([("Test · 3 boards", 3, false)], immediateRelease: true, plays: false)
    }

    func testFastReleaseWithFiveBoardPreview() throws {
        try checkGroups([("Test · 5 boards", 5, true)], immediateRelease: true)
    }

    func testFastReleaseAcrossEveryDuoPose() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] == "all", "Opt-in physical Duo drag matrix")
        keepsPhysicalRunOpen = true
        defer { keepsPhysicalRunOpen = false; finishPhysicalRun() }
        var poses = [("open", 0), ("half", 0), ("folded", 0), ("open", 1), ("half", 1),
                     ("open", 2), ("half", 2), ("open", 3), ("half", 3)]
        if ProcessInfo.processInfo.environment["RINA_GROUP_DROP_SKIP_OPEN_PORTRAIT"] == "1" {
            poses.removeFirst()
            print("RINA_GROUP_DROP_SKIPPED openPortraitPreviouslyVerified=true")
        }
        if let start = ProcessInfo.processInfo.environment["RINA_GROUP_DROP_START_INDEX"].flatMap(Int.init) {
            poses = Array(poses.dropFirst(start))
            print("RINA_GROUP_DROP_SKIPPED previouslyVerifiedPoses=\(start)")
        }
        for pose in poses {
            try checkGroups([("Test · 5 boards", 5, true)],
                            landscape: pose.1 == 1 || pose.1 == 3,
                            immediateRelease: true, pose: pose)
            print("RINA_GROUP_DROP_POSE_PASS hinge=\(pose.0) direction=\(pose.1)")
            fflush(stdout)
        }
        print("RINA_GROUP_DROP_RESULT poseCount=\(poses.count) PASS")
        fflush(stdout)
    }

    private func checkGroups(_ configurations: [(String, Int, Bool)], landscape: Bool = false, immediateRelease: Bool = false, plays: Bool = true, pose: (String, Int)? = nil) throws {
        continueAfterFailure = false
        for (name, count, paused) in configurations {
            let app = XCUIApplication()
            app.launchArguments = ["-initialTab", "text", "-disableStarAnimation", "YES",
                "-seedTestGroups", "YES", "-connectTestBoards", "YES", "-testBoardPort", "15370",
                "-testGroupName", name, "-playTestGroup", plays ? "YES" : "NO", "-pauseTestGroup", paused ? "YES" : "NO"]
            app.launch()
            defer { app.terminate() }
            if let pose {
                providePhysicalPose(hinge: pose.0, direction: pose.1)
            } else if let hinge = ProcessInfo.processInfo.environment["RINA_STRESS_HINGE"] {
                let direction = Int(ProcessInfo.processInfo.environment["RINA_STRESS_START_DIRECTION"] ?? "0") ?? 0
                providePhysicalPose(hinge: hinge, direction: direction)
            }
            let cells = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "group.preview.member."))
            let ready = NSPredicate { _, _ in
                let previews = cells.allElementsBoundByIndex
                return previews.count == count && previews.allSatisfy {
                    plays ? ($0.label.contains("Playing") || $0.label.contains("播放中") || $0.label.contains("Ready") || $0.label.contains("就绪"))
                        : !($0.label.contains("Offline") || $0.label.contains("离线"))
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
            assertPreview(cells, playing: plays)
            if name.contains("mirrors") {
                let values = cells.allElementsBoundByIndex.compactMap { $0.value as? String }
                XCTAssertEqual(Set(values).count, 1, "Mirror members must display the same held LED frame")
            }
            attach(app, "\(name)-before")
            // A narrow row cannot drop onto a fully offscreen slot. Use the
            // furthest visible board, while still verifying all member IDs.
            let visible = scroller.exists ? initial.filter {
                $0.frame.midX >= scroller.frame.minX + 8 && $0.frame.midX <= scroller.frame.maxX - 8
            } : initial
            let forwardTargetID = visible.last?.identifier ?? lastID
            let destination = try XCTUnwrap(initialIDs.firstIndex(of: forwardTargetID))
            XCTAssertGreaterThan(destination, 0)
            var forwardOrder = Array(initialIDs.dropFirst())
            forwardOrder.insert(firstID, at: destination)
            drag(app, source: firstID, target: forwardTargetID, immediateRelease: immediateRelease)
            waitForOrder(cells, expected: forwardOrder)
            assertPreview(cells, playing: plays)
            attach(app, "\(name)-forward")
            drag(app, source: firstID, target: initialIDs[1], immediateRelease: immediateRelease)
            waitForOrder(cells, expected: initialIDs)
            assertPreview(cells, playing: plays)
            attach(app, "\(name)-restored")
            // Hold/release in place must not change membership or playback.
            revealSource(app, identifier: firstID)
            let point = app.descendants(matching: .any)[firstID].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            point.press(forDuration: 0.4, thenDragTo: point)
            waitForOrder(cells, expected: initialIDs)
            assertPreview(cells, playing: plays)
            app.terminate()
        }
    }

    private func providePhysicalPose(hinge: String, direction: Int) {
        physicalSequence += 1
        let sequence = physicalSequence
        let path = physicalRequestURL
        let payload: [String: Any] = ["run": physicalRun, "seq": sequence, "action": "pose", "hinge": hinge,
                                     "direction": direction, "tab": "Text"]
        try! JSONSerialization.data(withJSONObject: payload).write(to: path, options: .atomic)
        print("RINA_PHYSICAL_REQUEST path=\(path.path) run=\(physicalRun) seq=\(sequence) action=pose hinge=\(hinge) direction=\(direction)")
        fflush(stdout)
        defer { if !keepsPhysicalRunOpen { finishPhysicalRun() } }
        let ack = path.deletingLastPathComponent().appendingPathComponent("RinaMenuStressAck.txt")
        let expected = "\(physicalRun):\(sequence)"
        let supplied = NSPredicate { _, _ in (try? String(contentsOf: ack)) == expected }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: supplied, object: self)], timeout: 600), .completed)
    }

    private func finishPhysicalRun() {
        guard physicalSequence > 0 else { return }
        try? JSONSerialization.data(withJSONObject: ["run": physicalRun, "seq": physicalSequence, "complete": true])
            .write(to: physicalRequestURL, options: .atomic)
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

    private func drag(_ app: XCUIApplication, source: String, target: String, immediateRelease: Bool = false) {
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
        let previewCells = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "group.preview.member."))
        let rowBounds = previewCells.allElementsBoundByIndex.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        start.press(forDuration: 0.4, thenDragTo: end,
                    withVelocity: immediateRelease ? .fast : .slow,
                    thenHoldForDuration: immediateRelease ? 0 : 0.4)
        if immediateRelease {
            for _ in 0..<8 {
                for cell in previewCells.allElementsBoundByIndex {
                    XCTAssertTrue(rowBounds.insetBy(dx: -8, dy: -8).contains(cell.frame),
                                  "Released board escaped its preview row: \(cell.identifier), \(cell.frame)")
                }
            }
        }
    }

    private func waitForOrder(_ cells: XCUIElementQuery, expected: [String]) {
        let ordered = NSPredicate { _, _ in
            cells.allElementsBoundByIndex.sorted { $0.frame.midX < $1.frame.midX }.map(\.identifier) == expected
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ordered, object: nil)], timeout: 15), .completed)
    }

    private func assertPreview(_ cells: XCUIElementQuery, playing: Bool) {
        if !playing {
            XCTAssertTrue(cells.allElementsBoundByIndex.allSatisfy { ($0.value as? String)?.hasPrefix("0 /") == true },
                          "Idle members must retain their dark preview after reordering")
            return
        }
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
