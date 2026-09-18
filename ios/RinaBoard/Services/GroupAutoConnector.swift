import Foundation
import RinaCore

/// Auto-connects every member of a targeted board group in the background
/// (user requirement: "切换到多板组时自动连接多个板子"). Root cause of "多板组同步
/// 功能没有生效": `GroupControlFanOut` only mirrors to members that are
/// *already* connected — nothing ever dialed the others, so a 2-board group
/// silently ran as if it were one board.
///
/// Connects each offline member's own `BoardSession` directly (never
/// `sessions.select(_:)`/`sessions.active`): the primary stays whatever board
/// the user is actually looking at. Never runs while the control target is
/// `.single`. Backs off per member (5s/15s/30s) instead of hot-looping a
/// board that keeps failing to connect.
@Observable
@MainActor
public final class GroupAutoConnector {
    private let sessions: BoardSessionStore
    private let groupStore: BoardGroupStore
    private let boardStore: BoardStore
    /// Injectable connect step, so tests can fake the transport instead of
    /// driving real BLE/Wi-Fi. The default dials through `ConnectionViewModel`
    /// exactly like a manual "已保存设备" tap, on the member's own session —
    /// never touching `sessions.active`.
    private let connect: @MainActor (KnownBoard, BoardSession) async -> Void

    private var target: ControlTarget = .single
    /// One retry/backoff task per member currently being pursued, keyed by
    /// `physicalBoardID`. Present while a connect attempt is in flight or
    /// waiting out its backoff delay; absent once the member is connected or
    /// no longer in the targeted group.
    private var pending: [String: Task<Void, Never>] = [:]
    /// How many consecutive failures each member has seen, so the delay
    /// schedule below advances per member rather than globally.
    private var failureCount: [String: Int] = [:]
    /// 5s / 15s / 30s, then holds at 30s (brief: "back off... per member").
    private static let backoffSchedule: [Double] = [5, 15, 30]

    private var reconcileEpoch = 0

    public init(
        sessions: BoardSessionStore,
        groupStore: BoardGroupStore,
        boardStore: BoardStore,
        connect: (@MainActor (KnownBoard, BoardSession) async -> Void)? = nil
    ) {
        self.sessions = sessions
        self.groupStore = groupStore
        self.boardStore = boardStore
        if let connect {
            self.connect = connect
        } else {
            let reconnectModel = ConnectionViewModel(startBonjourBrowsing: false)
            self.connect = { [sessions] board, session in
                await reconnectModel.connectSavedBoard(
                    board, ble: session.bleTransport, connection: session.connection,
                    boardStore: boardStore,
                    disconnectOtherHotspotSessions: {
                        for other in sessions.sessions
                        where other.connection !== session.connection && other.connection.transportKind == .hotspot {
                            other.connection.disconnect()
                        }
                    }
                )
            }
        }
    }

    /// Called from `RinaBoardApp` whenever the "控制对象" target changes
    /// (explicit selection, or a launch/foreground restore of a persisted
    /// group target) — see `GroupControlFanOut.setTarget`, which this
    /// mirrors. Never auto-connects for `.single`.
    func setTarget(_ newTarget: ControlTarget) {
        target = newTarget
        reconcile()
    }

