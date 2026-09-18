import Foundation
import RinaCore

/// Drives a `BoardGroup`'s live behaviour (BOARD_GROUP_SPEC.md §3): resolves
/// members to connected `BoardSession`s, runs the identify overlay loop, and
/// runs `play`/`stop`/re-anchoring. Holds no UI; a separate session builds
/// the screens on top of this.
@Observable
@MainActor
public final class BoardGroupCoordinator {
    /// Per-member live status, keyed by `physicalBoardID`.
    public enum MemberStatus: Equatable, Sendable {
        case offline
        case connected
        /// Missing one or more of the four board-group caps.
        case unsupported
        case uploading(progress: Double)
        case ready
        case playing
        case error(String)
    }

    public enum GroupPlayError: Error, Sendable, Equatable, LocalizedError {
        case tooFewMembers
        case offlineMembers([String])
        case unsupportedMembers([String])
        case aborted
        case buildFailed(String)

        public var errorDescription: String? {
            switch self {
            case .tooFewMembers: return "至少需要 2 块板"
            case .offlineMembers(let names):
                return "有板子离线：\(names.joined(separator: "、"))"
            case .unsupportedMembers(let names):
                return "以下面板固件过旧，不支持多板组：\(names.joined(separator: "、"))"
            case .aborted: return "多板组已变化，播放已取消"
            case .buildFailed(let message): return message
            }
        }
    }

    /// A board that successfully joined the currently-running play (via
    /// `play()` or a re-anchor rejoin): the exact session/generation/bootId
    /// it joined with, and the output-lease token it holds. Re-anchoring may
    /// only touch a board while its live state still matches this record —
    /// it must never call `output.claim`/`begin` itself (C1: re-anchor must
    /// never steal a board).
    private struct Participant {
        let member: BoardGroup.Member
        let session: BoardSession
        var generation: UUID
        var bootId: String
        var token: UUID
    }

    /// One member resolved to a connected session at `play()` time.
    private struct CapturedMember {
        let member: BoardGroup.Member
        let slot: Int
        let session: BoardSession
        let generation: UUID
    }

    /// Everything a re-anchor rejoin needs to re-upload the same bitmap to a
    /// board that missed the original `play()` upload (reconnected with a
    /// new generation or bootId).
    private struct PlayState {
        let bitmap: ScrollBitmap
        let layout: StitchedScreenLayout
        let mode: BoardGroup.Mode
        let virtualWidth: Int
        let fps: Int
        let timelineId: String
        let sourceText: String
        let loop: Bool
        /// The member order captured at `play()` time, used to look up each
        /// board's slot (and so its `viewportX`) during a rejoin.
        let memberOrder: [BoardGroup.Member]
    }

    private let store: BoardGroupStore
    private let sessions: BoardSessionStore
    /// Injectable monotonic microsecond clock, so tests can script it.
    private let nowUs: @Sendable () -> Int64
    private let loadFont: () async throws -> ArkPixelFont

    public private(set) var memberStatus: [String: MemberStatus] = [:]
    public private(set) var activeGroupID: UUID?
    public private(set) var isPlaying = false
    /// `true` between a successful `pause()` and the next `resume()`/`stop()`/
    /// `play()` — app-level group pause (no firmware timed-pause support,
    /// BOARD_GROUP_SPEC.md §1.5): every participant sits on `pausedFrame` via
    /// `pause_scroll` + `scroll_seek`, exited on `resume()`/`step()`.
    public private(set) var isPaused = false
    /// The global frame index every participant is seeked to while
    /// `isPaused` — the base `step()` nudges and `resume()` restarts from.
    public private(set) var pausedFrame = 0
    /// `true` from the moment a `play()` call starts uploading/clock-sampling
    /// until it either starts playing or aborts — lets the Text tab show its
    /// send pill's uploading spinner for a group the same way it does for a
    /// single board, before `isPlaying` flips (BOARD_GROUP_SPEC.md §3).
    public private(set) var isStarting = false
    /// The group a `play()` currently in flight (`isStarting`) targets, so a
    /// UI watching a *different* group doesn't show its spinner.
    public private(set) var startingGroupID: UUID?
    /// Whether re-anchoring should keep running; set from `RinaBoardApp` via
    /// `scenePhase` (BOARD_GROUP_SPEC §3 "while the app is active"). Going
    /// inactive only pauses re-anchor passes, it never ends playback.
    public var isAppActive = true

    private var estimators: [String: ClockOffsetEstimator] = [:]
    private var identifyTask: Task<Void, Never>?
    private var reanchorTask: Task<Void, Never>?
    private var currentAnchor: (phoneUs: Int64, startFrame: Int, intervalMs: Int, loop: Bool)?
    private var participants: [String: Participant] = [:]
    private var playState: PlayState?
    /// The `(groupID, layoutRevision, playEpoch)` a successful `play()` was
    /// last started with — frozen for `debugReanchorNow()` and re-anchoring,
    /// so a later live read of the group's revision can't defeat the
    /// staleness checks in `reanchor(groupID:revision:epoch:)` (B4/N3).
    private var activeRevision: Int?
    private var activeEpoch: Int?
    /// Members dropped from `participants` because something else took over
    /// their output lease (source changed away from `.group`) rather than
    /// because their connection generation/bootId changed. These must never
    /// be auto-rejoined — that would steal the board back from whatever
    /// single-board action now owns it (N1). Cleared at the start of the
    /// next `play()`.
    private var evictedByOwnership: Set<String> = []
    /// Bumped every `stop()`/`play()`; a `play()` call captures it and
    /// refuses to act (and its re-anchor loop refuses to run) once it no
    /// longer matches.
    private var playEpoch = 0
    /// Bumped synchronously (before any await) by `pause()`, `resume()`,
    /// `step()`, and `stop()` — separate from `playEpoch` (which changes
    /// only on `play()`/`stop()`/`markSupersededByControl()`, and which
    /// `resume()`/`step()` still need unchanged to validate against
    /// `activeEpoch`). Lets a pause/resume/step call invalidate an
    /// in-flight `reanchor()`/`rejoin()`/`updatePlayback()` pass — which
    /// captures this at its own start and rechecks it after every await,
    /// immediately before sending any `group_start` — without disturbing
    /// those play-time guards (B1: an in-flight re-anchor must never
    /// outlive a pause).
    private var controlGeneration = 0
    /// Serializes `pause()`/`resume()`/`step()` so overlapping taps can't
    /// send different frame indices to different boards (N5): a
    /// `pause()`/`resume()` call made while one is already in flight is
    /// ignored outright; a `step()` call made while one is in flight has
    /// its `direction` coalesced into `pendingStepDirection` and applied
    /// (as one further step) once the in-flight call finishes.
    private var isControlBusy = false
    private var pendingStepDirection = 0
    /// The board IDs the latest `play()` attempt claimed output leases for
    /// (set synchronously alongside `tokens` when it claims them, before the
    /// upload/clock-sync phases even start — so it already covers an
    /// in-flight `isStarting` attempt, not just a fully joined one).
    /// `claim(.group)` on a board whose source is already `.group` returns
    /// the SAME token a stale attempt's own captured `tokens` map still
    /// holds, so token equality alone can never tell a newer attempt's claim
    /// on a reused board apart from a stale attempt's own claim on it — this
    /// set is what `stop()`/`abortStartedBoards` consult instead, to never
    /// touch a board a newer attempt has claimed while still acting on every
    /// other board a stale attempt legitimately owns (cross-group stop).
    /// Cleared when the attempt owning it (matching `playEpoch`) finishes its
    /// own `stop()`/`abortStartedBoards`/`markSupersededByControl` pass, or
    /// overwritten wholesale by the next `play()`'s own claim.
    private var claimedBoardIDs: Set<String> = []

