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
/// `.single`.
///
/// Per-member state machine (`phases`; absent = idle):
///
///     idle ──schedule(delay>0)──▶ waiting ──delay elapses──▶ queued
///     idle ──schedule(delay=0)──────────────────────────────▶ queued
///     queued ──dispatch re-check passes──▶ dialing ──finish/timeout──▶ idle
///     waiting/queued ──invalidate (target/group edit/connectNow/busy)──▶ idle
///
/// `dialing` is never cancelled from outside: an attempt already in flight
/// finishes (including its post-connect naming). Its outcome is counted
/// exactly once — `.connected` resets `failureCount`, anything else adds one
/// (unless the user disconnected it). While any matching session is
/// `.connecting`/`.reconnecting` (e.g. `BoardConnection`'s own retry loop
/// after a failed dial) the member stays idle; once that loop ends the next
/// dial waits out the 5 s / 15 s / 30 s backoff for the current count, and at
/// `maxConsecutiveFailures` the member stops until the user taps "连接".
@Observable
@MainActor
public final class GroupAutoConnector {
    /// Backoff/timeout sleeper; throws when the sleeping task is cancelled.
    typealias Sleeper = @MainActor (Double) async throws -> Void

    @ObservationIgnored private let sessions: BoardSessionStore
    @ObservationIgnored private let groupStore: BoardGroupStore
    @ObservationIgnored private let boardStore: BoardStore
    /// Injectable connect step, so tests can fake the transport instead of
    /// driving real BLE/Wi-Fi. The default dials through a fresh
    /// `ConnectionViewModel` exactly like a manual "已保存设备" tap, on the
    /// member's own session — never touching `sessions.active`.
    @ObservationIgnored private let connect: @MainActor (KnownBoard, BoardSession) async -> Void
    @ObservationIgnored private let sleep: Sleeper
    /// 5s / 15s / 30s, then holds at 30s. Indexed by `failureCount - 1`.
    @ObservationIgnored private let backoffSchedule: [Double]
    /// One hung connect must not stall the serial queue forever.
    @ObservationIgnored private let attemptTimeout: Double
    static let maxConsecutiveFailures = 5

    @ObservationIgnored private var target: ControlTarget = .single
    /// Consecutive failed dials per member (`physicalBoardID`). Observed by
    /// the UI through `hasGivenUp`. Reset only on `.connected`, `connectNow`,
    /// or an explicit re-target of the group.
    private var failureCount: [String: Int] = [:]

    private enum Phase {
        case waiting(token: UUID, task: Task<Void, Never>)
        case queued(token: UUID)
        case dialing(token: UUID)
    }
    @ObservationIgnored private var phases: [String: Phase] = [:]
    /// FIFO of queued attempts. Stale entries (token no longer current) are
    /// skipped at dispatch.
    @ObservationIgnored private var readyQueue: [(id: String, token: UUID)] = []
    /// Connects are serialized across all members.
    @ObservationIgnored private var isDialing = false
    /// Member ids of the targeted group last reconciled; a change is a group
    /// edit and invalidates queued attempts.
    @ObservationIgnored private var memberSnapshot: [String] = []
    @ObservationIgnored private var reconcileEpoch = 0

    private struct DialPlan {
        let known: KnownBoard
        /// An existing session that already answers to this member — dialed
        /// in place so no second session is ever created for the board.
        let session: BoardSession?
    }

