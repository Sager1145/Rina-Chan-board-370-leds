import Foundation
import XCTest

/// Waits until `condition` holds, polling against a wall-clock deadline, and
/// fails the test if it never does.
///
/// `await Task.yield()` only offers the current task's turn back to the
/// scheduler once; it is *not* a guarantee that some other consumer task ran,
/// and it advances no wall-clock time at all. Tests that emit an event, yield,
/// and then assert on the published result are therefore flaky whenever the
/// machine is loaded (this Mac routinely runs several simulators and builds at
/// once, which starves main-actor work). Wait on the condition the assertion
/// actually depends on instead of on scheduling.
///
/// This only applies to *positive* waits — "X must become true". A yield used
/// before a negative assertion ("this late reply must be ignored") is a settle
/// window, not a wait, and cannot be replaced by polling.
@MainActor
func waitUntilTrue(
    _ message: String = "Condition never became true",
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(condition(), message, file: file, line: line)
}