    /// Re-derives which members need connecting from live state, and re-arms
    /// itself via `withObservationTracking` the same way
    /// `GroupControlFanOut.reconcile()` does, so a member dropping
    /// (disconnect) or the group's membership changing re-triggers this
    /// automatically.
    private func reconcile() {
        reconcileEpoch += 1
        let epoch = reconcileEpoch
        withObservationTracking {
            performReconcile()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, epoch == self.reconcileEpoch else { return }
                self.reconcile()
            }
        }
    }

    private func performReconcile() {
        guard case .group(let groupID) = target,
              let group = groupStore.groups.first(where: { $0.id == groupID }) else {
            cancelAllPending()
            return
        }

        let memberIDs = Set(group.members.map(\.physicalBoardID))
        for id in pending.keys where !memberIDs.contains(id) {
            cancelPending(id)
        }

        for member in group.members {
            let session = sessions.session(matchingGroupMember: member.physicalBoardID)
            // Touched for `withObservationTracking`, so a later connect/
            // disconnect of this exact member re-triggers reconcile.
            _ = session?.connection.connectionState

            if let session, session.connection.connectionState == .connected {
                cancelPending(member.physicalBoardID)
                failureCount[member.physicalBoardID] = 0
                // Refresh the durable mapping every time a matching session
                // connects — covers a member added before this mapping
                // existed, or reconnected over a different saved record
                // (e.g. re-paired BLE) than the one it was added with.
                for knownID in session.knownIdentifiers {
                    groupStore.rememberKnownBoardID(knownID, forPhysicalBoardID: member.physicalBoardID)
                }
                continue
            }
            // Already trying (in flight or waiting out a backoff delay).
            guard pending[member.physicalBoardID] == nil else { continue }
            guard let known = resolveKnownBoard(for: member) else { continue }
            scheduleConnect(member: member, known: known, delay: 0)
        }
        // Also tracked: a group edit (member added/removed) changes `.groups`.
        _ = groupStore.groups
    }

    private func scheduleConnect(member: BoardGroup.Member, known: KnownBoard, delay: Double) {
        let id = member.physicalBoardID
        pending[id] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled else { return }
            guard self.isStillPending(member) else {
                self.pending[id] = nil
                return
            }
            let session = self.sessions.session(for: known.id, name: known.name)
            await self.connect(known, session)
            guard !Task.isCancelled else { return }
            self.pending[id] = nil
            guard self.isStillPending(member) else { return }
            if session.connection.connectionState == .connected {
                self.failureCount[id] = 0
                return
            }
            let attempt = self.failureCount[id] ?? 0
            self.failureCount[id] = attempt + 1
            let nextDelay = Self.backoffSchedule[min(attempt, Self.backoffSchedule.count - 1)]
            self.scheduleConnect(member: member, known: known, delay: nextDelay)
        }
    }

    /// `false` once the target has moved off this group or this member left
    /// it while a connect attempt was in flight/waiting — the attempt must
    /// not resume or reschedule itself in that case.
    private func isStillPending(_ member: BoardGroup.Member) -> Bool {
        guard case .group(let groupID) = target,
              let group = groupStore.groups.first(where: { $0.id == groupID }) else { return false }
        return group.members.contains { $0.physicalBoardID == member.physicalBoardID }
    }

    /// Resolves a member's `physicalBoardID` to a `KnownBoard` to dial:
    /// prefers `knownBoardIDs` (the durable mapping saved when the member was
    /// added, or refreshed on a later connect); falls back to matching a
    /// saved board whose name is still the BLE default, "RinaBoard-<id>" —
    /// covers a board added to the group before this mapping existed, or
    /// never actually connected from this phone before.
    private func resolveKnownBoard(for member: BoardGroup.Member) -> KnownBoard? {
        if let known = boardStore.boards.first(where: { member.knownBoardIDs.contains($0.id) }) {
            return known
        }
        let expectedName = "RinaBoard-\(member.physicalBoardID)"
        return boardStore.boards.first {
            $0.name.caseInsensitiveCompare(expectedName) == .orderedSame
        }
    }

    /// Immediately (re)attempts a connect for `member`, bypassing any backoff
    /// wait currently in progress — the Control Center's per-member "连接"
    /// button for an offline member (BOARD_GROUP_SPEC.md §3 auto-connect
    /// addendum).
    func connectNow(_ member: BoardGroup.Member) {
        guard isStillPending(member) else { return }
        cancelPending(member.physicalBoardID)
        failureCount[member.physicalBoardID] = 0
        guard let known = resolveKnownBoard(for: member) else { return }
        scheduleConnect(member: member, known: known, delay: 0)
    }

    private func cancelPending(_ id: String) {
        pending.removeValue(forKey: id)?.cancel()
        failureCount.removeValue(forKey: id)
    }

    private func cancelAllPending() {
        for id in pending.keys { cancelPending(id) }
    }
}