    init(
        sessions: BoardSessionStore,
        groupStore: BoardGroupStore,
        boardStore: BoardStore,
        backoffSchedule: [Double] = [5, 15, 30],
        attemptTimeout: Double = 45,
        sleep: Sleeper? = nil,
        connect: (@MainActor (KnownBoard, BoardSession) async -> Void)? = nil
    ) {
        self.sessions = sessions
        self.groupStore = groupStore
        self.boardStore = boardStore
        self.backoffSchedule = backoffSchedule
        self.attemptTimeout = attemptTimeout
        self.sleep = sleep ?? { seconds in try await Task.sleep(for: .seconds(seconds)) }
        if let connect {
            self.connect = connect
        } else {
            self.connect = { [sessions] board, session in
                // A fresh model per attempt: its `connectingSavedBoardID`
                // guard would otherwise silently no-op every later attempt
                // while a timed-out one is still unwinding.
                let model = ConnectionViewModel(startBonjourBrowsing: false)
                await model.connectSavedBoard(
                    board, ble: session.bleTransport, connection: session.connection,
                    boardStore: boardStore,
                    updateLastSeen: false,
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

    // MARK: Target

    /// Called from `RinaBoardApp` for the "控制对象" target. `isExplicit` is
    /// `true` only for a real user change of the stored target (not the
    /// launch-time restore, not a foreground resume): only that clears every
    /// member's user-disconnect block and failure count. Any target change
    /// invalidates queued-but-not-started attempts; `.single` keeps existing
    /// links and only stops dialing.
    func setTarget(_ newTarget: ControlTarget, isExplicit: Bool) {
        let changed = newTarget != target
        target = newTarget
        if changed || isExplicit { invalidateQueued() }
        if let group = targetedGroup() {
            memberSnapshot = group.members.map(\.physicalBoardID)
            if isExplicit {
                for member in group.members {
                    failureCount[member.physicalBoardID] = nil
                    for session in matchingSessions(for: member) {
                        session.connection.resetUserDisconnected()
                    }
                }
            }
        } else {
            memberSnapshot = []
        }
        reconcile()
    }

    /// The per-member "连接" button: clears the retry cap and the user-
    /// disconnect block on every matching session, supersedes any waiting/
    /// queued attempt for the member, and queues exactly one immediate dial
    /// (none if one is already in flight).
    func connectNow(_ member: BoardGroup.Member) {
        guard let current = targetedMember(member.physicalBoardID) else { return }
        let id = current.physicalBoardID
        for session in matchingSessions(for: current) {
            session.connection.resetUserDisconnected()
        }
        if failureCount[id] != nil { failureCount[id] = nil }
        if case .dialing = phases[id] { return }
        cancelQueued(id)
        enqueue(id, token: UUID())
    }

    // MARK: UI queries

    /// `true` when every `KnownBoard` this member could resolve to only
    /// reaches it via the board's own SoftAP — auto-connect must never dial
    /// those: joining one board's hotspot drops another board's (and the
    /// phone's own) TCP/LAN connection. Shown as "热点直连的板需手动连接".
    func isHotspotOnlyMember(_ member: BoardGroup.Member) -> Bool {
        let candidates = knownBoardCandidates(for: member)
        return !candidates.isEmpty && candidates.allSatisfy { $0.preferredTransport == "hotspot" }
    }

    /// `true` once this member has failed `maxConsecutiveFailures` dials in a
    /// row; shown as "连接失败，点击重试".
    func hasGivenUp(_ member: BoardGroup.Member) -> Bool {
        (failureCount[member.physicalBoardID] ?? 0) >= Self.maxConsecutiveFailures
    }

    // MARK: Reconcile

    /// Re-derives what each member needs from live state and re-arms itself
    /// via `withObservationTracking`, like `GroupControlFanOut.reconcile()`.
    /// Side-effect free apart from scheduling/cancelling this connector's own
    /// attempts, resetting a connected member's count and refreshing its
    /// durable `knownBoardIDs`: it never creates, renames or selects a session.
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
        _ = sessions.sessions
        _ = boardStore.boards
        guard let group = targetedGroup() else {
            invalidateQueued()
            memberSnapshot = []
            return
        }
        let memberIDs = group.members.map(\.physicalBoardID)
        if memberIDs != memberSnapshot {
            invalidateQueued()
            memberSnapshot = memberIDs
        }

        for member in group.members {
            let id = member.physicalBoardID
            let matching = matchingSessions(for: member)
            for session in matching {
                _ = session.connection.connectionState
                _ = session.connection.wasUserDisconnected
            }

            if matching.contains(where: { $0.connection.connectionState == .connected }) {
                cancelQueued(id)
                if failureCount[id] != nil { failureCount[id] = nil }
                // Connected elsewhere clears the user-disconnect block on
                // every session that is this member, not just the live one.
                for session in matching where session.connection.wasUserDisconnected {
                    session.connection.resetUserDisconnected()
                }
                if let proven = sessions.session(matchingGroupMember: id),
                   proven.connection.connectionState == .connected,
                   proven.connection.boardIdentity == id {
                    for knownID in proven.knownIdentifiers {
                        groupStore.rememberKnownBoardID(knownID, forPhysicalBoardID: id)
                    }
                }
                continue
            }
            if isHotspotOnlyMember(member) || matching.contains(where: { $0.connection.wasUserDisconnected }) {
                cancelQueued(id)
                continue
            }
            if matching.contains(where: { Self.isDialing($0.connection.connectionState) }) {
                // Our own in-flight dial, a manual connect, or BoardConnection's
                // own retry loop: stay idle, never cancel a running dial.
                cancelQueued(id)
                continue
            }
            if hasGivenUp(member) { continue }
            if phases[id] != nil { continue }
            guard dialPlan(for: member) != nil else { continue }
            let failures = failureCount[id] ?? 0
            let delay = failures == 0 || backoffSchedule.isEmpty
                ? 0 : backoffSchedule[min(failures - 1, backoffSchedule.count - 1)]
            schedule(id, delay: delay)
        }
    }

    // MARK: Queue

    private func schedule(_ id: String, delay: Double) {
        let token = UUID()
        guard delay > 0 else {
            enqueue(id, token: token)
            return
        }
        let sleep = self.sleep
        let task = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, case .waiting(let current, _) = self.phases[id], current == token else { return }
            self.enqueue(id, token: token)
        }
        phases[id] = .waiting(token: token, task: task)
    }

    private func enqueue(_ id: String, token: UUID) {
        phases[id] = .queued(token: token)
        readyQueue.append((id, token))
        pump()
    }

    /// Starts the next queued attempt whose dispatch re-check still passes:
    /// token current, target still this group, member still in it, not
    /// user-disconnected, not given up, no matching session busy.
    private func pump() {
        guard !isDialing else { return }
        while !readyQueue.isEmpty {
            let (id, token) = readyQueue.removeFirst()
            guard case .queued(let current) = phases[id], current == token else { continue }
            guard let member = targetedMember(id), let plan = dialPlan(for: member) else {
                phases[id] = nil
                continue
            }
            phases[id] = .dialing(token: token)
            isDialing = true
            // The only place a session may be created/renamed, done in the
            // same turn as the re-check above. `backgroundSession` never
            // binds/replaces `sessions.active`, even the launch-time unbound
            // placeholder.
            let session = plan.session ?? sessions.backgroundSession(for: plan.known.id, name: plan.known.name)
            let connect = self.connect
            let known = plan.known
            // Unstructured and never cancelled here: a target change or
            // timeout must not abort a connect that succeeds, or its
            // post-connect naming.
            let dial = Task { @MainActor in await connect(known, session) }
            Task { @MainActor [weak self] in
                await self?.finishDial(id: id, token: token, session: session, dial: dial)
            }
            return
        }
    }

    private func finishDial(id: String, token: UUID, session: BoardSession, dial: Task<Void, Never>) async {
        // The generation this dial owns, captured as close to its own start
        // as this side of the Task can get.
        let generation = session.connection.connectionGeneration
        let finished = await Self.wait(for: dial, timeout: attemptTimeout, sleep: sleep)
        if !finished, session.connection.connectionState == .connecting,
           session.connection.connectionGeneration == generation {
            // A carrier hung mid-connect; tear it down so it cannot hold the
            // board in `.connecting` and block every later dial. Skipped if
            // the generation moved on: some other connect already superseded
            // this one, and tearing that down would be wrong.
            session.connection.disconnect()
        }

        isDialing = false
        if case .dialing(let current) = phases[id], current == token { phases[id] = nil }
        if targetedMember(id) != nil {
            if session.connection.connectionState == .connected {
                if failureCount[id] != nil { failureCount[id] = nil }
            } else if !session.connection.wasUserDisconnected {
                // Counted even when the connection is now `.reconnecting`: a
                // failed `connect(using:)` always hands off to BoardConnection's
                // own retry loop, so skipping that state meant no dial was
                // ever counted and the cap never engaged (677 dials in a test).
                // Reconcile stays idle until that loop settles anyway.
                failureCount[id, default: 0] += 1
            }
        }
        reconcile()
        pump()
    }

    /// `true` if `dial` finished before `timeout`.
    private static func wait(for dial: Task<Void, Never>, timeout: Double, sleep: @escaping Sleeper) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            let timer = Task { @MainActor in
                do { try await sleep(timeout) } catch { return }
                gate.resume(false)
            }
            Task { @MainActor in
                await dial.value
                timer.cancel()
                gate.resume(true)
            }
        }
    }

