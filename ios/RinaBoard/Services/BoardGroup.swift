import Foundation
import RinaCore

/// A saved multi-board layout (BOARD_GROUP_SPEC.md §3). Members are stored
/// left-to-right by `physicalBoardID` — the handshake `BoardConnection.
/// boardIdentity` — never by BLE UUID, host, or Bonjour name, so a group
/// survives a board reconnecting over a different transport.
public struct BoardGroup: Codable, Equatable, Identifiable, Sendable {
    /// One member's saved slot. `displayName` is a snapshot for display while
    /// the board is offline; a connected board's live name always wins.
    public struct Member: Codable, Equatable, Sendable {
        public var physicalBoardID: String
        public var displayName: String

        public init(physicalBoardID: String, displayName: String) {
            self.physicalBoardID = physicalBoardID
            self.displayName = displayName
        }
    }

    public enum Mode: String, Codable, Sendable {
        case stitched, mirror
    }

    public var id: UUID
    public var name: String
    /// Ordered left→right.
    public var members: [Member]
    /// Gap (virtual columns) after member `i`, for `i` in `0..<members.count-1`.
    public var gapsAfter: [Int]
    public var mode: Mode
    /// Bumped on any change to `members`/`gapsAfter`/`mode` order or shape
    /// (BOARD_GROUP_SPEC §3) — a running `BoardGroupCoordinator.play` aborts
    /// rather than write to a group whose layout moved under it.
    public var layoutRevision: Int

    public init(id: UUID = UUID(), name: String, members: [Member] = [], gapsAfter: [Int] = [],
                mode: Mode = .stitched, layoutRevision: Int = 0) {
        self.id = id
        self.name = name
        self.members = members
        self.gapsAfter = gapsAfter
        self.mode = mode
        self.layoutRevision = layoutRevision
    }

    public static let maxMembers = 5
    public static let minMembersToPlay = 2
    public static let maxGap = 8

    /// The `StitchedScreenLayout` this group's current members/gaps describe,
    /// or `nil` when `members` is empty (no layout to build).
    public var stitchedLayout: StitchedScreenLayout? {
        guard !members.isEmpty else { return nil }
        return try? StitchedScreenLayout(slotCount: members.count, gapsAfter: gapsAfter)
    }
}

/// Persists `BoardGroup`s as one JSON array in `UserDefaults` (matching
/// `BoardStore`'s whole-document-replace shape). Decode failure keeps the
/// existing in-memory list (and the persisted key) untouched rather than
/// silently discarding saved groups.
@Observable
@MainActor
public final class BoardGroupStore {
    private static let defaultsKey = "com.rinachan.board.groups"

    public private(set) var groups: [BoardGroup] = []

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([BoardGroup].self, from: data) else { return }
        groups = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public enum GroupError: Error, Sendable, Equatable {
        case tooManyMembers
        case duplicateMember
        case notFound
        case invalidGapCount
        case invalidGap(Int)
    }

    @discardableResult
    public func create(name: String) -> BoardGroup {
        let group = BoardGroup(name: name)
        groups.append(group)
        persist()
        return group
    }

    public func remove(id: UUID) {
        groups.removeAll { $0.id == id }
        persist()
    }

    public func rename(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
        persist()
    }

    public func setMode(id: UUID, mode: BoardGroup.Mode) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].mode = mode
        persist()
    }

    /// Appends a member at the end. Rejects a duplicate `physicalBoardID`
    /// (a board may appear at most once in a group) or a sixth member.
    public func addMember(groupID: UUID, member: BoardGroup.Member) throws {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { throw GroupError.notFound }
        var group = groups[index]
        guard group.members.count < BoardGroup.maxMembers else { throw GroupError.tooManyMembers }
        guard !group.members.contains(where: { $0.physicalBoardID == member.physicalBoardID }) else {
            throw GroupError.duplicateMember
        }
        group.members.append(member)
        if group.members.count > 1 { group.gapsAfter.append(0) }
        group.layoutRevision += 1
        groups[index] = group
        persist()
    }

    public func removeMember(groupID: UUID, physicalBoardID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = groups[index]
        guard let memberIndex = group.members.firstIndex(where: { $0.physicalBoardID == physicalBoardID }) else { return }
        group.members.remove(at: memberIndex)
        if !group.gapsAfter.isEmpty {
            group.gapsAfter.remove(at: min(memberIndex, group.gapsAfter.count - 1))
        }
        group.layoutRevision += 1
        groups[index] = group
        persist()
    }

    /// Moves the member at `from` to `to` (both valid indices into `members`).
    public func moveMember(groupID: UUID, from: Int, to: Int) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = groups[index]
        guard group.members.indices.contains(from), (0..<group.members.count).contains(to) else { return }
        let member = group.members.remove(at: from)
        group.members.insert(member, at: to)
        // Gaps describe the space after each slot; keep the count consistent
        // with the new member count/order (a reorder does not by itself
        // change how many gaps exist, only what sits at slot 0..<n-1).
        let expectedGapCount = max(0, group.members.count - 1)
        if group.gapsAfter.count > expectedGapCount {
            group.gapsAfter.removeLast(group.gapsAfter.count - expectedGapCount)
        } else if group.gapsAfter.count < expectedGapCount {
            group.gapsAfter.append(contentsOf: repeatElement(0, count: expectedGapCount - group.gapsAfter.count))
        }
        group.layoutRevision += 1
        groups[index] = group
        persist()
    }

    /// Sets the gap (virtual columns, `0...8`) after member `slot`.
    public func setGap(groupID: UUID, afterSlot slot: Int, columns: Int) throws {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { throw GroupError.notFound }
        var group = groups[index]
        guard group.gapsAfter.indices.contains(slot) else { throw GroupError.invalidGapCount }
        guard (0...BoardGroup.maxGap).contains(columns) else { throw GroupError.invalidGap(columns) }
        group.gapsAfter[slot] = columns
        group.layoutRevision += 1
        groups[index] = group
        persist()
    }
}
