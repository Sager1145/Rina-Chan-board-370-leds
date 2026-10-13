import XCTest
#if os(macOS)
import AppKit
import ApplicationServices
#endif

/// Opt in with TEST_RUNNER_RINA_GROUP_DRAG_HARDWARE=1 when invoking xcodebuild.
/// The operator must leave the existing "Rina Drag Test" two-board group selected
/// on the Text page. This test activates the running app; it never launches with
/// fixture arguments, changes defaults, creates groups, or handles system alerts.
@MainActor
final class GroupDragHardwareUITests: XCTestCase {
    private let leftName = "RinaBoard-80B54EF74801"
    private let rightName = "RinaBoard-80B54EF48E09"
    private var app: XCUIApplication!

    func testHeldDragSlidesNeighbourAndRestoresOrder() throws {
        try prepare()
        #if os(macOS)
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Native AX observer lacks Accessibility permission; grant it manually before rerunning. No permission dialog is automated.")
        }
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.rinachan.board.mac").first)
        let initialLeft = try cell(named: leftName)
        let initialRight = try cell(named: rightName)
        XCTAssertLessThan(initialLeft.frame.midX, initialRight.frame.midX,
                          "Prepare the existing test group in B then A order before running.")
        let paused60 = ProcessInfo.processInfo.environment["RINA_GROUP_DRAG_REQUIRE_PAUSED_60"] == "1"
        if paused60 { assertPaused60() }
        attachScreen("before-forward-drag")

        try dragAndObserve(sourceName: leftName, targetName: rightName, pid: running.processIdentifier,
                           attachmentName: "forward")
        waitForOrder(left: rightName, right: leftName)
        attachScreen("after-forward-drop")
        if paused60 { assertPaused60() }

        try dragAndObserve(sourceName: leftName, targetName: rightName, pid: running.processIdentifier,
                           attachmentName: "reverse")
        waitForOrder(left: leftName, right: rightName)
        attachScreen("after-reverse-drop-original-order-restored")
        if paused60 { assertPaused60() }

        // Holding and releasing at the same point is the valid no-move path.
        let point = try cell(named: leftName).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        point.click(forDuration: 0.4, thenDragTo: point, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForOrder(left: leftName, right: rightName)
        attachScreen("long-press-no-move-order-unchanged")

        // Moving more than the long-press tolerance before activation cancels
        // the long-press sequence. This does not claim OS cancellation after a
        // live reorder; the public synchronous gesture API cannot inject that.
        let cancelStart = try cell(named: leftName).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let cancelEnd = cancelStart.withOffset(CGVector(dx: 35, dy: 0))
        cancelStart.click(forDuration: 0.01, thenDragTo: cancelEnd, withVelocity: .fast, thenHoldForDuration: 0)
        waitForOrder(left: leftName, right: rightName)
        attachScreen("cancel-before-long-press-activation-order-unchanged")
        if paused60 { assertPaused60() }
        #else
        throw XCTSkip("This focused physical-board observer requires the native macOS runner.")
        #endif
    }

