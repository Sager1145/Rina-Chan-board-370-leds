import Foundation
import RinaCore

/// Mirrors a board group's control-target primary's non-Text-tab commands
/// and frames to every other online member (board-group control-fan-out
/// addendum to `BOARD_GROUP_SPEC.md`): with any board group selected as the
/// "控制对象", stitching itself stays Text-tab-only, but everything else —
/// faces, saved faces, prev/next, mode, brightness, colour, auto interval,
/// buttons, lip sync/Live/video frames, pause/resume, hint LED — applies to
/// every member. Face libraries are never synced across members; an
/// `apply_saved_face`/B1/B2 is re-resolved to the primary's actual resulting
/// frame (`faceFrameResolver`) and that bitmap is what a sink receives.
///
/// Holds no UI. `BoardConnection.command(_:)`/`setFrame(_:...)` call into
/// this type on the primary's connection only (`BoardConnection.fanOut`);
/// this type never calls back into the primary's own send path, so a slow or
/// failing sink can never delay or fail the primary's own request.
@Observable
@MainActor
public final class GroupControlFanOut {
    private let sessions: BoardSessionStore
    private let groupStore: BoardGroupStore
    private let coordinator: BoardGroupCoordinator

    /// The current control primary's `physicalBoardID`, or nil when the
    /// control target is `.single` or no member of the target group is
    /// online.
    public private(set) var primaryID: String?
    /// The most recent per-sink failure, keyed by `physicalBoardID`; cleared
    /// the next time that sink succeeds. Never surfaced to the primary's own
    /// callers — this is purely for a UI that wants to show which member is
    /// out of sync.
    public private(set) var memberErrors: [String: String] = [:]

    /// Resolves a group control primary's `apply_saved_face`/B1/B2 reply to
    /// the frame it actually applied, so a sink can be sent that bitmap
    /// directly instead of an id/index its own (unsynced) face library may
    /// not share. Wired in `RinaBoardApp` to
    /// `FaceLibraryModel.boardFaceFrame(id:index:generation:)`. Returning nil
    /// falls back to replaying the original command verbatim.
    public var faceFrameResolver: ((BoardConnection, CommandReply) -> PackedFrame?)?

    /// Called with a promoted primary's `boardKey` right before this type
    /// selects it as the new active session, so `ControlViewModel` can retag
    /// the in-progress Faces draft to the new board instead of the ordinary
    /// board-switch handling discarding it (user decision: primary
    /// auto-promotion must not lose the draft). Wired in `RinaBoardApp` to
    /// `ControlViewModel.retagDraftForGroupPromotion(to:)`. Not called for
    /// the very first member picked for a freshly selected group target,
    /// since there's no established primary/draft continuity to preserve
    /// yet.
    public var draftPromotionHook: ((String) -> Void)?

    private var target: ControlTarget = .single
    private weak var primaryConnectionRef: BoardConnection?
    private var dispatchSeq = 0
    private var channels: [String: SinkChannel] = [:]

    private enum Item {
        case command(RinaCommand, leased: Bool)
        case frame(PackedFrame, Playback, reason: String)
    }

    /// One outstanding mirror queue for one sink connection. Torn down (and
    /// its worker stopped) whenever that member drops out of the fan-out —
    /// target change, member removal, disconnect, or a reconnect that must
    /// start a fresh channel rather than resume a stale one.
    private final class SinkChannel {
        let id: String
        unowned let connection: BoardConnection
        var connectionGeneration: UUID
        /// Bumped on teardown; a running worker compares this against the
        /// value it captured at start and stops once they differ, instead of
        /// requiring a `Task` cancellation race.
        var channelGeneration = 0
        var token: UUID?
        var items: [Item] = []
        var worker: Task<Void, Never>?
        var wake: CheckedContinuation<Void, Never>?

        init(id: String, connection: BoardConnection, connectionGeneration: UUID) {
            self.id = id
            self.connection = connection
            self.connectionGeneration = connectionGeneration
        }
    }

    public init(sessions: BoardSessionStore, groups: BoardGroupStore, coordinator: BoardGroupCoordinator) {
        self.sessions = sessions
        self.groupStore = groups
        self.coordinator = coordinator
    }

    // MARK: - Target / reconciliation

    func setTarget(_ t: ControlTarget) {
        target = t
        reconcile()
    }

