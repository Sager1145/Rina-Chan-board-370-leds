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
/// board that keeps failing to connect, and gives up after
/// `maxConsecutiveFailures` in a row until the person retries by hand.
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
    /// waiting out its backoff delay; absent once the member is connected,
    /// has exhausted its retries, or is no longer in the targeted group.
    private var pending: [String: Task<Void, Never>] = [:]
    /// How many consecutive failures each member has seen, so the delay
    /// schedule below advances per member rather than globally.
    private var failureCount: [String: Int] = [:]
    /// 5s / 15s / 30s, then holds at 30s (brief: "back off... per member").
    /// Injectable so tests can shrink it instead of actually waiting.
    private let backoffSchedule: [Double]
    /// After this many consecutive failures for one member, auto-connect
    /// stops dialing it and leaves it to the per-member "连接" button (BOARD
    /// review: "cap retries"). The button resets the count on tap.
    private let maxConsecutiveFailures = 5

    /// Serializes every background connect attempt (across all members) onto
    /// one chain instead of letting them race the shared `ConnectionViewModel`
    /// used by the default `connect` closure — two concurrent calls into it
    /// silently no-op the second one (its own `connectingSavedBoardID`
    /// mutex), which showed up as a 3-board group falling into artificial
    /// backoff even though nothing had actually failed.
    private var connectQueueTail: Task<Void, Never> = Task {}

    private var reconcileEpoch = 0

    public init(
        sessions: BoardSessionStore,
        groupStore: BoardGroupStore,
        boardStore: BoardStore,
        backoffSchedule: [Double] = [5, 15, 30],
        connect: (@MainActor (KnownBoard, BoardSession) async -> Void)? = nil
    ) {
        self.sessions = sessions
        self.groupStore = groupStore
        self.boardStore = boardStore
        self.backoffSchedule = backoffSchedule
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
    /// mirrors. Never auto-connects for `.single`; switching to `.single`
    /// only stops dialing (existing member links stay up, see
    /// `cancelAllPending`). Re-targeting a group (even reselecting the same
    /// one) clears every member's "user disconnected" block, so a group a
    /// person just walked away from and comes back to resumes dialing.
    func setTarget(_ newTarget: ControlTarget) {
        target = newTarget
        if case .group(let groupID) = newTarget,
           let group = groupStore.groups.first(where: { $0.id == groupID }) {
            for member in group.members {
                sessions.session(matchingGroupMember: member.physicalBoardID)?.connection.resetUserDisconnected()
            }
        }
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
            let id = member.physicalBoardID
            let matchedSession = sessions.session(matchingGroupMember: id)
            // Touched for `withObservationTracking`, so a later connect/
            // disconnect of this exact member re-triggers reconcile.
            _ = matchedSession?.connection.connectionState

            if let matchedSession, matchedSession.connection.connectionState == .connected {
                cancelPending(id)
                failureCount[id] = 0
                // Refresh the durable mapping every time a matching session
                // connects — covers a member added before this mapping
                // existed, or reconnected over a different saved record
                // (e.g. re-paired BLE) than the one it was added with.
                for knownID in matchedSession.knownIdentifiers {
                    groupStore.rememberKnownBoardID(knownID, forPhysicalBoardID: id)
                }
                continue
            }

            // Hotspot-only members: joining one board's SoftAP drops another
            // board's (and the phone's own) TCP/LAN link, so these can only
            // ever be connected by hand.
            guard !isHotspotOnlyMember(member) else {
                cancelPending(id)
                continue
            }

            guard let known = resolveKnownBoard(for: member) else { continue }
            let targetSession = sessions.session(for: known.id, name: known.name)
            // Also touched, so a session that only resolves to this member by
            // `known.id` (not yet by live `boardIdentity`, e.g. mid-handshake)
            // still re-triggers reconcile when its state changes.
            let targetState = targetSession.connection.connectionState

            if matchedSession?.connection.wasUserDisconnected == true
                || targetSession.connection.wasUserDisconnected == true {
                // The user explicitly disconnected this board; do not redial
                // it until they reconnect it (clearing the flag) or re-target
                // the group (`setTarget` above).
                cancelPending(id)
                continue
            }

            switch targetState {
            case .connecting, .reconnecting:
                // Already being dialed — by this connector's own in-flight
                // attempt, by a manual reconnect, or by the launch-time
                // reconnect of the active session (RootTabView). Never start
                // a second dial for the same board; BoardConnection.disconnect()
                // inside a fresh connect(using:) would tear the in-progress
                // attempt down.
                cancelPending(id)
                continue
            default:
                break
            }

            guard (failureCount[id] ?? 0) < maxConsecutiveFailures else { continue }
            // Already trying (in flight or waiting out a backoff delay).
            guard pending[id] == nil else { continue }
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
            switch session.connection.connectionState {
            case .connecting, .reconnecting:
                // Something else started dialing this board while this
                // attempt was waiting out its delay. Step aside; reconcile()
                // re-triggers once that attempt's state changes.
                self.pending[id] = nil
                return
            default:
                break
            }
            await self.performConnect(known, session)
            guard !Task.isCancelled else { return }
            self.pending[id] = nil
            guard self.isStillPending(member) else { return }
            if session.connection.connectionState == .connected {
                self.failureCount[id] = 0
                return
            }
            if session.connection.wasUserDisconnected { return }
            let attempt = self.failureCount[id] ?? 0
            let nextAttempt = attempt + 1
            self.failureCount[id] = nextAttempt
            guard nextAttempt < self.maxConsecutiveFailures else {
                // Retry cap reached: stop auto-dialing. The per-member "连接"
                // button (`connectNow`) resets the count and tries again.
                return
            }
            let nextDelay = self.backoffSchedule[min(attempt, self.backoffSchedule.count - 1)]
            self.scheduleConnect(member: member, known: known, delay: nextDelay)
        }
    }

    /// Runs one connect attempt on the serial `connectQueueTail` chain, in an
    /// unstructured child `Task` so that cancelling the *caller's* task (e.g.
    /// a member leaving the group, or a backoff task cancelled by
    /// `cancelPending` while this is mid-flight) never cancels the connect
    /// itself — including its post-connect device-name refresh, which reads
    /// `Task.isCancelled` and must see a successful connect through to
    /// completion rather than silently skipping the name read.
    private func performConnect(_ known: KnownBoard, _ session: BoardSession) async {
        let previous = connectQueueTail
        let connect = self.connect
        let task = Task {
            _ = await previous.value
            await connect(known, session)
        }
        connectQueueTail = task
        await task.value
    }

    /// `false` once the target has moved off this group or this member left
    /// it while a connect attempt was in flight/waiting — the attempt must
    /// not resume or reschedule itself in that case.
    private func isStillPending(_ member: BoardGroup.Member) -> Bool {
        guard case .group(let groupID) = target,
              let group = groupStore.groups.first(where: { $0.id == groupID }) else { return false }
        return group.members.contains { $0.physicalBoardID == member.physicalBoardID }
    }

    /// Every `KnownBoard` this member could resolve to: the durable
    /// `knownBoardIDs` mapping (saved when the member was added, or
    /// refreshed on a later connect) if it has any matches, else a fallback
    /// match on the BLE default name, "RinaBoard-<id>" — covers a board
    /// added to the group before the mapping existed, or never actually
    /// connected from this phone before.
    private func knownBoardCandidates(for member: BoardGroup.Member) -> [KnownBoard] {
        let byMapping = boardStore.boards.filter { member.knownBoardIDs.contains($0.id) }
        if !byMapping.isEmpty { return byMapping }
        let expectedName = "RinaBoard-\(member.physicalBoardID)"
        return boardStore.boards.filter { $0.name.caseInsensitiveCompare(expectedName) == .orderedSame }
    }

    /// Resolves a member's `physicalBoardID` to a `KnownBoard` to dial:
    /// never a hotspot-only record (see `isHotspotOnlyMember`), and prefers
    /// BLE over TCP/Bonjour when both are known for the same board.
    private func resolveKnownBoard(for member: BoardGroup.Member) -> KnownBoard? {
        let candidates = knownBoardCandidates(for: member).filter { $0.preferredTransport != "hotspot" }
        if let ble = candidates.first(where: { $0.preferredTransport == "bluetooth" }) { return ble }
        return candidates.first
    }

    /// `true` when every `KnownBoard` this member could resolve to only
    /// reaches it via the board's own SoftAP — auto-connect must never dial
    /// those: joining one board's hotspot drops another board's (and the
    /// phone's own) TCP/LAN connection. Shown in the UI as "热点直连的板需手动连接".
    func isHotspotOnlyMember(_ member: BoardGroup.Member) -> Bool {
        let candidates = knownBoardCandidates(for: member)
        return !candidates.isEmpty && candidates.allSatisfy { $0.preferredTransport == "hotspot" }
    }

    /// `true` once this member has failed `maxConsecutiveFailures` times in a
    /// row and auto-connect has stopped dialing it. The per-member "连接"
    /// button resets this via `connectNow`.
    func hasGivenUp(_ member: BoardGroup.Member) -> Bool {
        (failureCount[member.physicalBoardID] ?? 0) >= maxConsecutiveFailures
    }

    /// Immediately (re)attempts a connect for `member`, bypassing any backoff
    /// wait currently in progress and any retry-cap/user-disconnect block —
    /// the Control Center's per-member "连接" button for an offline member
    /// (BOARD_GROUP_SPEC.md §3 auto-connect addendum).
    func connectNow(_ member: BoardGroup.Member) {
        guard isStillPending(member) else { return }
        cancelPending(member.physicalBoardID)
        failureCount[member.physicalBoardID] = 0
        guard let known = resolveKnownBoard(for: member) else { return }
        sessions.session(matchingGroupMember: member.physicalBoardID)?.connection.resetUserDisconnected()
        sessions.session(for: known.id, name: known.name).connection.resetUserDisconnected()
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