    private func prepare() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["RINA_GROUP_DRAG_HARDWARE"] == "1" else {
            throw XCTSkip("Opt-in physical-board test: set TEST_RUNNER_RINA_GROUP_DRAG_HARDWARE=1.")
        }
        app = XCUIApplication(bundleIdentifier: "com.rinachan.board.mac")
        guard app.state != .notRunning else {
            throw XCTSkip("Prepare the running real app and select Rina Drag Test before running; the test does not reset or launch it.")
        }
        app.activate()
        let textTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Text", "文字滚动")).firstMatch
        if textTab.exists && textTab.isHittable {
            #if os(macOS)
            textTab.click()
            #else
            textTab.tap()
            #endif
        }
        // The operator's explicit precondition is necessary because the target
        // menu lives on another page. Do not silently select a different group.
        guard ProcessInfo.processInfo.environment["RINA_GROUP_DRAG_GROUP_SELECTED"] == "Rina Drag Test" else {
            throw XCTSkip("Confirm the existing Rina Drag Test target, then set TEST_RUNNER_RINA_GROUP_DRAG_GROUP_SELECTED='Rina Drag Test'.")
        }
        _ = try cell(named: leftName)
        _ = try cell(named: rightName)
        XCTAssertEqual(previewCells.count, 2, "Expected exactly the two physical board previews, not an editor list.")
    }

    private var previewCells: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label MATCHES %@", "^(Board|板)\\s*[12][,，].*RinaBoard-.*"))
    }

    private func cell(named name: String) throws -> XCUIElement {
        let element = previewCells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Physical preview missing: \(name)")
        XCTAssertTrue(element.isHittable, "Physical preview is not hittable: \(name)")
        return element
    }

    private func waitForOrder(left: String, right: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let a = previewCells.matching(NSPredicate(format: "label CONTAINS %@", left)).firstMatch
            let b = previewCells.matching(NSPredicate(format: "label CONTAINS %@", right)).firstMatch
            return a.exists && b.exists && a.isEnabled && b.isEnabled && a.frame.midX < b.frame.midX
                && (a.label.hasPrefix("Board 1,") || a.label.hasPrefix("板 1，"))
                && (b.label.hasPrefix("Board 2,") || b.label.hasPrefix("板 2，"))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       "Committed preview order did not become \(left), \(right).")
    }

    private func assertPaused60() {
        // Native macOS exposes LabeledContent as a combined AX label or as
        // separate label/value attributes, depending on the current host.
        let paused = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR (label CONTAINS %@ AND value == %@)",
            "Status, Paused", "Status", "Paused")).firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 10), "Group did not remain paused after reorder.")
        let requested = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR (label CONTAINS %@ AND value == %@)",
            "Requested speed, 60 fps", "Requested speed", "60 fps")).firstMatch
        let configured = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR (label CONTAINS %@ AND value == %@)",
            "Configured board FPS, 60 fps", "Configured board FPS", "60 fps")).firstMatch
        XCTAssertTrue(requested.waitForExistence(timeout: 10), "Displayed requested FPS did not remain 60.")
        XCTAssertTrue(configured.waitForExistence(timeout: 10), "Displayed configured board FPS did not remain 60.")
        // Physical firmware state/timeline continuity needs the separate serial
        // or protocol oracle; these assertions deliberately cover visible UI only.
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    #if os(macOS)
    private func dragAndObserve(sourceName: String, targetName: String, pid: pid_t,
                                attachmentName: String) throws {
        let source = try cell(named: sourceName)
        let target = try cell(named: targetName)
        let targetInitialX = target.frame.midX
        // Freeze coordinates against the app window. Element-relative target
        // coordinates would move when the neighbour slides under this gesture.
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: source.frame.midX - window.frame.minX,
                                              dy: source.frame.minY + source.frame.height * 0.35 - window.frame.minY))
        let to = origin.withOffset(CGVector(dx: target.frame.midX - window.frame.minX,
                                            dy: target.frame.minY + target.frame.height * 0.35 - window.frame.minY))
        let observer = DragAXObserver(pid: pid, boardName: targetName)
        observer.start()
        defer { observer.stop() }
        from.click(forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 2)
        observer.stop()
        let samples = observer.samples
        let evidence = samples.map { sample in
            let label = sample.description.replacingOccurrences(of: "\"", with: "\"\"")
            return "\(sample.time),\(sample.mouseDown),\(sample.midX),\"\(label)\""
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: "time,mouseDown,targetMidX,description\n" + evidence)
        attachment.name = "\(attachmentName)-neighbour-during-native-gesture.csv"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(samples.contains { $0.mouseDown && abs($0.midX - targetInitialX) > 20 },
                      "No neighbour displacement observed while the mouse remained pressed. Final order alone cannot prove live movement.")

    }
    #endif
}

#if os(macOS)
/// Reads only this application's native AX tree. It does not send input,
/// automate system dialogs, or change application state.
private final class DragAXObserver: @unchecked Sendable {
    struct Sample {
        let time: TimeInterval
        let mouseDown: Bool
        let midX: CGFloat
        let description: String
    }
    private let pid: pid_t
    private let boardName: String
    private let lock = NSLock()
    private var stopped = false
    private var recorded: [Sample] = []
    private let queue = DispatchQueue(label: "rina.drag.ax-observer")

    init(pid: pid_t, boardName: String) { self.pid = pid; self.boardName = boardName }
    var samples: [Sample] { lock.lock(); defer { lock.unlock() }; return recorded }

    func start() {
        queue.async { [self] in
            let application = AXUIElementCreateApplication(pid)
            while !isStopped {
                if let (label, midX) = findBoard(in: application, depth: 0) {
                    let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    let sample = Sample(time: ProcessInfo.processInfo.systemUptime,
                                        mouseDown: down, midX: midX, description: label)
                    lock.lock(); recorded.append(sample); lock.unlock()

                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() { lock.lock(); stopped = true; lock.unlock(); queue.sync {} }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func attribute(_ key: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        return value
    }

    private func findBoard(in element: AXUIElement, depth: Int) -> (String, CGFloat)? {
        guard depth < 20 else { return nil }
        let label = attribute(kAXDescriptionAttribute as CFString, from: element) as? String ?? ""
        if (label.hasPrefix("Board ") || label.hasPrefix("板 ")), label.contains(boardName),
           let position = attribute(kAXPositionAttribute as CFString, from: element),
           let size = attribute(kAXSizeAttribute as CFString, from: element),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &point),
               AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
                return (label, point.x + dimensions.width / 2)
            }
        }
        let children = attribute(kAXChildrenAttribute as CFString, from: element) as? [AXUIElement] ?? []
        for child in children {
            if let found = findBoard(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
#endif
