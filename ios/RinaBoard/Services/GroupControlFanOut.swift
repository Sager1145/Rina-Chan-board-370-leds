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

    /// The current control primary's own connection (`GroupAutoCycler`'s only
    /// dependency on this type): the board whose `setFrame` a synced
    /// auto-cycle tick should call, since this type's own dispatch mirrors
    /// that call to every sink. `nil` exactly when `primaryID` is.
    public var primaryConnection: BoardConnection? { primaryConnectionRef }

    /// Resolves a group control primary's `apply_saved_face`/B1/B2 reply to
    /// the frame it actually applied, so a sink can be sent that bitmap
    /// directly instead of an id/index its own (unsynced) face library may
    /// not share. Wired in `RinaBoardApp` to
    /// `FaceLibraryModel.boardFaceFrame(id:index:generation:)`. Returning nil
    /// (or this being unset) falls back to reading the primary's resulting
    /// frame back via `getFrame()` instead — never to replaying the original
    /// command verbatim (`primaryFaceApplied(reply:original:ticket:from:)`).
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

    /// Called at most once per "target session" (from no primary to a
    /// primary being established, whether by explicit selection or
    /// promotion into an empty slot), when that freshly-established
    /// primary's own firmware `renderer.mode` is `"auto"` (M2). Turning a
    /// group on must not leave the primary free-running its own independent
    /// auto timer while every other member gets forced to `manual`
    /// (`alignSink`) — the user's auto intent is kept, just synced, by
    /// starting `GroupAutoCycler` instead. Wired in `RinaBoardApp` to
    /// `GroupAutoCycler.start()`. Never called again for the same
    /// continuous primary (a later reconcile of the same target/primary is
    /// not "the group was chosen" again) — see `primaryAutoCheckDone`.
    public var primaryWasAutoHook: (() -> Void)?
    /// `true` once `attachPrimary` has either found a definitive
    /// `renderer.mode` for the current primary (and, if `"auto"`, already
    /// fired `primaryWasAutoHook`) or is still waiting on the primary's
    /// first `status`. Reset to `false` only when transitioning from no
    /// primary to establishing one, so a promoted primary (already forced to
    /// `manual` by `alignSink` while it was a sink) is never re-checked.
    private var primaryAutoCheckDone = false

    private var target: ControlTarget = .single
    /// Consumed by the very next `performReconcile()` and reset to `false`
    /// immediately after: only a real, explicit `setTarget` call (the user
    /// choosing a group target) may force-select a first primary when the
    /// active board isn't already a member. A launch-time restore of the
    /// persisted target, or any reconcile triggered afterwards by
    /// `withObservationTracking` (a connect/disconnect, a group edit), must
    /// never silently switch control onto a board the user didn't pick
    /// (product rule: only explicit choices switch control).
    private var pendingExplicitTargetChange = false
    private weak var primaryConnectionRef: BoardConnection?
    private var dispatchSeq = 0
    private var channels: [String: SinkChannel] = [:]

    private struct LeaseSnapshot {
        let token: UUID
        let dispatchRevision: Int
        let connectionGeneration: UUID
    }

    private struct AlignmentAck: Equatable {
        let revision: Int
        let field: String
        let submissionID: UUID
    }

    private enum Item {
        /// `lease == nil` is an explicitly lease-free settings command.
        case command(RinaCommand, lease: LeaseSnapshot?, connectionGeneration: UUID, alignment: AlignmentAck? = nil)
        case frame(PackedFrame, Playback, reason: String, lease: LeaseSnapshot)
    }

    /// One outstanding mirror queue for one sink connection. Torn down (and
    /// its worker stopped) whenever that member drops out of the fan-out —
    /// target change, member removal, disconnect, or a reconnect that must
    /// start a fresh channel rather than resume a stale one.
    private final class SinkChannel {
        let id: String
        /// Weak, not `unowned`: the owning `BoardSession` (and its
        /// `connection`) can be removed from `BoardSessionStore` while this
        /// channel is still active (e.g. a session torn down mid group-play);
        /// an `unowned` reference would trap instead of letting the worker
        /// notice and tear the channel down.
        weak var connection: BoardConnection?
        var connectionGeneration: UUID
        /// Bumped on teardown; a running worker compares this against the
        /// value it captured at start and stops once they differ, instead of
        /// requiring a `Task` cancellation race.
        var channelGeneration = 0
        var currentLease: LeaseSnapshot?
        var items: [Item] = []
        var worker: Task<Void, Never>?
        var wake: CheckedContinuation<Void, Never>?
        /// `true` once attach-time alignment (brightness/colour/auto interval
        /// from the primary's `status`) has actually been sent. A sink
        /// attached before the primary's first `status` arrives starts
        /// `false`, and `attachPrimary` retries alignment for it on every
        /// later reconcile until it succeeds (F9).
        var isAligned = false
        var desiredSettingsRevision = 0
        var confirmedSettingsRevision = 0
        var pendingAlignment: [String: RinaCommand] = [:]
        var alignmentSubmissions: [String: UUID] = [:]
        var alignmentAttempts: [String: Int] = [:]
        var alignmentErrors: [String: String] = [:]
        var operationErrors: [String: String] = [:]

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

    /// - Parameter isExplicit: `true` (the default) for a real user choice of
    ///   control target — the only case allowed to force-select a first
    ///   primary when the active board isn't already a member. Pass `false`
    ///   for a launch-time restore of the persisted target, where the active
    ///   board being outside the restored group must leave `primaryID == nil`
    ///   instead (product rule: only explicit choices switch control).
    func setTarget(_ t: ControlTarget, isExplicit: Bool = true) {
        target = t
        if isExplicit { pendingExplicitTargetChange = true }
        reconcile()
    }

    /// Re-derives the primary/sinks from live state. Called on `setTarget`
    /// and re-arms itself via `withObservationTracking` on `sessions.active`,
    /// `groupStore.groups`, and every current target member's
    /// `connectionState`/`connectionGeneration`, so a connect/disconnect or a
    /// group edit re-runs this automatically without any external observer.
    ///
    /// Only ever one observation chain is actually armed: each call bumps
    /// `reconcileEpoch` and captures it, so if `reconcile()` runs again (e.g.
    /// `setTarget` called again) before an older chain's `onChange` fires,
    /// that stale `onChange` recognizes it's no longer current and does
    /// nothing instead of re-arming a second, redundant chain on top of the
    /// fresh one `performReconcile()` already re-armed.
    private var reconcileEpoch = 0

    public func reconcile() {
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
            detachAllSinks()
            primaryID = nil
            return
        }

        // Resolved by the shared `BoardSessionStore.session(matchingGroupMember:)`
        // helper (M3) — the same one `BoardGroupCoordinator.session(for:)`
        // uses — never `BoardSession.boardID` (the session's own persistent
        // slot identity, which is a BLE UUID/host/Bonjour storage id, not the
        // firmware `physicalBoardID`). That helper prefers a currently
        // CONNECTED session's live `boardIdentity`, falling back to
        // `matchesGroupMember(physicalBoardID:)` (which also accepts
        // `lastKnownBoardIdentity`) only when none is connected — sticky
        // because a connection clears its `boardIdentity` the instant it
        // disconnects (`clearBoardSnapshot()`) but keeps
        // `lastKnownBoardIdentity`, so a just-disconnected primary doesn't
        // otherwise silently drop out of `memberSessions` entirely, making it
        // indistinguishable from "the user switched to a board outside this
        // group" below.
        var memberSessions: [(member: BoardGroup.Member, session: BoardSession)] = []
        for member in group.members {
            guard let session = sessions.session(matchingGroupMember: member.physicalBoardID) else { continue }
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

        let wasExplicit = pendingExplicitTargetChange
        pendingExplicitTargetChange = false

        if activeEntry == nil, primaryID != nil {
            // The user navigated to a board outside this group, but not via
            // the "控制对象" menu — an implicit non-member selection (e.g. a
            // Settings board switch) must not silently drop the group as the
            // in-memory target either: only an explicit `setTarget` call may
            // change it (H1/F6). Detach every sink and clear `primaryID` (no
            // board to mirror through right now), but keep `target` pointed
            // at the group so a later re-selection of a member re-attaches
            // through the normal path above instead of requiring the user to
            // re-pick the group from the menu. The persisted "控制对象"
            // selection was never touched either way.
            detachAllSinks()
            primaryID = nil
            return
        }

        guard let next = memberSessions.first(where: { $0.session.connection.connectionState == .connected }) else {
            detachAllSinks()
            primaryID = nil
            return
        }

        if primaryID != nil {
            // The established primary just went offline: primary-disconnect
            // promotion always adopts the next online member, regardless of
            // whether this reconcile was triggered explicitly.
            if let newKey = next.session.connection.boardKey {
                draftPromotionHook?(newKey)
            }
            sessions.select(next.session)
            attachPrimary(member: next.member, session: next.session, memberSessions: memberSessions)
            return
        }

        // No established primary yet. Force-selecting the active board's
        // group's first online member is only correct right after the user
        // explicitly chose this target — never at launch restore, and never
        // on a later automatic reconcile (a member simply reconnecting must
        // not silently switch control onto it).
        guard wasExplicit else {
            primaryID = nil
            return
        }
        sessions.select(next.session)
        attachPrimary(member: next.member, session: next.session, memberSessions: memberSessions)
    }

    private func attachPrimary(
        member: BoardGroup.Member,
        session: BoardSession,
        memberSessions: [(member: BoardGroup.Member, session: BoardSession)]
    ) {
        if primaryID == nil { primaryAutoCheckDone = false }
        primaryID = member.physicalBoardID
        let primaryConnection = session.connection
        primaryConnectionRef = primaryConnection

        // M2: if this is a freshly-established primary (not a promotion —
        // already-manual sink taking over) and it turns out to still be in
        // firmware auto, keep the user's auto intent by starting the synced
        // cycler instead of forcing it to manual. Reading `status` here
        // (even when nil) keeps it tracked by the enclosing
        // `withObservationTracking`, so this retries on the next reconcile
        // once a real `status` arrives, mirroring the `alignSink` F9
        // pattern.
        if !primaryAutoCheckDone, let mode = primaryConnection.status?.renderer?.mode {
            primaryAutoCheckDone = true
            if mode == "auto" { primaryWasAutoHook?() }
        }

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
                if !existing.isAligned { alignSink(existing, primary: primaryConnection) }
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
        alignSink(channel, primary: primary)
    }

    /// Alignment on attach: the same fields `BoardControlCenterModel.sync(from:)`
    /// reads, so a newly attached sink starts matching the primary. The
    /// primary's `status` (and so its `renderer`) can still be nil right
    /// after `attachPrimary` first runs for a freshly connected primary —
    /// reading it here (even when nil) keeps it tracked by the enclosing
    /// `withObservationTracking`, so `attachPrimary` retries this on the
    /// next reconcile once a real `status` arrives, instead of leaving the
    /// sink silently unaligned forever (F9).
    private func alignSink(_ channel: SinkChannel, primary: BoardConnection) {
        guard let renderer = primary.status?.renderer else { return }
        guard channel.pendingAlignment.isEmpty else { return }
        channel.desiredSettingsRevision += 1
        let revision = channel.desiredSettingsRevision
        var settings: [(String, RinaCommand)] = []
        if let brightness = renderer.brightness {
            settings.append(("brightness", .setBrightness(raw: brightness)))
        }
        if let hex = renderer.color {
            settings.append(("color", .setColor(hex: hex)))
        }
        if let ms = renderer.autoIntervalMs {
            settings.append(("autoInterval", .setAutoInterval(ms: ms)))
        }
        // M2: also align firmware mode — a member still free-running its own
        // firmware auto timer must be forced to manual, the same as every
        // other non-Text-tab aspect of this sink, so its display can't drift
        // out of sync with the primary while it isn't yet receiving mirrored
        // frames.
        if channel.connection?.status?.renderer?.mode == "auto" {
            settings.append(("mode", .setMode(mode: "manual")))
        }
        channel.isAligned = settings.isEmpty
        if settings.isEmpty {
            channel.confirmedSettingsRevision = revision
            return
        }
        channel.pendingAlignment = Dictionary(uniqueKeysWithValues: settings)
        channel.alignmentAttempts = Dictionary(uniqueKeysWithValues: settings.map { ($0.0, 1) })
        for (field, command) in settings {
            let submissionID = UUID()
            channel.alignmentSubmissions[field] = submissionID
            enqueueAndWake(
                .command(
                    command,
                    lease: nil,
                    connectionGeneration: channel.connectionGeneration,
                    alignment: AlignmentAck(revision: revision, field: field, submissionID: submissionID)
                ),
                to: channel
            )
        }
    }

    private func detachSink(id: String) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        channel.channelGeneration += 1
        channel.worker?.cancel()
        channel.wake?.resume()
        channel.wake = nil
        if let connection = channel.connection, connection.output.source == .groupControl {
            connection.output.invalidate()
        }
        memberErrors.removeValue(forKey: id)
    }

    private func detachAllSinks() {
        for id in channels.keys { detachSink(id: id) }
        if let primary = primaryConnectionRef, primary.fanOut === self { primary.fanOut = nil }
        primaryConnectionRef = nil
        memberErrors.removeAll()
        primaryAutoCheckDone = false
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
            guard let connection = channel.connection else {
                channel.currentLease = nil
                continue
            }
            channel.currentLease = LeaseSnapshot(
                token: connection.output.claim(.groupControl),
                dispatchRevision: dispatchSeq,
                connectionGeneration: connection.connectionGeneration
            )
        }
        // N2: a paused group still owns its participants' output leases —
        // a control dispatch must supersede it (and clear the paused state)
        // the same as it would a playing one. 4.2: a `play()` still in its
        // upload/clock-sync phase (`isStarting`) hasn't populated
        // `participants`/`activeGroupID` yet, but its captured per-board
        // tokens are already live -- a control dispatch reaching a member
        // mid-start must still supersede it, or that in-flight `play()`
        // would go on to overwrite this claim's frame with its own
        // `group_start`.
        if case .group(let groupID) = target,
           (coordinator.activeGroupID == groupID && (coordinator.isPlaying || coordinator.isPaused))
           || (coordinator.isStarting && coordinator.startingGroupID == groupID) {
            coordinator.markSupersededByControl()
        }
        return dispatchSeq
    }

    public func dispatch(_ cmd: RinaCommand, leased: Bool, from primary: BoardConnection) {
        guard isCurrentPrimary(primary), !channels.isEmpty else { return }
        if leased { claimAllSinksAndBumpSeq() }
        for channel in channels.values {
            guard !leased || channel.currentLease != nil else { continue }
            if !leased,
               let field = alignmentField(for: cmd),
               channel.pendingAlignment[field] != nil {
                // A live user setting supersedes the attach-time value that
                // was awaiting ACK. Make the newer command itself the ACK for
                // this field so a delayed retry cannot restore the old value.
                let alignment = AlignmentAck(
                    revision: channel.desiredSettingsRevision,
                    field: field,
                    submissionID: UUID()
                )
                channel.pendingAlignment[field] = cmd
                channel.alignmentSubmissions[field] = alignment.submissionID
                channel.alignmentAttempts[field] = 1
                channel.items.removeAll { item in
                    guard case .command(_, _, _, let queuedAlignment) = item else { return false }
                    return queuedAlignment?.revision == alignment.revision
                        && queuedAlignment?.field == alignment.field
                }
                refreshMemberError(channel)
                enqueueAndWake(
                    .command(
                        cmd,
                        lease: nil,
                        connectionGeneration: channel.connectionGeneration,
                        alignment: alignment
                    ),
                    to: channel
                )
                continue
            }
            enqueueAndWake(
                .command(
                    cmd,
                    lease: leased ? channel.currentLease : nil,
                    connectionGeneration: channel.connectionGeneration
                ),
                to: channel
            )
        }
    }

    public func dispatchFrame(_ packed: PackedFrame, playback: Playback, reason: String, from primary: BoardConnection) {
        guard isCurrentPrimary(primary), !channels.isEmpty else { return }
        claimAllSinksAndBumpSeq()
        for channel in channels.values {
            guard let lease = channel.currentLease else { continue }
            enqueueAndWake(.frame(packed, playback, reason: reason, lease: lease), to: channel)
        }
    }

    public func beginLeasedAction(from primary: BoardConnection) -> Int? {
        guard isCurrentPrimary(primary), !channels.isEmpty else { return nil }
        return claimAllSinksAndBumpSeq()
    }

    public func primaryFaceApplied(reply: CommandReply, original: RinaCommand, ticket: Int, from primary: BoardConnection) {
        guard isCurrentPrimary(primary), ticket == dispatchSeq else { return }
        if let resolved = faceFrameResolver?(primary, reply) {
            for channel in channels.values {
                guard let lease = channel.currentLease, lease.dispatchRevision == ticket else { continue }
                enqueueAndWake(.frame(resolved, .idle, reason: "group_control_face", lease: lease), to: channel)
            }
            return
        }
        // No resolver, or it returned nil: never replay the original
        // apply_saved_face/B1/B2 verbatim — a sink's own (unsynced) face
        // library may not share the id/index, so it would end up showing a
        // different face than the primary. Instead read back the primary's
        // own resulting frame once the apply has settled and mirror that
        // bitmap; if that also fails, record a per-sink error rather than
        // guess.
        Task { @MainActor [weak self, weak primary] in
            guard let self, let primary else { return }
            if let frame = await self.primaryFrameAfterApply(primary: primary, ticket: ticket) {
                guard self.isCurrentPrimary(primary), ticket == self.dispatchSeq else { return }
                for channel in self.channels.values {
                    guard let lease = channel.currentLease, lease.dispatchRevision == ticket else { continue }
                    self.enqueueAndWake(.frame(frame, .idle, reason: "group_control_face", lease: lease), to: channel)
                }
            } else {
                guard self.isCurrentPrimary(primary), ticket == self.dispatchSeq else { return }
                for channel in self.channels.values {
                    channel.operationErrors["face"] = NSLocalizedString("未能同步表情", comment: "group control sink face sync failed")
                    self.refreshMemberError(channel)
                }
            }
        }
    }

    /// Reads the primary's current frame after its `apply_saved_face`/B1/B2
    /// reply resolved to no bitmap, waiting for the apply to settle first
    /// (small delay/retry acceptable: a fresh `get_frame` immediately after
    /// the apply can race the firmware's own render). One retry; `nil` if
    /// both attempts fail or this primary/ticket is no longer current.
    private func primaryFrameAfterApply(primary: BoardConnection, ticket: Int) async -> PackedFrame? {
        for _ in 0..<2 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard isCurrentPrimary(primary), ticket == dispatchSeq else { return nil }
            if let frame = try? await primary.getFrame() { return frame }
        }
        return nil
    }

    // MARK: - Per-sink queue / worker

    private func coalesceKey(for cmd: RinaCommand) -> String? {
        if case .verbatim(let key) = cmd.groupFanOutPolicy { return key }
        return nil
    }

    private func alignmentField(for cmd: RinaCommand) -> String? {
        switch cmd {
        case .setBrightness: return "brightness"
        case .setColor: return "color"
        case .setAutoInterval: return "autoInterval"
        case .setMode: return "mode"
        default: return nil
        }
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
        case .command(let cmd, _, _, let alignment):
            if alignment == nil, let key = coalesceKey(for: cmd),
               let idx = channel.items.firstIndex(where: {
                   if case .command(let queued, _, _, let queuedAlignment) = $0 {
                       return queuedAlignment == nil && coalesceKey(for: queued) == key
                   }
                   return false
               }) {
                // Coalescing replaces the earlier same-key entry, but moves
                // to the end: its relative order against every other queued
                // command must reflect when this newer value arrived, not
                // where the stale one happened to sit.
                channel.items.remove(at: idx)
                channel.items.append(item)
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
            } else if let idx = channel.items.firstIndex(where: {
                if case .command(_, _, _, alignment: nil) = $0 { return true }
                return false
            }) {
                channel.items.remove(at: idx)
            } else {
                let dropped = channel.items.removeFirst()
                if case .command(_, _, _, let alignment) = dropped,
                   let alignment,
                   isCurrent(alignment, for: channel) {
                    channel.alignmentErrors[alignment.field] = NSLocalizedString(
                        "同步队列已满",
                        comment: "group control alignment queue full"
                    )
                    scheduleAlignmentRetry(alignment, channel: channel)
                    refreshMemberError(channel)
                }
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
            if channel.connection == nil {
                // The sink's session was torn down (e.g. removed from
                // `BoardSessionStore`) out from under a still-active channel;
                // there is nothing left to mirror to.
                detachSink(id: channel.id)
                return
            }
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
        guard let connection = channel.connection else {
            detachSink(id: channel.id)
            return
        }
        do {
            switch item {
            case .command(let cmd, let lease, let connectionGeneration, let alignment):
                guard connectionGeneration == channel.connectionGeneration,
                      connection.connectionGeneration == connectionGeneration else { return }
                if let lease {
                    guard isCurrent(lease, for: channel, connection: connection) else {
                        dropQueuedItems(channel, for: lease)
                        return
                    }
                    _ = try await connection.withOutput(lease.token) { try await connection.command(cmd) }
                } else {
                    _ = try await connection.command(cmd)
                }
                guard channel.channelGeneration == myGeneration else { return }
                completeSuccess(alignment: alignment, operationKey: "command:\(cmd.name)", channel: channel)
            case .frame(let packed, let playback, let reason, let lease):
                guard isCurrent(lease, for: channel, connection: connection) else {
                    dropQueuedItems(channel, for: lease)
                    return
                }
                _ = try await connection.setFrame(packed, playback: playback, reason: reason, outputSession: lease.token)
                guard channel.channelGeneration == myGeneration else { return }
                channel.operationErrors.removeValue(forKey: "frame")
                refreshMemberError(channel)
            }
        } catch {
            guard channel.channelGeneration == myGeneration else { return }
            if error is CancellationError { return }
            if case .command(_, _, _, let alignment) = item, let alignment {
                guard isCurrent(alignment, for: channel) else { return }
                channel.alignmentErrors[alignment.field] = error.localizedDescription
                scheduleAlignmentRetry(alignment, channel: channel)
            } else {
                if case RatePumpError.dropped = error { return }
                channel.operationErrors[operationKey(for: item)] = error.localizedDescription
            }
            refreshMemberError(channel)
        }
    }

    private func isCurrent(_ lease: LeaseSnapshot, for channel: SinkChannel, connection: BoardConnection) -> Bool {
        channel.currentLease?.token == lease.token
            && channel.connectionGeneration == lease.connectionGeneration
            && connection.connectionGeneration == lease.connectionGeneration
            && connection.output.isCurrent(lease.token)
    }

    /// Drops only work captured from the same stale lease. A later dispatch
    /// may already have installed a fresh lease and must remain queued.
    private func dropQueuedItems(_ channel: SinkChannel, for staleLease: LeaseSnapshot) {
        channel.items.removeAll { item in
            switch item {
            case .frame(_, _, _, let lease):
                return lease.token == staleLease.token
            case .command(_, let lease, _, _):
                return lease?.token == staleLease.token
            }
        }
    }

    private func completeSuccess(alignment: AlignmentAck?, operationKey: String, channel: SinkChannel) {
        guard let alignment else {
            channel.operationErrors.removeValue(forKey: operationKey)
            refreshMemberError(channel)
            return
        }
        guard isCurrent(alignment, for: channel) else { return }
        channel.pendingAlignment.removeValue(forKey: alignment.field)
        channel.alignmentSubmissions.removeValue(forKey: alignment.field)
        channel.alignmentAttempts.removeValue(forKey: alignment.field)
        channel.alignmentErrors.removeValue(forKey: alignment.field)
        if channel.pendingAlignment.isEmpty {
            channel.confirmedSettingsRevision = alignment.revision
            channel.isAligned = true
        }
        refreshMemberError(channel)
    }

    private func scheduleAlignmentRetry(_ alignment: AlignmentAck, channel: SinkChannel) {
        guard isCurrent(alignment, for: channel),
              channel.pendingAlignment[alignment.field] != nil else { return }
        let attempt = channel.alignmentAttempts[alignment.field, default: 1]
        guard attempt < 3 else { return }
        channel.alignmentAttempts[alignment.field] = attempt + 1
        let channelGeneration = channel.channelGeneration
        let connectionGeneration = channel.connectionGeneration
        let delay = UInt64(attempt) * 100_000_000
        Task { @MainActor [weak self, weak channel] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, let channel,
                  channel.channelGeneration == channelGeneration,
                  channel.connectionGeneration == connectionGeneration,
                  self.isCurrent(alignment, for: channel),
                  let command = channel.pendingAlignment[alignment.field] else { return }
            self.enqueueAndWake(
                .command(
                    command,
                    lease: nil,
                    connectionGeneration: connectionGeneration,
                    alignment: alignment
                ),
                to: channel
            )
        }
    }

    private func refreshMemberError(_ channel: SinkChannel) {
        var errors = channel.alignmentErrors.keys.sorted().compactMap { channel.alignmentErrors[$0] }
        errors.append(contentsOf: channel.operationErrors.keys.sorted().compactMap { channel.operationErrors[$0] })
        if errors.isEmpty {
            memberErrors.removeValue(forKey: channel.id)
        } else {
            memberErrors[channel.id] = errors.joined(separator: "\n")
        }
    }

    private func isCurrent(_ alignment: AlignmentAck, for channel: SinkChannel) -> Bool {
        alignment.revision == channel.desiredSettingsRevision
            && channel.alignmentSubmissions[alignment.field] == alignment.submissionID
    }

    private func operationKey(for item: Item) -> String {
        switch item {
        case .frame: return "frame"
        case .command(let command, _, _, _): return "command:\(command.name)"
        }
    }
}
