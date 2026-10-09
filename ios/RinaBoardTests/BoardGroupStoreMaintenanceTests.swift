import Foundation
import XCTest
@testable import RinaBoard

@MainActor
final class BoardGroupStoreMaintenanceTests: XCTestCase {
    private func freshStore() -> (BoardGroupStore, UserDefaults, String) {
        let suiteName = "BoardGroupStoreMaintenanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (BoardGroupStore(defaults: defaults), defaults, suiteName)
    }

    func testRemoveMemberFromEveryGroupKeepsGapInvariant() throws {
        let (store, defaults, suiteName) = freshStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = store.create(name: "第一组")
        let second = store.create(name: "第二组")
        for groupID in [first.id, second.id] {
            try store.addMember(groupID: groupID, member: .init(physicalBoardID: "A", displayName: "A"))
            try store.addMember(groupID: groupID, member: .init(physicalBoardID: "B", displayName: "B"))
            try store.addMember(groupID: groupID, member: .init(physicalBoardID: "C", displayName: "C"))
        }
        try store.setGap(groupID: first.id, afterSlot: 0, columns: 2)
        try store.setGap(groupID: first.id, afterSlot: 1, columns: 4)

        store.removeMember(physicalBoardID: "B")

        for group in store.groups {
            XCTAssertEqual(group.members.map(\.physicalBoardID), ["A", "C"])
            XCTAssertEqual(group.gapsAfter.count, group.members.count - 1)
        }
        XCTAssertEqual(store.groups.first { $0.id == first.id }?.gapsAfter, [2])
    }

    func testCreateMakesDuplicateNamesUnique() {
        let (store, defaults, suiteName) = freshStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(store.create(name: "多板组").name, "多板组")
        XCTAssertEqual(store.create(name: "多板组").name, "多板组 2")
        XCTAssertEqual(store.create(name: "多板组").name, "多板组 3")
    }

    func testUpdateMemberNameUpdatesEveryMatchingMember() throws {
        let (store, defaults, suiteName) = freshStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = store.create(name: "第一组")
        let second = store.create(name: "第二组")
        try store.addMember(groupID: first.id, member: .init(physicalBoardID: "A", displayName: "旧名称"))
        try store.addMember(groupID: second.id, member: .init(physicalBoardID: "A", displayName: "另一个旧名称"))
        try store.addMember(groupID: second.id, member: .init(physicalBoardID: "B", displayName: "B"))

        store.updateMemberName(physicalBoardID: "A", name: "新名称")

        XCTAssertEqual(store.groups.flatMap(\.members).filter { $0.physicalBoardID == "A" }.map(\.displayName),
                       ["新名称", "新名称"])
        XCTAssertEqual(store.groups.flatMap(\.members).first { $0.physicalBoardID == "B" }?.displayName, "B")
    }

    func testRememberKnownBoardIDCanRefreshMemberName() throws {
        let (store, defaults, suiteName) = freshStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let group = store.create(name: "组")
        try store.addMember(groupID: group.id, member: .init(physicalBoardID: "A", displayName: "旧名称"))

        store.rememberKnownBoardID("known-A", forPhysicalBoardID: "A", name: "新名称")

        XCTAssertEqual(store.groups[0].members[0].knownBoardIDs, ["known-A"])
        XCTAssertEqual(store.groups[0].members[0].displayName, "新名称")
    }
}