    public init(
        store: BoardGroupStore,
        sessions: BoardSessionStore,
        nowUs: @escaping @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1000) },
        loadFont: @escaping () async throws -> ArkPixelFont = BoardGroupCoordinator.loadDefaultFont
    ) {
        self.store = store
        self.sessions = sessions
        self.nowUs = nowUs
        self.loadFont = loadFont
    }

    public static func loadDefaultFont() throws -> ArkPixelFont {
        guard let url = Bundle.main.url(forResource: "ark12", withExtension: "json") else {
            throw RinaTransportError.underlying("字体资源缺失")
        }
        return try ArkPixelFont.loadBundled(url: url)
    }

    // MARK: - Member resolution

    /// Resolves `member` to its session, if any, via the shared
    /// `BoardSessionStore.session(matchingGroupMember:)` helper (M3) —
    /// `BoardConnection.boardIdentity` of a CONNECTED session first, or
    /// (falling back, including once cleared by a disconnect) the last
    /// identity that connection ever reported — never BLE UUID, host, name,
    /// or `boardID`. Resolves offline-but-known sessions too (for
    /// status/promotion); callers that need "and currently online" must check
    /// `connection.connectionState` themselves. `GroupControlFanOut` uses the
    /// same helper, so the two callers can never disagree about which
    /// session a member resolves to.
    public func session(for member: BoardGroup.Member) -> BoardSession? {
        sessions.session(matchingGroupMember: member.physicalBoardID)
    }

    public func status(for member: BoardGroup.Member) -> MemberStatus {
        // 4.4: a board that has actually gone offline must read `.offline`
        // even if `memberStatus` still holds a stale `.playing`/`.uploading`
        // entry from before the disconnect (cleared lazily, on the next
        // prune/reanchor/rejoin pass that happens to touch it) -- never a UI
        // that goes on showing an offline board as still playing.
        guard let session = session(for: member), session.connection.connectionState == .connected else {
            return .offline
        }
        return memberStatus[member.physicalBoardID] ?? computeIdleStatus(for: member)
    }

    /// N6: the send pill's determinate upload progress while `group` is
    /// uploading (`isStarting`/`startingGroupID` — the group-play upload
    /// phase): the average of every member's own `.uploading(progress:)`
    /// status, or `nil` if none are currently uploading (so the caller falls
    /// back to an indeterminate spinner instead of a stuck 0% ring).
    public func uploadProgress(for group: BoardGroup) -> Double? {
        let progresses: [Double] = group.members.compactMap {
            if case .uploading(let progress) = memberStatus[$0.physicalBoardID] { return progress }
            return nil
        }
        guard !progresses.isEmpty else { return nil }
        return progresses.reduce(0, +) / Double(progresses.count)
    }

    private func computeIdleStatus(for member: BoardGroup.Member) -> MemberStatus {
        guard let session = session(for: member), session.connection.connectionState == .connected else {
            return .offline
        }
        guard hasAllCaps(session.connection) else { return .unsupported }
        return .connected
    }

    /// The four caps every board-group feature requires. `.group60Fps` is
    /// deliberately excluded — it's an optional speed upgrade
    /// (`maxFps(for:)`/`groupIntervalMs(forFps:)`), not a baseline
    /// requirement, so a board that lacks it must still read `.connected`/
    /// join a group, just capped at the legacy 50 fps.
    private static let requiredCaps: [BoardCapability] = [.identify, .clockSample, .scrollViewport, .groupStart]

    private func hasAllCaps(_ connection: BoardConnection) -> Bool {
        Self.requiredCaps.allSatisfy(connection.supports)
    }

    /// `true` iff `session`'s output lease is currently held by a group
    /// (BOARD_GROUP_SPEC §3): `BoardSessionStore.select(_:)` must not
    /// invalidate it. Reads `BoardPlaybackCoordinator.source` directly —
    /// the single source of truth — rather than a separately tracked set, so
    /// any single-board action that claims a different output source on this
    /// board (which changes `source` itself) automatically ends group
    /// ownership without the coordinator having to notice.
    public func isGroupOwned(_ session: BoardSession) -> Bool {
        session.connection.output.source == .group
    }

    // MARK: - Identify

    /// Sends `identify{number: slot+1, ttlMs}` to every connected member of
    /// `group`, in its current order.
    public func identifyAll(_ group: BoardGroup, ttlMs: Int = 5000) async {
        for (slot, member) in group.members.enumerated() {
            guard let session = session(for: member), session.connection.connectionState == .connected,
                  session.connection.supports(.identify) else { continue }
            _ = try? await session.connection.requestReliable(.identify(number: slot + 1, ttlMs: ttlMs))
        }
    }

    /// Re-sends `identifyAll` every 4s (BOARD_GROUP_SPEC §3), for as long as
    /// the layout editor for `group` stays open. Call `stopIdentifyLoop()`
    /// when it closes.
    public func startIdentifyLoop(for group: BoardGroup) {
        identifyTask?.cancel()
        let groupID = group.id
        identifyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Re-read from the store each pass rather than closing over
                // the `group` snapshot: a reorder while the loop is running
                // must be reflected in the next `identify{number:}` burst.
                if let live = self.store.groups.first(where: { $0.id == groupID }) {
                    await self.identifyAll(live)
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    public func stopIdentifyLoop(for group: BoardGroup) {
        stopIdentifyLoop()
        Task { [weak self] in
            guard let self else { return }
            for member in group.members {
                guard let session = self.session(for: member), session.connection.connectionState == .connected,
                      session.connection.supports(.identify) else { continue }
                _ = try? await session.connection.requestReliable(.identify(number: 1, ttlMs: 0))
            }
        }
    }

    /// Unconditional cancel of the polling task, with no group needed — safe
    /// to call from a view's `onDisappear` even after the group itself was
    /// deleted while the editor was open (N4).
    public func stopIdentifyLoop() {
        identifyTask?.cancel()
        identifyTask = nil
    }

    // MARK: - Play

    /// 4.1: firmware `group_start` rejects `intervalMs < 20`
    /// (`RinaLinkConstants.groupStartIntervalMsMinLegacy`) — every
    /// `group_start` this coordinator ever sends (`play()`,
    /// `updatePlayback()`) must clamp to that floor rather than pass through
    /// whatever `ScrollRasterizer.intervalMs(forFps:)` computes for a
    /// >50fps request. `capable` lifts the floor to `intervalMinMs` (17,
    /// 60 fps) — the caller must pass `true` only when EVERY board this
    /// specific command is about to reach (not the group's full, possibly-
    /// offline membership) advertises `group_60fps` (BOARD_GROUP_SPEC §1.1).
    private func groupIntervalMs(forFps fps: Int, capable: Bool) -> Int {
        let floor = capable ? RinaLinkConstants.intervalMinMs : RinaLinkConstants.groupStartIntervalMsMinLegacy
        return max(floor, ScrollRasterizer.intervalMs(forFps: fps))
    }

    /// The fastest fps `group`'s currently-connected members support in
    /// concert: 60 if every connected member advertises `group_60fps`,
    /// else the legacy 50 fps cap. A group with no members connected yet
    /// reads 60 (display-only default; the actual floor used by
    /// `play()`/`updatePlayback()` is always recomputed from the boards
    /// really being sent to, never from this display value).
    public func maxFps(for group: BoardGroup) -> Int {
        let connected = group.members.compactMap { session(for: $0) }
            .filter { $0.connection.connectionState == .connected }
        guard !connected.isEmpty else { return RinaLinkConstants.scrollFpsMax }
        return connected.allSatisfy { $0.connection.supports(.group60Fps) }
            ? RinaLinkConstants.scrollFpsMax
            : RinaLinkConstants.groupScrollFpsMaxLegacy
    }

    /// Builds one group bitmap, uploads it to every member concurrently,
    /// clock-samples every member, and starts synchronized playback
    /// (BOARD_GROUP_SPEC §3). Captures `(group.id, group.layoutRevision,
    /// each member's session + connection generation)` up front; if any of
    /// those changes after an `await`, aborts and reports instead of writing
    /// to the group. Requires every member online and supported (L2): a
    /// group never plays with a silently-skipped gap.
    public func play(group: BoardGroup, text: String, fps: Int, loop: Bool) async throws {
        try await startGroup(group: group, text: text, fps: fps, loop: loop, startFrame: 0, adoption: nil)
    }

    /// Whether a board reports a scroll timeline loaded or running.
    static func isScrolling(_ connection: BoardConnection) -> Bool {
        let renderer = connection.status?.renderer
        if let count = renderer?.scrollFrameCount, count > 0 { return true }
        return (renderer?.firmwareScrollActive ?? connection.preview?.firmwareScrollActive) == true
    }

    /// Some member of `group` is still scrolling although this coordinator
    /// isn't driving the group (state lost to a relaunch or reconnect). The
    /// Text tab keeps Stop available for exactly this case.
    public func hasOrphanedScroll(group: BoardGroup) -> Bool {
        guard !(activeGroupID == group.id && (isPlaying || isPaused)) else { return false }
        return group.members.contains { member in
            guard let session = session(for: member), session.connection.connectionState == .connected else { return false }
            let source = session.connection.output.source
            return (source == nil || source == .group) && Self.isScrolling(session.connection)
        }
    }

    /// Takes back control of `group`'s scroll after an app relaunch or a
    /// reconnect wiped this coordinator's in-memory state while the boards
    /// kept playing their `group_start` schedule. Every member must be
    /// connected and report the same group-timed timeline, text, length and
    /// rate; the text is rebuilt with the current layout and must produce the
    /// same frame count. On success the group is playing (or paused, if the
    /// boards were) from where the boards are, with no re-upload. Returns
    /// whether it adopted; a no-op while this coordinator already drives or
    /// is starting anything.
    @discardableResult
    public func adoptRunningScroll(group: BoardGroup) async -> Bool {
        guard !isStarting, !(isPlaying || isPaused),
              group.members.count >= BoardGroup.minMembersToPlay else { return false }
        var metas: [ScrollMeta] = []
        for member in group.members {
            guard let session = session(for: member), session.connection.connectionState == .connected,
                  hasAllCaps(session.connection),
                  let meta = try? await session.connection.getScrollMeta() else { return false }
            metas.append(meta)
        }
        let readAt = nowUs()
        guard let first = metas.first,
              let timelineId = first.scrollTimelineId, !timelineId.isEmpty,
              let text = first.sourceText, !text.isEmpty,
              let frameCount = first.frameCount, frameCount > 0,
              let intervalMs = first.scrollIntervalMs, intervalMs > 0,
              metas.allSatisfy({
                  $0.groupTimed == true && $0.firmwareScrollActive == true
                      && $0.scrollTimelineId == timelineId && $0.sourceText == text
                      && $0.frameCount == frameCount && $0.scrollIntervalMs == intervalMs
              }) else { return false }
        // Re-checked after the awaits above: someone may have started a play.
        guard !isStarting, !(isPlaying || isPaused),
              let live = store.groups.first(where: { $0.id == group.id }) else { return false }
        let wasPaused = first.firmwareScrollPaused == true
        let fps = max(1, Int((1000.0 / Double(intervalMs)).rounded()))
        do {
            try await startGroup(
                group: live, text: text, fps: fps, loop: first.scrollLoop ?? true, startFrame: 0,
                adoption: Adoption(timelineId: timelineId, frameCount: frameCount,
                                   frameIndex: first.frameIndex ?? 0, readAtPhoneUs: wasPaused ? .max : readAt)
            )
        } catch {
            return false
        }
        if wasPaused { await pause(group: live) }
        return isPlaying || isPaused
    }

    /// A group scroll that is already running on every member (left behind
    /// by an app relaunch or a BLE drop), to be taken over without
    /// re-uploading: the boards keep their timeline and are re-anchored in
    /// step from `startFrame`.
    private struct Adoption {
        let timelineId: String
        let frameCount: Int
        /// Where the boards were (`frameIndex` from their scroll meta) and
        /// when that was read, so the anchor can be projected forward.
        let frameIndex: Int
        let readAtPhoneUs: Int64
    }

    private func startGroup(
        group: BoardGroup, text: String, fps: Int, loop: Bool, startFrame: Int, adoption: Adoption?
    ) async throws {
        let capturedGroupID = group.id
        let capturedRevision = group.layoutRevision
        guard group.members.count >= BoardGroup.minMembersToPlay else { throw GroupPlayError.tooFewMembers }

        // 4.4: every preflight step -- online/caps resolution, layout, font
        // load, bitmap build -- runs *before* any of this coordinator's own
        // state is touched. A failed `play()` (bad text, missing font, an
        // offline member) must never strand a still-running previous play by
        // wiping its state first and only then discovering the new attempt
        // can't proceed.
        var online: [CapturedMember] = []
        var offlineNames: [String] = []
        var unsupportedNames: [String] = []
        for (slot, member) in group.members.enumerated() {
            guard let session = session(for: member), session.connection.connectionState == .connected else {
                offlineNames.append(member.displayName)
                continue
            }
            guard hasAllCaps(session.connection) else {
                unsupportedNames.append(member.displayName)
                continue
            }
            online.append(CapturedMember(member: member, slot: slot, session: session, generation: session.connection.connectionGeneration))
        }
        guard offlineNames.isEmpty else { throw GroupPlayError.offlineMembers(offlineNames) }
        guard unsupportedNames.isEmpty else { throw GroupPlayError.unsupportedMembers(unsupportedNames) }

        // Re-checked after the font-load await (and again just below, after
        // building the bitmap) -- neither touches any of this coordinator's
        // state, so "not still valid" here just means throwing `.aborted`
        // rather than releasing anything.
        func preflightStillValid() -> Bool {
            guard let live = store.groups.first(where: { $0.id == capturedGroupID }),
                  live.layoutRevision == capturedRevision else { return false }
            for captured in online {
                guard captured.session.connection.connectionState == .connected,
                      captured.session.connection.connectionGeneration == captured.generation else { return false }
            }
            return true
        }

        guard let layout = try? StitchedScreenLayout(slotCount: group.members.count, gapsAfter: group.gapsAfter) else {
            throw GroupPlayError.buildFailed("布局无效")
        }
        let mode = group.mode
        let virtualWidth = mode == .mirror ? MatrixGeometry.cols : layout.virtualWidth
        let font: ArkPixelFont
        do {
            font = try await loadFont()
        } catch {
            throw GroupPlayError.buildFailed(error.localizedDescription)
        }
        guard preflightStillValid() else { throw GroupPlayError.aborted }
        let bitmap: ScrollBitmap
        do {
            bitmap = try GroupScrollBitmap.build(text: text, font: font, virtualWidth: virtualWidth)
        } catch {
            throw GroupPlayError.buildFailed("\(error)")
        }
        guard preflightStillValid() else { throw GroupPlayError.aborted }
        if let adoption {
            // Taking over only works if this layout and text rebuild exactly
            // the timeline the boards are playing.
            let builtFrames = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: virtualWidth)
            guard builtFrames == adoption.frameCount else { throw GroupPlayError.aborted }
        }

        // Part B: whatever the previous attempt/active group was doing —
        // playing, paused, or itself mid-`play()` — snapshot the boards it
        // was driving (`claimedBoardIDs` covers a still-`isStarting` attempt
        // too, `participants` covers a fully joined one) before any of that
        // gets torn down below. Diffed against this new group's own
        // membership once its own claim lands (below), and stopped
        // concurrently with the new upload (`stopBoardsNotInNewGroup`).
        let previouslyClaimedIDs = claimedBoardIDs.union(participants.keys)

        // B4: a fresh play supersedes whatever the previous one was doing.
        // No `stop_scroll` here — the upload below replaces the timeline on
        // every board it reaches — but the old re-anchor loop, participant
        // set, and anchor must not keep acting once this one has started.
        // Everything above this point was read-only; only now (with every
        // preflight check already satisfied) does this attempt start
        // touching state a failure would need to unwind.
        playEpoch += 1
        reanchorTask?.cancel()
        reanchorTask = nil
        participants.removeAll()
        currentAnchor = nil
        playState = nil
        isPlaying = false
        isPaused = false
        pausedFrame = 0
        evictedByOwnership.removeAll()

        let capturedEpoch = playEpoch

        // 4.2: one output-lease token per board, claimed synchronously here
        // (no `await` since the previous statement) and reused at every site
        // below that touches these boards' output — upload, `group_start`,
        // and the `Participant` records. `play()` itself must never call
        // `output.claim` again after this point: a manual claim that lands
        // on one of these boards during the clock-sync phase changes its
        // `output.source`/session away from what's captured here, and
        // `stillValid()` below is what must catch that — re-claiming inside
        // `play()` would instead silently take the board back and paper over
        // the takeover.
        var tokens: [String: UUID] = [:]
        for captured in online {
            tokens[captured.member.physicalBoardID] = captured.session.connection.output.claim(.group)
        }
        claimedBoardIDs = Set(tokens.keys)

        // Part B: starting this group must stop any board a previous group
        // was driving that isn't a member of THIS one — run concurrently
        // (unstructured Task, never awaited here) so it can never delay this
        // group's own upload/start. `stopBoardsNotInNewGroup` re-checks
        // `claimedBoardIDs` itself (which is already this new group's own
        // set as of the line above) before touching anything, so a board a
        // later `play()` claims while this cleanup is still in flight is
        // never stepped on.
        let boardsToStop = previouslyClaimedIDs.subtracting(claimedBoardIDs)
        if !boardsToStop.isEmpty {
            Task { [weak self] in await self?.stopBoardsNotInNewGroup(boardsToStop) }
        }

        func stillValid() -> Bool {
            guard playEpoch == capturedEpoch else { return false }
            guard let live = store.groups.first(where: { $0.id == capturedGroupID }),
                  live.layoutRevision == capturedRevision else { return false }
            for captured in online {
                guard captured.session.connection.connectionState == .connected,
                      captured.session.connection.connectionGeneration == captured.generation,
                      let token = tokens[captured.member.physicalBoardID],
                      captured.session.connection.output.source == .group,
                      captured.session.connection.output.isCurrent(token) else { return false }
            }
            return true
        }

        let timelineId = adoption?.timelineId ?? UUID().uuidString

        // B3: from the upload phase through the final `group_start`, one
        // do/catch. Any throw here — upload failure, a `stillValid()` abort,
        // a clock-phase failure, H5's missing-command guard, or H3's
        // partial-start guard — must release every board this attempt
        // touched, not just the ones reached by the last sub-phase.
        isStarting = true
        startingGroupID = capturedGroupID
        do {
            // Upload concurrently, each board's own (already-claimed) output
            // lease. Skipped when adopting: every board already holds this
            // timeline.
            if adoption == nil {
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for captured in online {
                    let viewportX = self.viewportX(for: captured.slot, mode: mode, layout: layout)
                    let token = tokens[captured.member.physicalBoardID]!
                    taskGroup.addTask { @MainActor in
                        self.memberStatus[captured.member.physicalBoardID] = .uploading(progress: 0)
                        do {
                            try await captured.session.connection.withOutput(token) {
                                _ = try await captured.session.connection.uploadGroupScrollBitmap(
                                    bitmap: bitmap, viewportX: viewportX, virtualWidth: virtualWidth,
                                    fps: fps, timelineId: timelineId, sourceText: text, start: false,
                                    onProgress: { progress in
                                        self.memberStatus[captured.member.physicalBoardID] = .uploading(progress: progress)
                                    }
                                )
                            }
                        } catch {
                            // Member-scoped failure: recorded so the play panel can
                            // show which board failed, in addition to the throw
                            // that aborts the whole `play()` (BOARD_GROUP_SPEC §3).
                            self.memberStatus[captured.member.physicalBoardID] = .error(error.localizedDescription)
                            throw error
                        }
                        self.memberStatus[captured.member.physicalBoardID] = .ready
                    }
                }
                try await taskGroup.waitForAll()
            }
            }
            guard stillValid() else { throw GroupPlayError.aborted }

            // 8 clock samples per board, sequential per board, boards in parallel.
            try await withThrowingTaskGroup(of: (String, ClockOffsetEstimator).self) { taskGroup in
                for captured in online {
                    taskGroup.addTask { @MainActor in
                        var estimator = self.estimators[captured.member.physicalBoardID] ?? ClockOffsetEstimator()
                        estimator.removeAllSamples()
                        for _ in 0..<8 {
                            let sample = try await self.takeClockSample(connection: captured.session.connection)
                            if let sample, let bootId = captured.session.connection.bootId {
                                estimator.addSample(sample, bootId: bootId)
                            }
                        }
                        return (captured.member.physicalBoardID, estimator)
                    }
                }
                for try await (id, estimator) in taskGroup {
                    self.estimators[id] = estimator
                }
            }
            guard stillValid() else { throw GroupPlayError.aborted }

            let worstRtt = online.compactMap { estimators[$0.member.physicalBoardID]?.bestRttUs }.max() ?? 0
            let phoneStart = nowUs() + max(400_000, 3 * worstRtt)
            let capable60 = online.allSatisfy { $0.session.connection.supports(.group60Fps) }
            let intervalMs = groupIntervalMs(forFps: fps, capable: capable60)
            var bootIds: [String: String] = [:]
            var ests: [String: ClockOffsetEstimator] = [:]
            for captured in online {
                if let bootId = captured.session.connection.bootId {
                    bootIds[captured.member.physicalBoardID] = bootId
                }
                if let estimator = estimators[captured.member.physicalBoardID] {
                    ests[captured.member.physicalBoardID] = estimator
                }
            }
            var firstFrame = startFrame
            if let adoption, adoption.frameCount > 0 {
                // Where the still-running boards will be at `phoneStart`,
                // at the rate they were running when their meta was read.
                let elapsedFrames = Int((phoneStart - adoption.readAtPhoneUs) / Int64(max(intervalMs, 1) * 1000))
                let projected = adoption.frameIndex + max(0, elapsedFrames)
                firstFrame = loop ? projected % adoption.frameCount : min(projected, adoption.frameCount - 1)
            }
            let commands = GroupSchedule.startCommands(
                phoneStartUs: phoneStart, estimators: ests, bootIds: bootIds, intervalMs: intervalMs,
                startFrame: firstFrame, loop: loop
            )

            // H5: every online member must have a `group_start` command (a valid
            // clock estimate + bootId) before any board is sent one — never
            // start some boards and leave others silently unsynced.
            let missing = online.filter { commands[$0.member.physicalBoardID] == nil }
            guard missing.isEmpty else {
                let names = missing.map(\.member.displayName).joined(separator: "、")
                throw GroupPlayError.buildFailed("时钟同步失败：\(names)")
            }

            // H3: partial-start abort. If any board fails to receive
            // `group_start` (or the captured state went stale), best-effort stop
            // every board that did start, release their leases, and rethrow —
            // never leave a mix of started/unstarted boards claiming "playing".
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for captured in online {
                    guard let cmd = commands[captured.member.physicalBoardID] else { continue }
                    let token = tokens[captured.member.physicalBoardID]!
                    taskGroup.addTask { @MainActor in
                        do {
                            try await captured.session.connection.withOutput(token) {
                                let reply = try await captured.session.connection.requestReliable(cmd)
                                // Same H3 partial-start treatment as an outright
                                // send failure: a rejected `group_start` reply
                                // (e.g. firmware still enforcing `intervalMs >=
                                // 20`) must never be treated as this board
                                // having started.
                                guard reply.ok else { throw RinaTransportError.underlying("面板拒绝指令：group_start") }
                            }
                        } catch {
                            self.memberStatus[captured.member.physicalBoardID] = .error(error.localizedDescription)
                            throw error
                        }
                        self.memberStatus[captured.member.physicalBoardID] = .playing
                    }
                }
                try await taskGroup.waitForAll()
            }
            guard stillValid() else { throw GroupPlayError.aborted }

            activeGroupID = capturedGroupID
            activeRevision = capturedRevision
            activeEpoch = capturedEpoch
            isPlaying = true
            currentAnchor = (phoneUs: phoneStart, startFrame: firstFrame, intervalMs: intervalMs, loop: loop)
            playState = PlayState(
                bitmap: bitmap, layout: layout, mode: mode, virtualWidth: virtualWidth, fps: fps,
                timelineId: timelineId, sourceText: text, loop: loop, memberOrder: group.members
            )
            participants.removeAll()
            for captured in online {
                guard let bootId = captured.session.connection.bootId,
                      let token = tokens[captured.member.physicalBoardID] else { continue }
                participants[captured.member.physicalBoardID] = Participant(
                    member: captured.member, session: captured.session,
                    generation: captured.session.connection.connectionGeneration, bootId: bootId, token: token
                )
            }
            startReanchorLoop(groupID: capturedGroupID, revision: capturedRevision, epoch: capturedEpoch)
            isStarting = false
            startingGroupID = nil
        } catch {
            // A newer `play()` may already have bumped `playEpoch` (and so
            // captured its own `isStarting`/`startingGroupID`) while this
            // stale attempt was still failing — only this attempt's own
            // epoch may clear them, never a newer attempt's in-flight state.
            if playEpoch == capturedEpoch {
                isStarting = false
                startingGroupID = nil
            }
            await abortStartedBoards(online, tokens: tokens, epoch: capturedEpoch)
            // A member disconnecting (or any other generation change) mid-flight
            // surfaces here as `CancellationError` from the in-flight request
            // whose connection generation moved out from under it — not a
            // distinct failure the UI should show differently from any other
            // "the group changed underneath us" abort.
            if error is CancellationError {
                throw GroupPlayError.aborted
            }
            throw error
        }
    }

    /// Best-effort: `stop_scroll` + release the lease on every captured board
    /// still owned by this group attempt, so a partial start never leaves a
    /// board scrolling under a stale group anchor while the coordinator
    /// reports nothing is playing (H3, M3, B3). If a newer `play()` has since
    /// bumped `playEpoch`, this attempt must never touch a board the newer
    /// attempt claimed (`claimedBoardIDs` — token equality can't tell them
    /// apart on a reused board, see its declaration) — but a sibling board
    /// the newer attempt left alone still belongs to this stale attempt and
    /// must still be stopped/released (cross-group stop: a second group
    /// starting mid-abort must never strand the boards it didn't touch).
    private func abortStartedBoards(_ online: [CapturedMember], tokens: [String: UUID], epoch: Int) async {
        for captured in online {
            let id = captured.member.physicalBoardID
            // 4.3: rechecked on every iteration (not just once up front) — a
            // newer `play()` can start mid-loop while an earlier board's
            // best-effort `stop_scroll` is still in flight, and this attempt
            // must stop touching any board that newer attempt claimed the
            // instant that happens.
            if playEpoch != epoch, claimedBoardIDs.contains(id) { continue }
            guard let token = tokens[id], captured.session.connection.output.isCurrent(token) else {
                memberStatus.removeValue(forKey: id)
                continue
            }
            _ = try? await captured.session.connection.withOutput(token) {
                _ = try? await captured.session.connection.requestReliable(.stopScroll(restoreAuto: nil, clear: nil))
            }
            if playEpoch != epoch, claimedBoardIDs.contains(id) { continue }
            // Conditional on `token` still being current: a newer play that
            // reused this exact board (source unchanged, so its own claim
            // returned the same token) must never have its lease invalidated
            // out from under it by this stale abort.
            captured.session.connection.output.invalidate(ifCurrent: token)
            memberStatus.removeValue(forKey: id)
        }
        guard playEpoch == epoch else { return }
        participants.removeAll()
        currentAnchor = nil
        playState = nil
        isPlaying = false
        isPaused = false
        pausedFrame = 0
        activeGroupID = nil
        activeRevision = nil
        activeEpoch = nil
        claimedBoardIDs.removeAll()
    }

    /// Part B: stops every board in `boardIDs` that a previous group left
    /// running/claimed and that this new group's own `play()` didn't just
    /// claim for itself — called as a fire-and-forget `Task` from `play()`
    /// right after it claims its own `claimedBoardIDs`, so it runs
    /// concurrently with (never delays) the new group's upload. Same
    /// cross-group-stop shape as `stop()`/`abortStartedBoards`: only acts on
    /// a board still actually owned by a group (`output.source == .group`)
    /// — never one a single-board action already took over — and rechecks
    /// `claimedBoardIDs` (this coordinator's single running total, already
    /// overwritten to the new group's own set by the time this task starts)
    /// both before claiming and before invalidating, so a later `play()`
    /// that re-claims one of these same boards while this cleanup is still
    /// in flight is never stepped on.
    private func stopBoardsNotInNewGroup(_ boardIDs: Set<String>) async {
        for id in boardIDs {
            guard !claimedBoardIDs.contains(id) else { continue }
            guard let session = sessions.session(matchingGroupMember: id),
                  session.connection.output.source == .group else { continue }
            let token = session.connection.output.claim(.group)
            _ = try? await session.connection.withOutput(token) {
                _ = try? await session.connection.requestReliable(.stopScroll(restoreAuto: nil, clear: nil))
            }
            guard !claimedBoardIDs.contains(id) else { continue }
            session.connection.output.invalidate(ifCurrent: token)
            memberStatus.removeValue(forKey: id)
        }
    }

    private func viewportX(for slot: Int, mode: BoardGroup.Mode, layout: StitchedScreenLayout) -> Int {
        // Mirror mode: every board shows the same V=22 viewport at X=0.
        mode == .mirror ? 0 : layout.viewportX(slot: slot)
    }

    /// One `clock_sample` round trip (BOARD_GROUP_SPEC §1.3/§2).
    private func takeClockSample(connection: BoardConnection) async throws -> ClockSample? {
        let m1 = nowUs()
        let reply: ClockSampleReply = try await connection.requestReliableDecoding(.clockSample)
        let m4 = nowUs()
        guard reply.ok == true, let rx = reply.rxUs, let tx = reply.txUs else { return nil }
        return ClockSample(m1: m1, b2: rx, b3: tx, m4: m4)
    }

    // MARK: - Re-anchoring

    private func startReanchorLoop(groupID: UUID, revision: Int, epoch: Int) {
        reanchorTask?.cancel()
        reanchorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.isPlaying, self.activeGroupID == groupID, self.playEpoch == epoch else { return }
                guard self.isAppActive else { continue } // M1: skip this pass, keep the loop running
                await self.reanchor(groupID: groupID, revision: revision, epoch: epoch)
            }
        }
    }

    /// C1: only ever touches a board that is still a live `Participant`
    /// (same connection generation, output source still `.group`, and its
    /// stored lease token is still current) — never claims a lease itself.
    /// C2: a member whose generation/bootId changed (or was never a
    /// participant while the layout stayed the same) gets a per-board
    /// rejoin instead, unless something else now owns its output. N1: a
    /// member dropped because its output ownership itself moved away from
    /// `.group` is never auto-rejoined — that would steal it back from
    /// whatever single-board action now owns it.
    private func reanchor(groupID: UUID, revision: Int, epoch: Int) async {
        guard playEpoch == epoch else { return } // N3
        let gen = controlGeneration // B1: captured before any await below
        guard let group = store.groups.first(where: { $0.id == groupID }), group.layoutRevision == revision,
              let anchor = currentAnchor, playState != nil, !isPaused else { return } // B1

        var survivors: [String: Participant] = [:]
        for (id, participant) in participants {
            let connection = participant.session.connection
            // A reconnect (new connection generation) naturally invalidates
            // the output lease too, same as a deliberate takeover — so
            // "still the exact same connection generation" is what actually
            // distinguishes the two (N1), not the output source alone.
            let sameConnection = connection.connectionState == .connected
                && connection.connectionGeneration == participant.generation
            guard sameConnection, connection.output.source == .group,
                  connection.output.isCurrent(participant.token) else {
                memberStatus.removeValue(forKey: id) // M3: falls back to live status
                // N1: only a same-generation member whose output moved to a
                // different source was actually taken over — never rejoin
                // it. A member dropped by a generation/bootId change (or a
                // disconnect) stays eligible.
                if sameConnection, connection.output.source != .group {
                    evictedByOwnership.insert(id)
                }
                continue
            }
            survivors[id] = participant
        }
        participants = survivors

        var bootIds: [String: String] = [:]
        for (id, participant) in participants {
            bootIds[id] = participant.bootId
            var estimator = estimators[id] ?? ClockOffsetEstimator()
            // Start this re-anchor's window fresh: a stale low-RTT sample
            // from a much earlier burst must not keep winning "minimum RTT
            // of the last N" over this pass's fresher samples.
            estimator.removeAllSamples()
            for _ in 0..<4 {
                guard let sample = try? await takeClockSample(connection: participant.session.connection) else { continue }
                estimator.addSample(sample, bootId: participant.bootId)
            }
            estimators[id] = estimator
        }
        // N3/B1: re-check after the sampling awaits — a pause() that landed
        // mid-sampling must stop this pass before it ever reaches a
        // `group_start` send.
        guard playEpoch == epoch, controlGeneration == gen, !isPaused else { return }
        let commands = GroupSchedule.reanchorCommands(
            phoneAnchorUs: anchor.phoneUs, startFrame: anchor.startFrame, intervalMs: anchor.intervalMs,
            loop: anchor.loop, estimators: estimators.filter { participants[$0.key] != nil }, bootIds: bootIds
        )
        for (id, participant) in participants {
            guard let cmd = commands[id] else { continue }
            // B1: recheck immediately before every group_start send.
            guard playEpoch == epoch, controlGeneration == gen, !isPaused else { return }
            do {
                try await participant.session.connection.withOutput(participant.token) {
                    _ = try await participant.session.connection.requestReliable(cmd)
                }
                guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1: before writing memberStatus
                memberStatus[id] = .playing
            } catch {
                guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1: before writing memberStatus
                // Member-scoped re-anchor failure: recorded rather than
                // silently swallowed, so the play panel can surface which
                // board drifted out of sync (BOARD_GROUP_SPEC §3).
                memberStatus[id] = .error(error.localizedDescription)
            }
        }

        for member in group.members
        where participants[member.physicalBoardID] == nil && !evictedByOwnership.contains(member.physicalBoardID) {
            guard playEpoch == epoch, controlGeneration == gen, !isPaused else { return } // B1
            await rejoin(member: member, groupID: groupID, revision: revision, epoch: epoch)
        }
    }

    /// C2's per-board rejoin: re-upload the same group bitmap (from the
    /// stored `playState`) and send `group_start` mapped to the same phone
    /// anchor, only if this board isn't already owned by something else
    /// (never steal — H4/C2).
    private func rejoin(member: BoardGroup.Member, groupID: UUID, revision: Int, epoch: Int) async {
        guard playEpoch == epoch, !isPaused else { return } // N3/B1
        let gen = controlGeneration // B1: captured before any await below
        let id = member.physicalBoardID
        guard let session = session(for: member), session.connection.connectionState == .connected else { return }
        guard hasAllCaps(session.connection) else { return }
        let source = session.connection.output.source
        guard source == nil || source == .group else { return } // never steal from another feature
        guard let playState, let anchor = currentAnchor,
              let slot = playState.memberOrder.firstIndex(where: { $0.physicalBoardID == id }) else { return }

        // A legacy board (no `group_60fps`) rejoining a group already
        // running at a 60fps-only anchor (< 20ms) can't be sent that
        // `group_start` at all — firmware would reject it. Simpler-and-
        // correct choice over re-anchoring every other, already-synced
        // participant down to 20ms just to fit one latecomer: leave this
        // board out until it either reconnects with capable firmware or the
        // whole group is restarted at a rate everyone can join.
        if anchor.intervalMs < RinaLinkConstants.groupStartIntervalMsMinLegacy, !session.connection.supports(.group60Fps) {
            memberStatus[id] = .error("固件不支持 60 fps")
            return
        }

        memberStatus[id] = .error("需要重新上传")
        let viewportX = viewportX(for: slot, mode: playState.mode, layout: playState.layout)
        let token = session.connection.output.claim(.group)
        do {
            try await session.connection.withOutput(token) {
                _ = try await session.connection.uploadGroupScrollBitmap(
                    bitmap: playState.bitmap, viewportX: viewportX, virtualWidth: playState.virtualWidth,
                    fps: playState.fps, timelineId: playState.timelineId, sourceText: playState.sourceText,
                    start: false
                )
            }
            // Same live-state guards `play()` uses: bail without touching
            // anything durable if the group moved on underneath us. B1:
            // also bails if a pause landed mid-upload.
            guard playEpoch == epoch, controlGeneration == gen, !isPaused, // N3/B1
                  store.groups.first(where: { $0.id == groupID })?.layoutRevision == revision,
                  isPlaying, activeGroupID == groupID, currentAnchor?.phoneUs == anchor.phoneUs else { return }

            var estimator = estimators[id] ?? ClockOffsetEstimator()
            estimator.removeAllSamples()
            for _ in 0..<8 {
                guard let sample = try? await takeClockSample(connection: session.connection) else { continue }
                if let bootId = session.connection.bootId { estimator.addSample(sample, bootId: bootId) }
            }
            estimators[id] = estimator
            guard playEpoch == epoch, controlGeneration == gen, !isPaused else { return } // N3/B1: after the sampling awaits
            guard let bootId = session.connection.bootId,
                  let cmd = GroupSchedule.reanchorCommands(
                    phoneAnchorUs: anchor.phoneUs, startFrame: anchor.startFrame, intervalMs: anchor.intervalMs,
                    loop: anchor.loop, estimators: [id: estimator], bootIds: [id: bootId]
                  )[id]
            else {
                guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1
                memberStatus[id] = .error("时钟同步失败：\(member.displayName)")
                return
            }
            // B1: recheck immediately before sending group_start.
            guard playEpoch == epoch, controlGeneration == gen, !isPaused else { return }
            try await session.connection.withOutput(token) {
                _ = try await session.connection.requestReliable(cmd)
            }
            guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1
            memberStatus[id] = .playing
            participants[id] = Participant(
                member: member, session: session, generation: session.connection.connectionGeneration,
                bootId: bootId, token: token
            )
        } catch {
            guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1
            memberStatus[id] = .error(error.localizedDescription)
        }
    }

    // MARK: - Live playback updates

    /// 4.7: `updatePlayback` is serialized latest-wins — a call made while
    /// one is already running is remembered (overwriting any earlier pending
    /// one) and replayed once the in-flight pass finishes, rather than ever
    /// running two passes concurrently against the same participant set.
    private var updatePlaybackBusy = false
    private var pendingUpdatePlayback: (group: BoardGroup, fps: Int?, loop: Bool?)?

    /// BOARD_GROUP_SPEC.md §3 addendum (live fps/loop update): re-anchors
    /// every live participant to a new `(intervalMs, loop)` without a phase
    /// jump. Picks one common phone instant `T = now + max(300 ms, 3 ×
    /// worst bestRtt)`, computes the global frame index at `T` under the
    /// *current* anchor (wrapped/clamped per the old `loop`), then
    /// re-anchors every participant with fresh clock samples to resume from
    /// that frame at the new rate — same live-participant/epoch/revision
    /// guards as `reanchor`. Does nothing unless this exact group is
    /// currently playing. `fps`/`loop` left `nil` keep that part of the
    /// anchor unchanged; if both are `nil` this is a no-op.
    public func updatePlayback(group: BoardGroup, fps: Int?, loop: Bool?) async {
        guard fps != nil || loop != nil else { return }
        guard !updatePlaybackBusy else {
            pendingUpdatePlayback = (group, fps, loop)
            return
        }
        updatePlaybackBusy = true
        await updatePlaybackCore(group: group, fps: fps, loop: loop)
        while let next = pendingUpdatePlayback {
            pendingUpdatePlayback = nil
            await updatePlaybackCore(group: next.group, fps: next.fps, loop: next.loop)
        }
        updatePlaybackBusy = false
    }

    private func updatePlaybackCore(group: BoardGroup, fps: Int?, loop: Bool?) async {
        guard isPlaying || isPaused, activeGroupID == group.id,
              let epoch = activeEpoch, playEpoch == epoch,
              let revision = activeRevision,
              let anchor = currentAnchor, let playState else { return }
        guard let liveGroup = store.groups.first(where: { $0.id == group.id }),
              liveGroup.layoutRevision == revision else { return }

        // C1: same live-participant pruning `reanchor` uses — never touches
        // a board that isn't still exactly the one this group started with.
        // Run up front (even on the paused path below, which sends nothing
        // yet) so the 60fps-capability check just below reflects the boards
        // this update actually targets, not a stale/offline membership list.
        pruneParticipants()
        guard !participants.isEmpty else { return }
        let capable = participants.values.allSatisfy { $0.session.connection.supports(.group60Fps) }
        let newIntervalMs = fps.map { groupIntervalMs(forFps: $0, capable: capable) } ?? anchor.intervalMs
        let newLoop = loop ?? anchor.loop

        // Paused: no live re-anchor to send — just remember the new
        // interval/loop on the anchor, applied by `resume()` next (B2).
        if isPaused {
            currentAnchor = (phoneUs: anchor.phoneUs, startFrame: anchor.startFrame, intervalMs: newIntervalMs, loop: newLoop)
            return
        }

        let gen = controlGeneration // B1: captured before any await below

        // 4.7: sample every live participant's clock in parallel (boards
        // never wait on each other's round trips), and only *after* every
        // sample is back pick the switch time `T` and the frame to resume
        // from — picking `T` up front (the old order) meant sampling could
        // eat well past `T`'s own margin, so boards ended up jumping instead
        // of landing smoothly on the intended frame.
        var bootIds: [String: String] = [:]
        for (id, participant) in participants { bootIds[id] = participant.bootId }
        var freshEstimators: [String: ClockOffsetEstimator] = [:]
        await withTaskGroup(of: (String, ClockOffsetEstimator).self) { taskGroup in
            for (id, participant) in participants {
                taskGroup.addTask { @MainActor in
                    var estimator = self.estimators[id] ?? ClockOffsetEstimator()
                    estimator.removeAllSamples()
                    for _ in 0..<4 {
                        guard let sample = try? await self.takeClockSample(connection: participant.session.connection) else { continue }
                        estimator.addSample(sample, bootId: participant.bootId)
                    }
                    return (id, estimator)
                }
            }
            for await (id, estimator) in taskGroup {
                freshEstimators[id] = estimator
            }
        }
        for (id, estimator) in freshEstimators { estimators[id] = estimator }

        // N3/B1: re-check after the sampling awaits — a pause() that landed
        // mid-sampling must stop this pass before it ever picks a switch
        // time or sends a `group_start`.
        guard playEpoch == epoch, controlGeneration == gen, isPlaying, !isPaused, activeGroupID == group.id,
              store.groups.first(where: { $0.id == group.id })?.layoutRevision == revision else { return }

        let worstRtt = participants.keys.compactMap { estimators[$0]?.bestRttUs }.max() ?? 0
        let phoneNow = nowUs() + max(300_000, 3 * worstRtt)

        let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: playState.bitmap.width, virtualWidth: playState.virtualWidth)
        let oldIntervalUs = Int64(anchor.intervalMs) * 1000
        let elapsedUs = phoneNow - anchor.phoneUs
        let rawFrame = elapsedUs < 0
            ? Int64(anchor.startFrame)
            : Int64(anchor.startFrame) + elapsedUs / max(oldIntervalUs, 1)
        let newStartFrame: Int
        if frameCount <= 0 {
            newStartFrame = 0
        } else if anchor.loop {
            let m = Int64(frameCount)
            newStartFrame = Int(((rawFrame % m) + m) % m)
        } else {
            newStartFrame = Int(min(max(rawFrame, 0), Int64(frameCount - 1)))
        }

        let commands = GroupSchedule.reanchorCommands(
            phoneAnchorUs: phoneNow, startFrame: newStartFrame, intervalMs: newIntervalMs,
            loop: newLoop, estimators: estimators.filter { participants[$0.key] != nil }, bootIds: bootIds
        )

        // Send `group_start` to every participant in parallel.
        var anyAccepted = false
        await withTaskGroup(of: Bool.self) { taskGroup in
            for (id, participant) in participants {
                guard let cmd = commands[id] else { continue }
                taskGroup.addTask { @MainActor in
                    // B1: recheck immediately before this board's send.
                    guard self.playEpoch == epoch, self.controlGeneration == gen, !self.isPaused else { return false }
                    do {
                        try await participant.session.connection.withOutput(participant.token) {
                            let reply = try await participant.session.connection.requestReliable(cmd)
                            // 4.1 hardening: firmware `group_start` rejects
                            // `intervalMs < 20` -- normally prevented by
                            // `groupIntervalMs`, but a rejected reply must
                            // still be treated as this board not having
                            // accepted the new anchor, not as success.
                            guard reply.ok else { throw RinaTransportError.underlying("面板拒绝指令：group_start") }
                        }
                        guard self.playEpoch == epoch, self.controlGeneration == gen else { return false } // N3/B1
                        self.memberStatus[id] = .playing
                        return true
                    } catch {
                        guard self.playEpoch == epoch, self.controlGeneration == gen else { return false } // N3/B1
                        self.memberStatus[id] = .error(error.localizedDescription)
                        return false
                    }
                }
            }
            for await accepted in taskGroup where accepted { anyAccepted = true }
        }

        // 4.1 hardening: only commit the new anchor if at least one
        // participant actually accepted the `group_start` -- otherwise every
        // board is still running under the old anchor, and moving
        // `currentAnchor` forward would desync the next re-anchor/rejoin
        // pass from what the boards are actually showing.
        guard anyAccepted, playEpoch == epoch, controlGeneration == gen, !isPaused else { return } // N3/B1
        currentAnchor = (phoneUs: phoneNow, startFrame: newStartFrame, intervalMs: newIntervalMs, loop: newLoop)
    }

    // MARK: - Pause / resume / step (app-level; no firmware timed-pause)

    /// C1: same live-participant pruning `reanchor`/`updatePlayback` use —
    /// never touches a board that isn't still exactly the one this group
    /// started with. Shared by `pause`/`resume`/`step`.
    private func pruneParticipants() {
        var survivors: [String: Participant] = [:]
        for (id, participant) in participants {
            let connection = participant.session.connection
            let sameConnection = connection.connectionState == .connected
                && connection.connectionGeneration == participant.generation
            guard sameConnection, connection.output.source == .group,
                  connection.output.isCurrent(participant.token) else {
                memberStatus.removeValue(forKey: id) // M3: falls back to live status
                if sameConnection, connection.output.source != .group {
                    evictedByOwnership.insert(id) // N1: never auto-rejoined
                }
                continue
            }
            survivors[id] = participant
        }
        participants = survivors
    }

    // MARK: - Preview snapshot

    /// What the group preview draws while a group is playing or paused: the
    /// exact bitmap and per-slot viewports the boards were given, so the
    /// preview shows what the hardware shows rather than a re-render.
    public struct PlaybackSnapshot {
        public let groupID: UUID
        public let bitmap: ScrollBitmap
        /// Member order at `play()` time, left to right.
        public let memberOrder: [BoardGroup.Member]
        /// `viewportX` per slot of `memberOrder`.
        public let viewportXs: [Int]
        public let frameCount: Int
        public let sourceText: String
        /// Current frame interval, so the preview redraws at the playback
        /// rate rather than every display refresh.
        public let intervalMs: Int
    }

    /// `nil` unless a group is playing or paused.
    public var playbackSnapshot: PlaybackSnapshot? {
        guard let groupID = activeGroupID, isPlaying || isPaused, let playState else { return nil }
        return PlaybackSnapshot(
            groupID: groupID,
            bitmap: playState.bitmap,
            memberOrder: playState.memberOrder,
            viewportXs: playState.memberOrder.indices.map {
                viewportX(for: $0, mode: playState.mode, layout: playState.layout)
            },
            frameCount: GroupScrollBitmap.frameCount(bitmapWidth: playState.bitmap.width, virtualWidth: playState.virtualWidth),
            sourceText: playState.sourceText,
            intervalMs: currentAnchor?.intervalMs ?? ScrollRasterizer.intervalMs(forFps: playState.fps)
        )
    }

    /// The global frame the boards are showing now: `pausedFrame` while
    /// paused, else computed from the live anchor. `nil` when idle.
    public func currentFrame() -> Int? {
        guard let playState, isPlaying || isPaused else { return nil }
        if isPaused { return pausedFrame }
        guard let anchor = currentAnchor else { return nil }
        let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: playState.bitmap.width, virtualWidth: playState.virtualWidth)
        return frame(atPhoneUs: nowUs(), anchor: anchor, frameCount: frameCount)
    }

    /// Drag-to-swap from the group preview, by board identity (the preview
    /// may be drawing the play-time order while the store already differs).
    /// Idle group: just reorders. Playing or paused: every member must be
    /// online and group-capable first, then the order is swapped and the text
    /// restarted with the new layout; if that restart fails the group is put
    /// back exactly as it was (revision included) so the running playback
    /// keeps its controls, and the error is rethrown. Refused while starting.
    public func swapMembers(group: BoardGroup, _ boardA: String, _ boardB: String) async throws {
        guard boardA != boardB,
              let before = store.groups.first(where: { $0.id == group.id }),
              let a = before.members.firstIndex(where: { $0.physicalBoardID == boardA }),
              let b = before.members.firstIndex(where: { $0.physicalBoardID == boardB }) else { return }
        if isStarting { throw GroupPlayError.aborted }
        let active = activeGroupID == group.id && (isPlaying || isPaused)
        guard active, let playState, let anchor = currentAnchor else {
            store.swapMembers(groupID: group.id, a, b)
            return
        }
        var offlineNames: [String] = []
        var unsupportedNames: [String] = []
        for member in before.members {
            guard let session = session(for: member), session.connection.connectionState == .connected else {
                offlineNames.append(member.displayName)
                continue
            }
            if !hasAllCaps(session.connection) { unsupportedNames.append(member.displayName) }
        }
        guard offlineNames.isEmpty else { throw GroupPlayError.offlineMembers(offlineNames) }
        guard unsupportedNames.isEmpty else { throw GroupPlayError.unsupportedMembers(unsupportedNames) }

        store.swapMembers(groupID: group.id, a, b)
        guard let live = store.groups.first(where: { $0.id == group.id }) else { return }
        let fps = max(1, Int((1000.0 / Double(max(anchor.intervalMs, 1))).rounded()))
        do {
            try await play(group: live, text: playState.sourceText, fps: fps, loop: anchor.loop)
        } catch {
            // Only undo if nothing else changed the group meanwhile.
            if store.groups.first(where: { $0.id == group.id })?.layoutRevision == live.layoutRevision {
                store.restore(before)
            }
            throw error
        }
    }

    /// The global frame index at `phoneUs` under `anchor`, wrapped (loop) or
    /// clamped (no loop) to `frameCount` — same math `updatePlayback` uses to
    /// find the frame to resume from at a new rate.
    private func frame(atPhoneUs phoneUs: Int64, anchor: (phoneUs: Int64, startFrame: Int, intervalMs: Int, loop: Bool), frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let intervalUs = Int64(anchor.intervalMs) * 1000
        let elapsedUs = phoneUs - anchor.phoneUs
        let rawFrame = elapsedUs < 0
            ? Int64(anchor.startFrame)
            : Int64(anchor.startFrame) + elapsedUs / max(intervalUs, 1)
        if anchor.loop {
            let m = Int64(frameCount)
            return Int(((rawFrame % m) + m) % m)
        }
        return Int(min(max(rawFrame, 0), Int64(frameCount - 1)))
    }

    /// N4: median of `values`, or `nil` if empty — used for the pause-frame
    /// margin so one outlier board's RTT doesn't set the schedule for
    /// everyone.
    private func median(_ values: [Int64]) -> Int64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Pauses a playing group in place (BOARD_GROUP_SPEC.md §1.5: `pause_scroll`
    /// / `scroll_seek` exit group-timed mode): picks one common phone instant
    /// `T`, computes the global frame `n` every member is showing at `T` under
    /// the current anchor, stops re-anchoring, then sends every live
    /// participant `pause_scroll` followed by `scroll_seek{frameIndex:n}` in
    /// parallel — so every board ends up paused on the identical frame. A
    /// member whose request fails is recorded `.error`; the others still end
    /// paused. Same live-participant/epoch/revision guards as `reanchor` (C1/N3).
    public func pause(group: BoardGroup) async {
        guard !isControlBusy else { return } // N5: ignore an overlapping pause tap
        isControlBusy = true
        await pauseCore(group: group)
        isControlBusy = false
        drainPendingStep(group: group)
    }

    /// The actual pause body, with no busy-flag guard of its own — used by
    /// `pause()` (guarded/serialized, N5) and directly by `performStep(...)`
    /// (already running inside `step()`'s own busy section, so re-taking the
    /// guard there would deadlock/no-op).
    private func pauseCore(group: BoardGroup) async {
        guard isPlaying, activeGroupID == group.id,
              let epoch = activeEpoch, playEpoch == epoch,
              let revision = activeRevision,
              let anchor = currentAnchor, let playState else { return }
        guard let liveGroup = store.groups.first(where: { $0.id == group.id }),
              liveGroup.layoutRevision == revision else { return }

        pruneParticipants()
        guard !participants.isEmpty else { return }

        reanchorTask?.cancel()
        reanchorTask = nil

        // N4: the pause frame is computed at "now" plus half the median
        // best RTT across participants — not a fixed margin — so boards
        // land on the frame they were actually showing instead of jumping
        // forward by a margin much larger than the real one-way delay.
        let halfRtts = participants.keys.compactMap { estimators[$0]?.bestRttUs.map { $0 / 2 } }
        let margin = median(halfRtts) ?? 0
        let phoneNow = nowUs() + margin
        let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: playState.bitmap.width, virtualWidth: playState.virtualWidth)
        let n = frame(atPhoneUs: phoneNow, anchor: anchor, frameCount: frameCount)

        // B1: flip state and bump `controlGeneration` synchronously, before
        // any await — including the send fan-out below. An in-flight
        // reanchor()/rejoin()/updatePlayback() pass captured this
        // generation at its own start and rechecks it (plus `!isPaused`)
        // after every await, so it aborts as soon as it next checks instead
        // of racing a `group_start` out after this pause.
        controlGeneration += 1
        let gen = controlGeneration
        isPlaying = false
        isPaused = true
        pausedFrame = n

        let snapshot = participants
        await withTaskGroup(of: Void.self) { taskGroup in
            for (id, participant) in snapshot {
                taskGroup.addTask { @MainActor in
                    guard self.playEpoch == epoch, self.controlGeneration == gen else { return } // N3/B1
                    do {
                        try await participant.session.connection.withOutput(participant.token) {
                            _ = try await participant.session.connection.requestReliable(.pauseScroll)
                            _ = try await participant.session.connection.requestReliable(.scrollSeek(frameIndex: n))
                        }
                        guard self.playEpoch == epoch, self.controlGeneration == gen else { return } // N3/B1
                        self.memberStatus[id] = .ready
                    } catch {
                        guard self.playEpoch == epoch, self.controlGeneration == gen else { return } // N3/B1
                        self.memberStatus[id] = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// N5: after `pause()`/`resume()`/`step()` releases the busy flag, kicks
    /// off any `step()` direction that got coalesced into
    /// `pendingStepDirection` while this call was in flight (e.g. a step tap
    /// that landed mid-pause) — fire-and-forget, since the caller has
    /// already returned.
    private func drainPendingStep(group: BoardGroup) {
        guard pendingStepDirection != 0 else { return }
        let direction = pendingStepDirection
        pendingStepDirection = 0
        Task { [weak self] in await self?.step(group: group, direction: direction) }
    }

    /// Resumes a paused group from `pausedFrame`: fresh clock samples (like
    /// `reanchor`), a fresh common phone start instant, then one `group_start`
    /// per live participant anchored at `pausedFrame` — restarting the
    /// re-anchor loop once every reachable board is back in group-timed
    /// playback. `intervalMs`/`loop` are whatever `updatePlayback` last stored
    /// while paused (or the play-time values if it was never called).
    public func resume(group: BoardGroup) async {
        guard !isControlBusy else { return } // N5: ignore an overlapping resume tap
        isControlBusy = true
        await resumeCore(group: group)
        isControlBusy = false
        drainPendingStep(group: group)
    }

    private func resumeCore(group: BoardGroup) async {
        guard isPaused, activeGroupID == group.id,
              let epoch = activeEpoch, playEpoch == epoch,
              let revision = activeRevision,
              let anchor = currentAnchor, let playState else { return }
        guard let liveGroup = store.groups.first(where: { $0.id == group.id }),
              liveGroup.layoutRevision == revision else { return }

        pruneParticipants()
        guard !participants.isEmpty else { return }

        let gen = controlGeneration // B1: captured before any await below

        var bootIds: [String: String] = [:]
        for (id, participant) in participants {
            bootIds[id] = participant.bootId
            var estimator = estimators[id] ?? ClockOffsetEstimator()
            estimator.removeAllSamples()
            for _ in 0..<4 {
                guard let sample = try? await takeClockSample(connection: participant.session.connection) else { continue }
                estimator.addSample(sample, bootId: participant.bootId)
            }
            estimators[id] = estimator
        }
        guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1: re-check after sampling awaits

        let worstRtt = participants.keys.compactMap { estimators[$0]?.bestRttUs }.max() ?? 0
        let phoneStart = nowUs() + max(400_000, 3 * worstRtt)
        let intervalMs = anchor.intervalMs
        let loop = anchor.loop
        let commands = GroupSchedule.reanchorCommands(
            phoneAnchorUs: phoneStart, startFrame: pausedFrame, intervalMs: intervalMs,
            loop: loop, estimators: estimators.filter { participants[$0.key] != nil }, bootIds: bootIds
        )

        var anyAccepted = false
        for (id, participant) in participants {
            guard let cmd = commands[id] else { continue }
            // B1: recheck immediately before every group_start send.
            guard playEpoch == epoch, controlGeneration == gen else { return }
            do {
                try await participant.session.connection.withOutput(participant.token) {
                    let reply = try await participant.session.connection.requestReliable(cmd)
                    // 4.1 hardening: a rejected `group_start` (e.g. firmware
                    // still enforcing `intervalMs >= 20`) must never be
                    // treated as this board having resumed.
                    guard reply.ok else { throw RinaTransportError.underlying("面板拒绝指令：group_start") }
                }
                guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1
                memberStatus[id] = .playing
                anyAccepted = true
            } catch {
                guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1
                memberStatus[id] = .error(error.localizedDescription)
            }
        }

        // 4.1 hardening: only flip to playing if at least one participant
        // actually accepted the `group_start` -- otherwise every board is
        // still sitting paused on `pausedFrame`, and the coordinator must
        // keep reporting that instead of claiming a resume that never
        // reached the wire. Per-board failures are already recorded above
        // the same way any other send failure is (`memberStatus[id] =
        // .error(...)`).
        guard anyAccepted else { return }
        guard playEpoch == epoch, controlGeneration == gen else { return } // N3/B1
        currentAnchor = (phoneUs: phoneStart, startFrame: pausedFrame, intervalMs: intervalMs, loop: loop)
        isPaused = false
        isPlaying = true
        startReanchorLoop(groupID: group.id, revision: revision, epoch: epoch)
    }

    /// Steps one frame while paused (or pauses first if the group was
    /// playing): `pausedFrame` moves by `direction`, wrapped if the current
    /// loop setting is on, else clamped, then every live participant is sent
    /// `scroll_seek{frameIndex:pausedFrame}` — never `scroll_step`, so every
    /// board lands on the exact same frame the app just computed rather than
    /// each stepping its own board-side state independently.
    ///
    /// N5: overlapping step taps while one is already in flight are
    /// coalesced — their directions are summed into `pendingStepDirection`
    /// and applied as one further step once the in-flight one finishes,
    /// rather than firing a separate `scroll_seek` per tap.
    public func step(group: BoardGroup, direction: Int) async {
        guard !isControlBusy else {
            pendingStepDirection += direction
            return
        }
        isControlBusy = true
        var pendingDirection = direction
        while pendingDirection != 0 {
            let thisDirection = pendingDirection
            pendingDirection = 0
            await performStep(group: group, direction: thisDirection)
            pendingDirection += pendingStepDirection
            pendingStepDirection = 0
        }
        isControlBusy = false
    }

    /// The body of one (possibly coalesced) `step()` call — see
    /// `step(group:direction:)` for the busy-flag/coalescing wrapper (N5).
    /// Calls `pauseCore` directly rather than the public `pause()`: this
    /// runs inside `step()`'s own busy section already, so taking the busy
    /// guard again here would just no-op.
    private func performStep(group: BoardGroup, direction: Int) async {
        if isPlaying, activeGroupID == group.id {
            await pauseCore(group: group)
        }
        guard isPaused, activeGroupID == group.id,
              let epoch = activeEpoch, playEpoch == epoch,
              let revision = activeRevision,
              let anchor = currentAnchor, let playState else { return }
        guard let liveGroup = store.groups.first(where: { $0.id == group.id }),
              liveGroup.layoutRevision == revision else { return }

        pruneParticipants()
        guard !participants.isEmpty else { return }

        let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: playState.bitmap.width, virtualWidth: playState.virtualWidth)
        let newFrame: Int
        if frameCount <= 0 {
            newFrame = 0
        } else if anchor.loop {
            let m = frameCount
            newFrame = ((pausedFrame + direction) % m + m) % m
        } else {
            newFrame = min(max(pausedFrame + direction, 0), frameCount - 1)
        }

        // B1: bump before the only await below (the send fan-out) — the
        // frame is fixed here regardless of per-board send outcome, same as
        // the original behaviour.
        controlGeneration += 1
        let gen = controlGeneration
        pausedFrame = newFrame

        let snapshot = participants
        await withTaskGroup(of: Void.self) { taskGroup in
            for (id, participant) in snapshot {
                taskGroup.addTask { @MainActor in
                    guard self.playEpoch == epoch, self.controlGeneration == gen else { return } // N3/B1
                    do {
                        try await participant.session.connection.withOutput(participant.token) {
                            _ = try await participant.session.connection.requestReliable(.scrollSeek(frameIndex: newFrame))
                        }
                        guard self.playEpoch == epoch, self.controlGeneration == gen else { return } // N3/B1
                        self.memberStatus[id] = .ready
                    } catch {
                        guard self.playEpoch == epoch, self.controlGeneration == gen else { return } // N3/B1
                        self.memberStatus[id] = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    #if DEBUG
    /// Test-only seam: runs one re-anchor pass synchronously instead of
    /// waiting for the 30s interval loop. Never called from production code.
    /// B4: uses the revision/epoch frozen at the last successful `play()`
    /// (`activeRevision`/`activeEpoch`) rather than the group's *current*
    /// live revision — reading the live revision here would always agree
    /// with itself and silently defeat `reanchor`'s own staleness guard.
    func debugReanchorNow() async {
        guard let groupID = activeGroupID, let revision = activeRevision, let epoch = activeEpoch else { return }
        await reanchor(groupID: groupID, revision: revision, epoch: epoch)
    }

    /// Test-only accessor: the epoch counter right now, so a test can
    /// snapshot it after one `play()` completes and later prove a re-anchor
    /// pass computed with that stale epoch is rejected once a second
    /// `play()` has bumped it (B4/N3).
    var debugPlayEpoch: Int { playEpoch }

    /// Test-only seam: like `debugReanchorNow()`, but takes an explicit
    /// `(groupID, revision, epoch)` instead of reading the coordinator's
    /// current `active*` state — lets a test simulate a re-anchor pass that
    /// was captured before a later `play()` superseded it.
    func debugReanchor(groupID: UUID, revision: Int, epoch: Int) async {
        await reanchor(groupID: groupID, revision: revision, epoch: epoch)
    }

    /// Test-only accessor: the current anchor's `intervalMs`, or `nil` if
    /// nothing is playing/paused -- lets a test prove a `group_start` every
    /// participant rejected left the anchor untouched (4.1 hardening).
    var debugAnchorIntervalMs: Int? { currentAnchor?.intervalMs }
    #endif

    /// Board-group control fan-out addendum: called by `GroupControlFanOut`
    /// right before it claims a `.groupControl` lease on a board this
    /// coordinator currently owns as a Text-tab participant (a face/button
    /// applied while the group is playing supersedes its scroll). Unlike
    /// `stop()`, sends nothing on the wire — the claim about to happen (and
    /// `output.invalidate()` on takeover, or the next `SET_FRAME`/command)
    /// is what actually stops the board; this only stops the coordinator
    /// from fighting that with a re-anchor or treating the board as still
    /// playing.
    public func markSupersededByControl() {
        playEpoch += 1
        controlGeneration += 1 // B1
        reanchorTask?.cancel()
        reanchorTask = nil
        isPlaying = false
        isPaused = false
        pausedFrame = 0
        activeGroupID = nil
        activeRevision = nil
        activeEpoch = nil
        currentAnchor = nil
        playState = nil
        // `claimedBoardIDs` covers a `play()` still mid `isStarting` (its
        // tokens are claimed before `participants` is ever populated) as
        // well as a fully joined play, so this clears memberStatus for
        // either case — not just the boards that had already become
        // `participants`.
        for id in claimedBoardIDs { memberStatus.removeValue(forKey: id) }
        for id in participants.keys { memberStatus.removeValue(forKey: id) }
        participants.removeAll()
        evictedByOwnership.removeAll()
        claimedBoardIDs.removeAll()
        // This bump just invalidated any in-flight `play()`'s own epoch, so
        // its `catch` block will no longer clear these itself (it only ever
        // clears them under its own matching epoch) — this call must take
        // over that responsibility instead of leaving the Text tab's upload
        // spinner stuck on.
        isStarting = false
        startingGroupID = nil
    }

    // MARK: - Stop

    /// H6/M3: only ever acts on a board this coordinator currently owns
    /// (`output.source == .group`) — a board a single-board action already
    /// took over is left alone. Ends ownership via `output.invalidate()`
    /// after `stop_scroll`, clears per-member status, and cancels re-anchor.
    public func stop(group: BoardGroup) async {
        playEpoch += 1
        controlGeneration += 1 // B1
        let epoch = playEpoch // 4.3: captured right after this stop's own bump
        reanchorTask?.cancel()
        reanchorTask = nil
        isPlaying = false
        isPaused = false
        pausedFrame = 0
        activeGroupID = nil
        activeRevision = nil
        activeEpoch = nil
        currentAnchor = nil
        playState = nil
        // N2: clear before the awaited loop below, with the members to stop
        // captured up front (`group.members`, the parameter) — a concurrent
        // reader must not see this coordinator still claiming an anchor or
        // participant set mid-stop.
        let toStop = group.members
        participants.removeAll()
        for member in toStop {
            let id = member.physicalBoardID
            // 4.3/cross-group: a `play()` started while this `stop()`'s own
            // loop is still awaiting an earlier board's `stop_scroll` reply
            // bumps `playEpoch` again — from that point this stale `stop()`
            // must never touch a board that newer play claimed
            // (`claimedBoardIDs`), but a sibling board the newer play didn't
            // touch still belongs to this group and must still be stopped
            // (e.g. G1={A,B,C} stopping while G2={A,D} starts mid-stop must
            // still deliver `stop_scroll` to B and C).
            if playEpoch != epoch, claimedBoardIDs.contains(id) { continue }
            // A board whose lease a reconnect cleared (`source == nil`) but
            // that is still scrolling is as much this group's as one we own:
            // skipping it would leave it scrolling with Stop gone. A board
            // owned by anything else is still left alone (H6).
            guard let session = session(for: member),
                  session.connection.output.source == .group
                      || (session.connection.output.source == nil && Self.isScrolling(session.connection))
            else { continue }
            let token = session.connection.output.claim(.group)
            _ = try? await session.connection.withOutput(token) {
                _ = try? await session.connection.requestReliable(.stopScroll(restoreAuto: nil, clear: nil))
            }
            if playEpoch != epoch, claimedBoardIDs.contains(id) { continue }
            // Conditional on `token` still being current: never invalidate a
            // newer play's lease out from under it just because this board
            // happened to reuse the same session (source never left `.group`).
            session.connection.output.invalidate(ifCurrent: token)
            memberStatus.removeValue(forKey: id)
        }
        // Only this stop's own (still-current) epoch may declare "nothing is
        // claimed anymore" — a newer play's `claimedBoardIDs` must survive a
        // stale stop() finishing after it.
        if playEpoch == epoch { claimedBoardIDs.removeAll() }
    }
}