    /// Re-derives the primary/sinks from live state. Called on `setTarget`
    /// and re-arms itself via `withObservationTracking` on `sessions.active`,
    /// `groupStore.groups`, and every current target member's
    /// `connectionState`/`connectionGeneration`, so a connect/disconnect or a
    /// group edit re-runs this automatically without any external observer.
    public func reconcile() {
        withObservationTracking {
            performReconcile()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    private func performReconcile() {
        guard case .group(let groupID) = target,
              let group = groupStore.groups.first(where: { $0.id == groupID }) else {
            detachAllSinks()
            primaryID = nil
            return
        }

        var memberSessions: [(member: BoardGroup.Member, session: BoardSession)] = []
        for member in group.members {
            guard let session = coordinator.session(for: member) else { continue }
            // Touched for `withObservationTracking` even when not used below.
            _ = session.connection.connectionState
            _ = session.connection.connectionGeneration
            memberSessions.append((member, session))
        }

        let activeSession = sessions.active
        let activeEntry = memberSessions.first { $0.session === activeSession }

        if let entry = activeEntry, activeSession.connection.connectionState == .connected {
            attachPrimary(member: entry.member, session: activeSession, memberSessions: memberSessions)
            return
        }

        if activeEntry == nil, primaryID != nil {
            // The user navigated to a board outside this group after a
            // primary was already established — leaving group control mode
            // is the real intent, not something to fight by re-selecting a
            // member underneath them.
            detachAllSinks()
            primaryID = nil
            target = .single
            UserDefaults.standard.set("", forKey: ControlTargetKey.groupID)
            return
        }

        // Either the freshly selected target's active board isn't a member
        // yet, or the established primary just went offline: adopt the next
        // online member in slot order.
        guard let next = memberSessions.first(where: { $0.session.connection.connectionState == .connected }) else {
            detachAllSinks()
            primaryID = nil
            return
        }
        if primaryID != nil, let newKey = next.session.connection.boardKey {
            draftPromotionHook?(newKey)
        }
        sessions.select(next.session)
        attachPrimary(member: next.member, session: next.session, memberSessions: memberSessions)
    }

    private func attachPrimary(
        member: BoardGroup.Member,
        session: BoardSession,
        memberSessions: [(member: BoardGroup.Member, session: BoardSession)]
    ) {
        primaryID = member.physicalBoardID
        let primaryConnection = session.connection
        primaryConnectionRef = primaryConnection

        for other in sessions.sessions where other !== session {
            if other.connection.fanOut === self { other.connection.fanOut = nil }
        }
        primaryConnection.fanOut = self

        let connectedSinks = memberSessions.filter {
            $0.session !== session && $0.session.connection.connectionState == .connected
        }
        let connectedIDs = Set(connectedSinks.map(\.member.physicalBoardID))

        for id in channels.keys where !connectedIDs.contains(id) {
            detachSink(id: id)
        }

        for entry in connectedSinks {
            let id = entry.member.physicalBoardID
            let connection = entry.session.connection
            if let existing = channels[id], existing.connectionGeneration == connection.connectionGeneration {
                continue
            }
            if channels[id] != nil { detachSink(id: id) }
            attachSink(id: id, connection: connection, primary: primaryConnection)
        }
    }

    private func attachSink(id: String, connection: BoardConnection, primary: BoardConnection) {
        let channel = SinkChannel(id: id, connection: connection, connectionGeneration: connection.connectionGeneration)
        channels[id] = channel
        memberErrors.removeValue(forKey: id)
        startWorker(channel)

        // Alignment on attach: the same fields `BoardControlCenterModel.sync(from:)`
        // reads, so a newly attached sink starts matching the primary.
        if let renderer = primary.status?.renderer {
            if let brightness = renderer.brightness {
                enqueueAndWake(.command(.setBrightness(raw: brightness), leased: false), to: channel)
            }
            if let hex = renderer.color {
                enqueueAndWake(.command(.setColor(hex: hex), leased: false), to: channel)
            }
            if let ms = renderer.autoIntervalMs {
                enqueueAndWake(.command(.setAutoInterval(ms: ms), leased: false), to: channel)
            }
        }
    }

    private func detachSink(id: String) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        channel.channelGeneration += 1
        channel.worker?.cancel()
        channel.wake?.resume()
        channel.wake = nil
        if channel.connection.output.source == .groupControl {
            channel.connection.output.invalidate()
        }
        memberErrors.removeValue(forKey: id)
    }

    private func detachAllSinks() {
        for id in channels.keys { detachSink(id: id) }
        if let primary = primaryConnectionRef, primary.fanOut === self { primary.fanOut = nil }
        primaryConnectionRef = nil
        memberErrors.removeAll()
    }

    // MARK: - Dispatch (called from `BoardConnection` on the primary)

    private func isCurrentPrimary(_ connection: BoardConnection) -> Bool {
        primaryConnectionRef === connection
    }

    /// Synchronously claims a `.groupControl` lease on every sink (bumping
    /// `dispatchSeq`), and — if the target group is currently playing on the
    /// Text tab — tells the coordinator it's been superseded so its
    /// re-anchor loop stops fighting this claim.
    @discardableResult
    private func claimAllSinksAndBumpSeq() -> Int {
        dispatchSeq += 1
        for channel in channels.values {
            channel.token = channel.connection.output.claim(.groupControl)
        }
        if case .group(let groupID) = target, coordinator.isPlaying, coordinator.activeGroupID == groupID {
            coordinator.markSupersededByControl()
        }
        return dispatchSeq
    }

    public func dispatch(_ cmd: RinaCommand, leased: Bool, from primary: BoardConnection) {
        guard isCurrentPrimary(primary), !channels.isEmpty else { return }
        if leased { claimAllSinksAndBumpSeq() }
        for channel in channels.values {
            enqueueAndWake(.command(cmd, leased: leased), to: channel)
        }
    }

    public func dispatchFrame(_ packed: PackedFrame, playback: Playback, reason: String, from primary: BoardConnection) {
        guard isCurrentPrimary(primary), !channels.isEmpty else { return }
        claimAllSinksAndBumpSeq()
        for channel in channels.values {
            enqueueAndWake(.frame(packed, playback, reason: reason), to: channel)
        }
    }

    public func beginLeasedAction(from primary: BoardConnection) -> Int? {
        guard isCurrentPrimary(primary), !channels.isEmpty else { return nil }
        return claimAllSinksAndBumpSeq()
    }

    public func primaryFaceApplied(reply: CommandReply, original: RinaCommand, ticket: Int, from primary: BoardConnection) {
        guard isCurrentPrimary(primary), ticket == dispatchSeq else { return }
        let resolved = faceFrameResolver?(primary, reply)
        for channel in channels.values {
            if let frame = resolved {
                enqueueAndWake(.frame(frame, .idle, reason: "group_control_face"), to: channel)
            } else {
                enqueueAndWake(.command(original, leased: true), to: channel)
            }
        }
    }

    // MARK: - Per-sink queue / worker

    private func coalesceKey(for cmd: RinaCommand) -> String? {
        if case .verbatim(let key) = cmd.groupFanOutPolicy { return key }
        return nil
    }

    private func enqueueAndWake(_ item: Item, to channel: SinkChannel) {
        switch item {
        case .frame:
            // A new frame replaces any queued-but-unstarted frame after the
            // last queued command, so a burst of live frames never falls
            // behind while still respecting command ordering.
            if let lastCommandIndex = channel.items.lastIndex(where: {
                if case .command = $0 { return true }; return false
            }) {
                channel.items.removeSubrange((lastCommandIndex + 1)...)
            } else {
                channel.items.removeAll { if case .frame = $0 { return true }; return false }
            }
            channel.items.append(item)
        case .command(let cmd, _):
            if let key = coalesceKey(for: cmd),
               let idx = channel.items.firstIndex(where: {
                   if case .command(let queued, _) = $0 { return coalesceKey(for: queued) == key }
                   return false
               }) {
                channel.items[idx] = item
            } else {
                channel.items.append(item)
            }
        }
        enforceCap(channel)
        if let wake = channel.wake {
            channel.wake = nil
            wake.resume()
        }
    }

    private func enforceCap(_ channel: SinkChannel) {
        while channel.items.count > 16 {
            if let idx = channel.items.firstIndex(where: { if case .frame = $0 { return true }; return false }) {
                channel.items.remove(at: idx)
            } else {
                channel.items.removeFirst()
            }
        }
    }

    private func startWorker(_ channel: SinkChannel) {
        let myGeneration = channel.channelGeneration
        channel.worker = Task { @MainActor [weak self] in
            await self?.runWorker(channel, myGeneration: myGeneration)
        }
    }

    private func runWorker(_ channel: SinkChannel, myGeneration: Int) async {
        while !Task.isCancelled {
            guard channel.channelGeneration == myGeneration else { return }
            if channel.items.isEmpty {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    guard channel.channelGeneration == myGeneration else {
                        continuation.resume()
                        return
                    }
                    channel.wake = continuation
                }
                continue
            }
            guard channel.channelGeneration == myGeneration else { return }
            let item = channel.items.removeFirst()
            await process(item, channel: channel, myGeneration: myGeneration)
        }
    }

