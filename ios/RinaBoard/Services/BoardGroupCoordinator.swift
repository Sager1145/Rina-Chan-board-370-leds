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
        case unsupportedMembers([String])
        case aborted
        case buildFailed(String)

        public var errorDescription: String? {
            switch self {
            case .tooFewMembers: return "多板组至少需要 2 块已连接的面板"
            case .unsupportedMembers(let names):
                return "以下面板固件过旧，不支持多板组：\(names.joined(separator: "、"))"
            case .aborted: return "多板组已变化，播放已取消"
            case .buildFailed(let message): return message
            }
        }
    }

    private let store: BoardGroupStore
    private let sessions: BoardSessionStore
    /// Injectable monotonic microsecond clock, so tests can script it.
    private let nowUs: @Sendable () -> Int64
    private let loadFont: () async throws -> ArkPixelFont

    public private(set) var memberStatus: [String: MemberStatus] = [:]
    public private(set) var activeGroupID: UUID?
    public private(set) var isPlaying = false
    /// Whether re-anchoring should keep running; set `false` when the app
    /// goes to background (BOARD_GROUP_SPEC §3 "while the app is active").
    public var isAppActive = true

    private var estimators: [String: ClockOffsetEstimator] = [:]
    private var identifyTask: Task<Void, Never>?
    private var reanchorTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var currentAnchor: (phoneUs: Int64, startFrame: Int, intervalMs: Int, loop: Bool)?

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
    /// to the group.
    public func play(group: BoardGroup, text: String, fps: Int, loop: Bool) async throws {
        let capturedGroupID = group.id
        let capturedRevision = group.layoutRevision
        guard group.members.count >= BoardGroup.minMembersToPlay else { throw GroupPlayError.tooFewMembers }

        struct Captured {
            let member: BoardGroup.Member
            let slot: Int
            let session: BoardSession
            let generation: UUID
        }
        var online: [Captured] = []
        var unsupportedNames: [String] = []
        for (slot, member) in group.members.enumerated() {
            guard let session = session(for: member), session.connection.connectionState == .connected else {
                continue // offline: keeps its slot, never blocks play
            }
            guard hasAllCaps(session.connection) else {
                unsupportedNames.append(member.displayName)
                continue
            }
            online.append(Captured(member: member, slot: slot, session: session, generation: session.connection.connectionGeneration))
        }
        guard unsupportedNames.isEmpty else { throw GroupPlayError.unsupportedMembers(unsupportedNames) }
        guard !online.isEmpty else { throw GroupPlayError.tooFewMembers }

        func stillValid() -> Bool {
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            for captured in online {
                let viewportX = self.viewportX(for: captured.slot, mode: mode, layout: layout)
                group.addTask { @MainActor in
                    let token = captured.session.connection.output.claim(.group)
                    self.memberStatus[captured.member.physicalBoardID] = .uploading(progress: 0)
                    try await captured.session.connection.withOutput(token) {
                        _ = try await captured.session.connection.uploadGroupScrollBitmap(
                            bitmap: bitmap, viewportX: viewportX, virtualWidth: virtualWidth,
                            fps: fps, timelineId: timelineId, sourceText: text, start: false,
                            onProgress: { progress in
                                self.memberStatus[captured.member.physicalBoardID] = .uploading(progress: progress)
                            }
                        )
                    }
                    self.memberStatus[captured.member.physicalBoardID] = .ready
                }
            }
            try await group.waitForAll()
        }
        guard stillValid() else { throw GroupPlayError.aborted }

        // 8 clock samples per board, sequential per board, boards in parallel.
        try await withThrowingTaskGroup(of: (String, ClockOffsetEstimator).self) { group in
            for captured in online {
                group.addTask { @MainActor in
                    var estimator = self.estimators[captured.member.physicalBoardID] ?? ClockOffsetEstimator()
                    for _ in 0..<8 {
                        let sample = try await self.takeClockSample(connection: captured.session.connection)
                        if let sample, let bootId = captured.session.connection.bootId {
                            estimator.addSample(sample, bootId: bootId)
                        }
                    }
                    return (captured.member.physicalBoardID, estimator)
                }
            }
            for try await (id, estimator) in group {
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

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for captured in online {
                guard let cmd = commands[captured.member.physicalBoardID] else { continue }
                taskGroup.addTask { @MainActor in
                    let token = captured.session.connection.output.claim(.group)
                    try await captured.session.connection.withOutput(token) {
                        _ = try await captured.session.connection.requestReliable(cmd)
                    }
                    self.memberStatus[captured.member.physicalBoardID] = .playing
                }
            }
            try await taskGroup.waitForAll()
        }
        guard stillValid() else { throw GroupPlayError.aborted }

        activeGroupID = capturedGroupID
        isPlaying = true
        currentAnchor = (phoneUs: phoneStart, startFrame: 0, intervalMs: intervalMs, loop: loop)
        startReanchorLoop(groupID: capturedGroupID, revision: capturedRevision)
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

    private func startReanchorLoop(groupID: UUID, revision: Int) {
        reanchorTask?.cancel()
        reanchorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.isAppActive, self.isPlaying, self.activeGroupID == groupID else { return }
                await self.reanchor(groupID: groupID, revision: revision)
            }
        }
    }

    private func reanchor(groupID: UUID, revision: Int) async {
        guard let group = store.groups.first(where: { $0.id == groupID }), group.layoutRevision == revision,
              let anchor = currentAnchor else { return }
        var bootIds: [String: String] = [:]
        for member in group.members {
            guard let session = session(for: member) else { continue }
            if let bootId = session.connection.bootId { bootIds[member.physicalBoardID] = bootId }
            var estimator = estimators[member.physicalBoardID] ?? ClockOffsetEstimator()
            guard session.connection.connectionState == .connected else { continue }
            // Start this re-anchor's window fresh: a stale low-RTT sample
            // from a much earlier burst must not keep winning "minimum RTT
            // of the last N" over this pass's fresher samples.
            estimator.removeAllSamples()
            for _ in 0..<4 {
                guard let sample = try? await takeClockSample(connection: session.connection),
                      let bootId = session.connection.bootId else { continue }
                estimator.addSample(sample, bootId: bootId)
            }
            estimators[member.physicalBoardID] = estimator
        }
        let commands = GroupSchedule.reanchorCommands(
            phoneAnchorUs: anchor.phoneUs, startFrame: anchor.startFrame, intervalMs: anchor.intervalMs,
            loop: anchor.loop, estimators: estimators, bootIds: bootIds
        )
        for member in group.members {
            guard let cmd = commands[member.physicalBoardID], let session = session(for: member) else { continue }
            let token = session.connection.output.claim(.group)
            _ = try? await session.connection.withOutput(token) {
                _ = try await session.connection.requestReliable(cmd)
            }
        }
    }

    // MARK: - Stop

    public func stop(group: BoardGroup) async {
        reanchorTask?.cancel()
        reanchorTask = nil
        isPlaying = false
        activeGroupID = nil
        currentAnchor = nil
        for member in group.members {
            guard let session = session(for: member), session.connection.connectionState == .connected else { continue }
            let token = session.connection.output.claim(.group)
            _ = try? await session.connection.withOutput(token) {
                _ = try await session.connection.command(.stopScroll(restoreAuto: nil, clear: nil))
            }
            memberStatus[member.physicalBoardID] = .connected
        }
    }
}
