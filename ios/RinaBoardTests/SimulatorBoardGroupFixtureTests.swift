#if targetEnvironment(simulator)
import XCTest
@testable import RinaBoard

@MainActor
final class SimulatorBoardGroupFixtureTests: XCTestCase {
    func testCreatesDifferentSizesAndModesWithEmulatorIdentities() throws {
        let suite = "SimulatorBoardGroupFixtureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        SimulatorBoardGroupFixtures.seed(in: store)
        XCTAssertEqual(store.groups.map(\.members.count), [2, 3, 5, 3])
        XCTAssertEqual(store.groups.map(\.mode), [.stitched, .stitched, .stitched, .mirror])
        for group in store.groups {
            XCTAssertEqual(Set(group.members.map(\.physicalBoardID)).count, group.members.count)
            XCTAssertTrue(group.members.allSatisfy { $0.physicalBoardID == "EMU-\($0.knownBoardIDs[0])" })
        }
    }

    func testReseedingPreservesExistingGroupsAndReorderedFixtures() throws {
        let suite = "SimulatorBoardGroupFixtureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardGroupStore(defaults: defaults)
        let existing = store.create(name: "Existing user group")
        SimulatorBoardGroupFixtures.seed(in: store)
        let group = try XCTUnwrap(store.groups.first { $0.name == "Test · 3 boards" })
        store.moveMember(groupID: group.id, from: 0, to: 2)
        let expected = store.groups
        SimulatorBoardGroupFixtures.seed(in: store)
        XCTAssertEqual(store.groups, expected)
        XCTAssertEqual(store.groups.first?.id, existing.id)
    }
}
#endif
