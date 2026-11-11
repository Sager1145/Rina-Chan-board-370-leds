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
        /// `KnownBoard.id` values (BLE UUID/host/Bonjour storage id) ever seen
        /// carrying this member's `physicalBoardID`, so `GroupAutoConnector`
        /// can dial this board directly instead of only reconnecting whichever
        /// one the user happens to have connected manually (user bug: "多板组
        /// 同步功能没有生效" — the fan-out never connected anyone). Filled when
        /// a member is added (`BoardGroupEditorView`) and refreshed whenever a
        /// session with this `physicalBoardID` connects. Defaults to `[]` so
        /// JSON written before this field existed still decodes.
        public var knownBoardIDs: [String]

        public init(physicalBoardID: String, displayName: String, knownBoardIDs: [String] = []) {
            self.physicalBoardID = physicalBoardID
            self.displayName = displayName
            self.knownBoardIDs = knownBoardIDs
        }

        private enum CodingKeys: String, CodingKey {
            case physicalBoardID, displayName, knownBoardIDs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            physicalBoardID = try container.decode(String.self, forKey: .physicalBoardID)
            displayName = try container.decode(String.self, forKey: .displayName)
            knownBoardIDs = try container.decodeIfPresent([String].self, forKey: .knownBoardIDs) ?? []
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

    // MARK: - Played layout

    /// The slice of the group bitmap each board was last uploaded, and for
    /// which timeline. `GET_SCROLL_META` reports neither `viewportX` nor
    /// `virtualWidth`, so after a relaunch this record is the only evidence
    /// of what the boards are showing: `BoardGroupCoordinator` takes a
    /// running scroll over without re-uploading only while the group's
    /// current layout still gives every member the viewport recorded here.
    public struct PlayedLayout: Codable, Equatable, Sendable {
        public var timelineId: String
        public var virtualWidth: Int
        /// `viewportX` by `physicalBoardID`.
        public var viewportXs: [String: Int]

        public init(timelineId: String, virtualWidth: Int, viewportXs: [String: Int]) {
            self.timelineId = timelineId
            self.virtualWidth = virtualWidth
            self.viewportXs = viewportXs
        }
    }

    private static let playedLayoutsKey = "com.rinachan.board.groups.playedLayouts"

    private func loadPlayedLayouts() -> [String: PlayedLayout] {
        guard let data = defaults.data(forKey: Self.playedLayoutsKey),
              let decoded = try? JSONDecoder().decode([String: PlayedLayout].self, from: data) else { return [:] }
        return decoded
    }

    /// The layout `groupID`'s boards were last uploaded, or `nil` if none was
    /// ever recorded. Kept apart from `groups` so recording it neither bumps
    /// `layoutRevision` nor invalidates views observing the group list.
    public func playedLayout(groupID: UUID) -> PlayedLayout? {
        loadPlayedLayouts()[groupID.uuidString]
    }

    /// Records what a successful group start uploaded. Entries of groups that
    /// no longer exist are dropped on the way.
    public func recordPlayedLayout(_ layout: PlayedLayout, groupID: UUID) {
        let liveIDs = Set(groups.map(\.id.uuidString))
        var all = loadPlayedLayouts().filter { liveIDs.contains($0.key) }
        all[groupID.uuidString] = layout
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.playedLayoutsKey)
    }

    public enum GroupError: Error, Sendable, Equatable {
        case tooManyMembers
        case duplicateMember
        case notFound
        case invalidGapCount
        case invalidGap(Int)
    }

    /// `GroupError`'s user-facing text; see the `LocalizedError` extension below.
    nonisolated static func message(for error: GroupError) -> String {
        switch error {
        case .tooManyMembers:
            return String(
                format: NSLocalizedString("多板组最多只能有 %lld 块板", comment: "board group error: member limit reached; argument is the limit"),
                Int64(BoardGroup.maxMembers)
            )
        case .duplicateMember:
            return NSLocalizedString("这块板已经在多板组中", comment: "board group error: board is already a member")
        case .notFound:
            return NSLocalizedString("找不到这个多板组，可能已被删除", comment: "board group error: group no longer exists")
        case .invalidGapCount:
            return NSLocalizedString("找不到要设置间隙的位置", comment: "board group error: gap slot out of range")
        case .invalidGap(let columns):
            return String(
                format: NSLocalizedString("间隙 %lld 列超出范围，必须在 0 到 %lld 列之间", comment: "board group error: gap width out of range; arguments are the requested width and the maximum"),
                Int64(columns), Int64(BoardGroup.maxGap)
            )
        }
    }

    @discardableResult
    public func create(name: String) -> BoardGroup {
        var uniqueName = name
        var suffix = 2
        while groups.contains(where: { $0.name == uniqueName }) {
            uniqueName = "\(name) \(suffix)"
            suffix += 1
        }
        let group = BoardGroup(name: uniqueName)
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
        groups[index].layoutRevision += 1
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

    /// Removes a physical board from every group that contains it. Used when
    /// the saved board itself is forgotten rather than from one group editor.
    public func removeMember(physicalBoardID: String) {
        var changed = false
        for groupIndex in groups.indices {
            guard let memberIndex = groups[groupIndex].members.firstIndex(where: {
                $0.physicalBoardID == physicalBoardID
            }) else { continue }
            groups[groupIndex].members.remove(at: memberIndex)
            if !groups[groupIndex].gapsAfter.isEmpty {
                groups[groupIndex].gapsAfter.remove(
                    at: min(memberIndex, groups[groupIndex].gapsAfter.count - 1)
                )
            }
            let expectedGapCount = max(0, groups[groupIndex].members.count - 1)
            if groups[groupIndex].gapsAfter.count > expectedGapCount {
                groups[groupIndex].gapsAfter.removeLast(
                    groups[groupIndex].gapsAfter.count - expectedGapCount
                )
            } else if groups[groupIndex].gapsAfter.count < expectedGapCount {
                groups[groupIndex].gapsAfter.append(contentsOf: repeatElement(
                    0, count: expectedGapCount - groups[groupIndex].gapsAfter.count
                ))
            }
            groups[groupIndex].layoutRevision += 1
            changed = true
        }
        if changed { persist() }
    }

    /// Refreshes the offline snapshot name everywhere this physical board is
    /// a member. A name-only change does not alter the layout revision.
    public func updateMemberName(physicalBoardID: String, name: String) {
        var changed = false
        for groupIndex in groups.indices {
            for memberIndex in groups[groupIndex].members.indices
            where groups[groupIndex].members[memberIndex].physicalBoardID == physicalBoardID
                && groups[groupIndex].members[memberIndex].displayName != name {
                groups[groupIndex].members[memberIndex].displayName = name
                changed = true
            }
        }
        if changed { persist() }
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

    /// Puts back an earlier value of an existing group verbatim, including
    /// its `layoutRevision` — used to undo a drag-swap whose replay failed,
    /// so the still-running playback keeps matching the stored revision.
    public func restore(_ group: BoardGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        persist()
    }

    /// Swaps the boards at slots `a` and `b` (drag-to-swap in the group
    /// preview). Gaps stay attached to slot positions, not to boards.
    public func swapMembers(groupID: UUID, _ a: Int, _ b: Int) {
        guard a != b, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = groups[index]
        guard group.members.indices.contains(a), group.members.indices.contains(b) else { return }
        group.members.swapAt(a, b)
        group.layoutRevision += 1
        groups[index] = group
        persist()
    }

    /// Remembers a `KnownBoard.id` (BLE UUID/host/Bonjour storage id) as one
    /// that carries `physicalBoardID`, on every member across every group
    /// that matches — called whenever a session with that identity connects
    /// (`GroupAutoConnector`/`RinaBoardApp`), so a board reconnected over a
    /// different saved record (e.g. re-paired BLE) keeps `GroupAutoConnector`
    /// able to dial it directly. A no-op (no persist) if every matching
    /// member already has it, so this can be called on every connect without
    /// spamming `UserDefaults` writes.
    public func rememberKnownBoardID(_ knownBoardID: String, forPhysicalBoardID physicalBoardID: String,
                                     name: String? = nil) {
        var changed = false
        for groupIndex in groups.indices {
            for memberIndex in groups[groupIndex].members.indices
            where groups[groupIndex].members[memberIndex].physicalBoardID == physicalBoardID {
                if !groups[groupIndex].members[memberIndex].knownBoardIDs.contains(knownBoardID) {
                    groups[groupIndex].members[memberIndex].knownBoardIDs.append(knownBoardID)
                    changed = true
                }
                if let name, !name.isEmpty,
                   groups[groupIndex].members[memberIndex].displayName != name {
                    groups[groupIndex].members[memberIndex].displayName = name
                    changed = true
                }
            }
        }
        if changed { persist() }
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

extension BoardGroupStore.GroupError: LocalizedError {
    public var errorDescription: String? { BoardGroupStore.message(for: self) }
}