    private func cancelQueued(_ id: String) {
        switch phases[id] {
        case .waiting(_, let task):
            task.cancel()
            phases[id] = nil
        case .queued:
            phases[id] = nil
        case .dialing, nil:
            return
        }
    }

    /// Drops every waiting/queued attempt; a dial in flight is left to finish.
    private func invalidateQueued() {
        for id in Array(phases.keys) { cancelQueued(id) }
        readyQueue.removeAll()
    }

    // MARK: Resolution

    private static func isDialing(_ state: BoardConnectionState) -> Bool {
        switch state {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    private func targetedGroup() -> BoardGroup? {
        guard case .group(let groupID) = target else { return nil }
        return groupStore.groups.first { $0.id == groupID }
    }

    private func targetedMember(_ id: String) -> BoardGroup.Member? {
        targetedGroup()?.members.first { $0.physicalBoardID == id }
    }

    /// Every session that could be this member: live/sticky board identity,
    /// or any alias equal to one of its `knownBoardIDs` / candidate records.
    private func matchingSessions(for member: BoardGroup.Member) -> [BoardSession] {
        var ids = Set(member.knownBoardIDs)
        ids.formUnion(knownBoardCandidates(for: member).map(\.id))
        var result = sessions.existingSessions(matchingAnyOf: ids)
        for session in sessions.sessions
        where session.matchesGroupMember(physicalBoardID: member.physicalBoardID)
            && !result.contains(where: { $0 === session }) {
            result.append(session)
        }
        return result
    }

    /// What a dial for `member` would connect, or `nil` if it must not dial
    /// now. Side-effect free. Prefers an existing matching session and that
    /// session's own record; otherwise the member's BLE record.
    private func dialPlan(for member: BoardGroup.Member) -> DialPlan? {
        guard !isHotspotOnlyMember(member), !hasGivenUp(member) else { return nil }
        let matching = matchingSessions(for: member)
        if matching.contains(where: {
            $0.connection.connectionState == .connected || Self.isDialing($0.connection.connectionState)
                || $0.connection.wasUserDisconnected
        }) { return nil }
        let candidates = knownBoardCandidates(for: member).filter { $0.preferredTransport != "hotspot" }
        for session in matching {
            let own = candidates.filter { record in
                session.boardID == record.id
                    || sessions.existingSessions(matchingAnyOf: [record.id]).contains { $0 === session }
            }
            if let record = own.first(where: { $0.preferredTransport == "bluetooth" }) ?? own.first {
                return DialPlan(known: record, session: session)
            }
        }
        guard let record = resolveKnownBoard(for: member) else { return nil }
        return DialPlan(known: record, session: matching.first)
    }

    /// Every `KnownBoard` this member could resolve to: the durable
    /// `knownBoardIDs` mapping if it has any matches, else a fallback match
    /// on the BLE default name, "RinaBoard-<id>".
    private func knownBoardCandidates(for member: BoardGroup.Member) -> [KnownBoard] {
        let byMapping = boardStore.boards.filter { member.knownBoardIDs.contains($0.id) }
        if !byMapping.isEmpty { return byMapping }
        let expectedName = "RinaBoard-\(member.physicalBoardID)"
        return boardStore.boards.filter { $0.name.caseInsensitiveCompare(expectedName) == .orderedSame }
    }

    /// Never a hotspot-only record; prefers BLE over TCP/Bonjour.
    private func resolveKnownBoard(for member: BoardGroup.Member) -> KnownBoard? {
        let candidates = knownBoardCandidates(for: member).filter { $0.preferredTransport != "hotspot" }
        if let ble = candidates.first(where: { $0.preferredTransport == "bluetooth" }) { return ble }
        return candidates.first
    }
}

/// Resumes a continuation at most once (dial finish vs. timeout race).
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