    private func process(_ item: Item, channel: SinkChannel, myGeneration: Int) async {
        let connection = channel.connection
        do {
            switch item {
            case .command(let cmd, let leased):
                if leased {
                    guard let token = channel.token, connection.output.isCurrent(token) else {
                        dropQueuedLeasedItems(channel)
                        return
                    }
                    _ = try await connection.withOutput(token) { try await connection.command(cmd) }
                } else {
                    _ = try await connection.command(cmd)
                }
            case .frame(let packed, let playback, let reason):
                guard let token = channel.token, connection.output.isCurrent(token) else {
                    dropQueuedLeasedItems(channel)
                    return
                }
                _ = try await connection.setFrame(packed, playback: playback, reason: reason, outputSession: token)
            }
            guard channel.channelGeneration == myGeneration else { return }
            memberErrors.removeValue(forKey: channel.id)
        } catch {
            guard channel.channelGeneration == myGeneration else { return }
            if error is CancellationError { return }
            if case RatePumpError.dropped = error { return }
            memberErrors[channel.id] = error.localizedDescription
        }
    }

    /// "A worker finding its token no longer current drops its queued leased
    /// items and never re-claims" — every frame, and every leased command,
    /// still queued is discarded; unleased commands (which don't need the
    /// lease at all) are left in place.
    private func dropQueuedLeasedItems(_ channel: SinkChannel) {
        channel.items.removeAll { item in
            switch item {
            case .frame: return true
            case .command(_, let leased): return leased
            }
        }
    }
}
