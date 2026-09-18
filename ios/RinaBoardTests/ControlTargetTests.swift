import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// `ControlTarget`'s parse/persist/validate helpers (BOARD_GROUP_SPEC.md
/// §3's "控制对象" menu): empty storage means `.single`, a stored group id
/// that no longer exists in `BoardGroupStore` reads back — and resets — as
/// `.single`.
@MainActor
final class ControlTargetTests: XCTestCase {
    private func freshStore() -> (BoardGroupStore, UserDefaults, String) {
        let suiteName = "ControlTargetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (BoardGroupStore(defaults: defaults), defaults, suiteName)
    }

    func testEmptyStringIsSingle() {
        XCTAssertEqual(ControlTarget(storedGroupIDString: ""), .single)
        XCTAssertEqual(ControlTarget.single.storedGroupIDString, "")
    }

    func testGarbageStringIsSingle() {
        XCTAssertEqual(ControlTarget(storedGroupIDString: "not-a-uuid"), .single)
    }

    func testValidUUIDStringRoundTrips() {
        let id = UUID()
        let target = ControlTarget(storedGroupIDString: id.uuidString)
        XCTAssertEqual(target, .group(id))
        XCTAssertEqual(target.storedGroupIDString, id.uuidString)
    }

    func testResolvedTreatsExistingGroupAsGroup() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let group = store.create(name: "客厅拼接屏")

        let resolved = ControlTarget.resolved(storedGroupIDString: group.id.uuidString, in: store)
        XCTAssertEqual(resolved, .group(group.id))
    }

    func testResolvedTreatsMissingGroupAsSingle() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let resolved = ControlTarget.resolved(storedGroupIDString: UUID().uuidString, in: store)
        XCTAssertEqual(resolved, .single)
    }

    func testValidateResetsStaleGroupID() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = UUID().uuidString

        ControlTarget.validate(&stored, in: store)

        XCTAssertEqual(stored, "")
    }

    func testValidateLeavesExistingGroupIDAlone() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let group = store.create(name: "客厅拼接屏")
        var stored = group.id.uuidString

        ControlTarget.validate(&stored, in: store)

        XCTAssertEqual(stored, group.id.uuidString)
    }

    func testValidateLeavesSingleAlone() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = ""

        ControlTarget.validate(&stored, in: store)

        XCTAssertEqual(stored, "")
    }

    func testValidateResetsAfterGroupIsDeleted() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let group = store.create(name: "客厅拼接屏")
        var stored = group.id.uuidString
        store.remove(id: group.id)

        ControlTarget.validate(&stored, in: store)

        XCTAssertEqual(stored, "")
    }
}
