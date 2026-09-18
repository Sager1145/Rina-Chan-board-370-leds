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
    /// Bumped every `stop()`; a `play()` call captures it and refuses to act
    /// (and its re-anchor loop refuses to run) once it no longer matches.
    private var playEpoch = 0

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

    /// Resolves `member` to its connected session, if any, by matching
    /// `BoardConnection.boardIdentity` — never BLE UUID, host, or name.
    public func session(for member: BoardGroup.Member) -> BoardSession? {
        sessions.sessions.first { $0.connection.boardIdentity == member.physicalBoardID }
    }

    public func status(for member: BoardGroup.Member) -> MemberStatus {
        memberStatus[member.physicalBoardID] ?? computeIdleStatus(for: member)
    }

    private func computeIdleStatus(for member: BoardGroup.Member) -> MemberStatus {
        guard let session = session(for: member), session.connection.connectionState == .connected else {
            return .offline
        }
        guard hasAllCaps(session.connection) else { return .unsupported }
        return .connected
    }

    private func hasAllCaps(_ connection: BoardConnection) -> Bool {
        BoardCapability.allCases.allSatisfy(connection.supports)
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
        identifyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.identifyAll(group)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    public func stopIdentifyLoop(for group: BoardGroup) {
        identifyTask?.cancel()
        identifyTask = nil
        Task { [weak self] in
            guard let self else { return }
            for member in group.members {
                guard let session = self.session(for: member), session.connection.connectionState == .connected,
                      session.connection.supports(.identify) else { continue }
                _ = try? await session.connection.requestReliable(.identify(number: 1, ttlMs: 0))
            }
        }
    }

    // MARK: - Play

    /// Builds one group bitmap, uploads it to every member concurrently,
    /// clock-samples every member, and starts synchronized playback
    /// (BOARD_GROUP_SPEC §3). Captures `(group.id, group.layoutRevision,
    /// each member's session + connection generation)` up front; if any of
    /// those changes after an `await`, aborts and reports instead of writing
    /// to the group. Requires every member online and supported (L2): a
    /// group never plays with a silently-skipped gap.
    public func play(group: BoardGroup, text: String, fps: Int, loop: Bool) async throws {
        let capturedGroupID = group.id
        let capturedRevision = group.layoutRevision
        guard group.members.count >= BoardGroup.minMembersToPlay else { throw GroupPlayError.tooFewMembers }

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

        let capturedEpoch = playEpoch

        func stillValid() -> Bool {
            guard playEpoch == capturedEpoch else { return false }
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
        let bitmap: ScrollBitmap
        do {
            bitmap = try GroupScrollBitmap.build(text: text, font: font, virtualWidth: virtualWidth)
        } catch {
            throw GroupPlayError.buildFailed("\(error)")
        }
        guard stillValid() else { throw GroupPlayError.aborted }

        let timelineId = UUID().uuidString

        // Upload concurrently, each board's own output lease.
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for captured in online {
                let viewportX = self.viewportX(for: captured.slot, mode: mode, layout: layout)
                taskGroup.addTask { @MainActor in
                    let token = captured.session.connection.output.claim(.group)
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
        let intervalMs = ScrollRasterizer.intervalMs(forFps: fps)
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
        let commands = GroupSchedule.startCommands(
            phoneStartUs: phoneStart, estimators: ests, bootIds: bootIds, intervalMs: intervalMs, loop: loop
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
        do {
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for captured in online {
                    guard let cmd = commands[captured.member.physicalBoardID] else { continue }
                    taskGroup.addTask { @MainActor in
                        let token = captured.session.connection.output.claim(.group)
                        do {
                            try await captured.session.connection.withOutput(token) {
                                _ = try await captured.session.connection.requestReliable(cmd)
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
        } catch {
            await abortStartedBoards(online)
            throw error
        }

        activeGroupID = capturedGroupID
        isPlaying = true
        currentAnchor = (phoneUs: phoneStart, startFrame: 0, intervalMs: intervalMs, loop: loop)
        playState = PlayState(
            bitmap: bitmap, layout: layout, mode: mode, virtualWidth: virtualWidth, fps: fps,
            timelineId: timelineId, sourceText: text, loop: loop, memberOrder: group.members
        )
        participants.removeAll()
        for captured in online {
            guard let bootId = captured.session.connection.bootId else { continue }
            let token = captured.session.connection.output.claim(.group)
            participants[captured.member.physicalBoardID] = Participant(
                member: captured.member, session: captured.session,
                generation: captured.session.connection.connectionGeneration, bootId: bootId, token: token
            )
        }
        startReanchorLoop(groupID: capturedGroupID, revision: capturedRevision, epoch: capturedEpoch)
    }

    /// Best-effort: `stop_scroll` + release the lease on every board that
    /// reached "started"/"playing", so a partial start never leaves a board
    /// scrolling under a stale group anchor while the coordinator reports
    /// nothing is playing (H3, M3).
    private func abortStartedBoards(_ online: [CapturedMember]) async {
        for captured in online {
            guard captured.session.connection.output.source == .group else { continue }
            let token = captured.session.connection.output.claim(.group)
            _ = try? await captured.session.connection.withOutput(token) {
                _ = try? await captured.session.connection.requestReliable(.stopScroll(restoreAuto: nil, clear: nil))
            }
            captured.session.connection.output.invalidate()
            memberStatus.removeValue(forKey: captured.member.physicalBoardID)
        }
        participants.removeAll()
        currentAnchor = nil
        playState = nil
        isPlaying = false
        activeGroupID = nil
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
                await self.reanchor(groupID: groupID, revision: revision)
            }
        }
    }

    /// C1: only ever touches a board that is still a live `Participant`
    /// (same connection generation, output source still `.group`, and its
    /// stored lease token is still current) — never claims a lease itself.
    /// C2: a member whose generation/bootId changed (or was never a
    /// participant while the layout stayed the same) gets a per-board
    /// rejoin instead, unless something else now owns its output.
    private func reanchor(groupID: UUID, revision: Int) async {
        guard let group = store.groups.first(where: { $0.id == groupID }), group.layoutRevision == revision,
              let anchor = currentAnchor, playState != nil else { return }

        var survivors: [String: Participant] = [:]
        for (id, participant) in participants {
            guard participant.session.connection.connectionState == .connected,
                  participant.session.connection.connectionGeneration == participant.generation,
                  participant.session.connection.output.source == .group,
                  participant.session.connection.output.isCurrent(participant.token) else {
                memberStatus.removeValue(forKey: id) // M3: falls back to live status
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
        let commands = GroupSchedule.reanchorCommands(
            phoneAnchorUs: anchor.phoneUs, startFrame: anchor.startFrame, intervalMs: anchor.intervalMs,
            loop: anchor.loop, estimators: estimators.filter { participants[$0.key] != nil }, bootIds: bootIds
        )
        for (id, participant) in participants {
            guard let cmd = commands[id] else { continue }
            do {
                try await participant.session.connection.withOutput(participant.token) {
                    _ = try await participant.session.connection.requestReliable(cmd)
                }
                memberStatus[id] = .playing
            } catch {
                // Member-scoped re-anchor failure: recorded rather than
                // silently swallowed, so the play panel can surface which
                // board drifted out of sync (BOARD_GROUP_SPEC §3).
                memberStatus[id] = .error(error.localizedDescription)
            }
        }

        for member in group.members where participants[member.physicalBoardID] == nil {
            await rejoin(member: member, groupID: groupID, revision: revision)
        }
    }

    /// C2's per-board rejoin: re-upload the same group bitmap (from the
    /// stored `playState`) and send `group_start` mapped to the same phone
    /// anchor, only if this board isn't already owned by something else
    /// (never steal — H4/C2).
    private func rejoin(member: BoardGroup.Member, groupID: UUID, revision: Int) async {
        let id = member.physicalBoardID
        guard let session = session(for: member), session.connection.connectionState == .connected else { return }
        guard hasAllCaps(session.connection) else { return }
        let source = session.connection.output.source
        guard source == nil || source == .group else { return } // never steal from another feature
        guard let playState, let anchor = currentAnchor,
              let slot = playState.memberOrder.firstIndex(where: { $0.physicalBoardID == id }) else { return }

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
            // anything durable if the group moved on underneath us.
            guard store.groups.first(where: { $0.id == groupID })?.layoutRevision == revision,
                  isPlaying, activeGroupID == groupID, currentAnchor?.phoneUs == anchor.phoneUs else { return }

            var estimator = estimators[id] ?? ClockOffsetEstimator()
            estimator.removeAllSamples()
            for _ in 0..<8 {
                guard let sample = try? await takeClockSample(connection: session.connection) else { continue }
                if let bootId = session.connection.bootId { estimator.addSample(sample, bootId: bootId) }
            }
            estimators[id] = estimator
            guard let bootId = session.connection.bootId,
                  let cmd = GroupSchedule.reanchorCommands(
                    phoneAnchorUs: anchor.phoneUs, startFrame: anchor.startFrame, intervalMs: anchor.intervalMs,
                    loop: anchor.loop, estimators: [id: estimator], bootIds: [id: bootId]
                  )[id]
            else {
                memberStatus[id] = .error("时钟同步失败：\(member.displayName)")
                return
            }
            try await session.connection.withOutput(token) {
                _ = try await session.connection.requestReliable(cmd)
            }
            memberStatus[id] = .playing
            participants[id] = Participant(
                member: member, session: session, generation: session.connection.connectionGeneration,
                bootId: bootId, token: token
            )
        } catch {
            memberStatus[id] = .error(error.localizedDescription)
        }
    }

    // MARK: - Stop

    /// H6/M3: only ever acts on a board this coordinator currently owns
    /// (`output.source == .group`) — a board a single-board action already
    /// took over is left alone. Ends ownership via `output.invalidate()`
    /// after `stop_scroll`, clears per-member status, and cancels re-anchor.
    public func stop(group: BoardGroup) async {
        playEpoch += 1
        reanchorTask?.cancel()
        reanchorTask = nil
        isPlaying = false
        activeGroupID = nil
        currentAnchor = nil
        playState = nil
        for member in group.members {
            guard let session = session(for: member), session.connection.output.source == .group else { continue }
            let token = session.connection.output.claim(.group)
            _ = try? await session.connection.withOutput(token) {
                _ = try? await session.connection.requestReliable(.stopScroll(restoreAuto: nil, clear: nil))
            }
            session.connection.output.invalidate()
            memberStatus.removeValue(forKey: member.physicalBoardID)
        }
        participants.removeAll()
    }
}
