import Foundation
import RinaCore
import WatchConnectivity

/// The phone end of the Apple Watch companion.
///
/// The watch never pairs with a board: it sends `WatchCommand`s here over
/// WatchConnectivity, this service runs them against the boards the phone is
/// connected to, and pushes a `WatchBoardSnapshot` back whenever anything the
/// watch shows changes.
///
/// Targeting rules (user requirement 2026-09-22):
/// - The watch has its own target — the phone's current choice by default,
///   or any connected board / any board group. Picking one on the watch never
///   changes the phone's active session or its "控制对象", so the phone keeps
///   doing whatever it was doing.
/// - A watch command aimed at the phone's own active board goes through the
///   same `BoardControlCenterModel` path the phone's Control Center uses, so
///   the phone's drafts and group fan-out stay consistent. Any other board is
///   driven directly through its own `BoardConnection`, bypassing the
///   phone's drafts entirely.
/// - Only an interrupting action (prev/next, auto on/off, lip sync) takes over
///   a board's output — exactly as the phone's own Control Center would.
///   Brightness, colour, interval and scroll speed retune whatever is
///   already running.
@MainActor
final class WatchLinkService {
    struct Dependencies {
        let sessions: BoardSessionStore
        let controlCenter: BoardControlCenterModel
        let lipSync: LipSyncModel
        let text: TextViewModel
        let groupStore: BoardGroupStore
        let fanOut: GroupControlFanOut
        let groupAutoCycler: GroupAutoCycler
        /// Retunes a live group-timed scroll; the phone's Text tab never
        /// touches the primary's own scroll timing while a group plays.
        let groupCoordinator: BoardGroupCoordinator
        /// The phone's persisted "控制对象" (`ControlTargetKey.groupID`).
        var controlTargetStorage: () -> String = {
            UserDefaults.standard.string(forKey: ControlTargetKey.groupID) ?? ""
        }
    }

    private let deps: Dependencies
    private let relay = WatchLinkSessionRelay()
    private var session: WCSession?
    private var publishTask: Task<Void, Never>?
    private var lastPublished: WatchBoardSnapshot?

    /// The watch's own target. `nil`/`phone` follows the phone.
    private(set) var selectedTargetID: String = WatchTargetChoice.phoneID
    /// A failure from the last watch command. Sent to the watch exactly once
    /// (cleared as soon as a snapshot carrying it goes out), so dismissing
    /// the alert there is final.
    private var lastCommandError: String?
    /// The board lip sync was started on from the watch, so a later stop
    /// closes *that* mouth even after the watch has retargeted.
    private weak var watchLipSyncConnection: BoardConnection?

    init(deps: Dependencies) {
        self.deps = deps
    }

    // MARK: Lifecycle

    /// Installs the WatchConnectivity delegate and starts mirroring state.
    /// No-op on devices without a paired-watch capability (iPad).
    func activate() {
        guard WCSession.isSupported(), session == nil else { return }
        let session = WCSession.default
        self.session = session
        relay.onPayload = { [weak self] data, reply in
            guard let command = try? WatchLinkCodec.decode(WatchCommand.self, from: data) else {
                reply?(Data())
                return
            }
            Task { @MainActor in
                guard let self else { reply?(Data()); return }
                // Reply straight away: a start that waits on the microphone
                // permission prompt would otherwise outlive WatchConnectivity's
                // reply timeout. The result reaches the watch as a push.
                reply?((try? WatchLinkCodec.encode(self.snapshot())) ?? Data())
                await self.handle(command)
                self.publish(force: true)
            }
        }
        relay.onStateChange = { [weak self] in
            Task { @MainActor in self?.publish(force: true) }
        }
        session.delegate = relay
        session.activate()
        deps.controlCenter.loadDefaultsIfNeeded()
        observe()
    }

    // MARK: Target

    private enum Route {
        /// The phone's active board, driven through the shared Control Center
        /// model (which also covers the phone's synced group via fan-out).
        case phoneActive(BoardConnection, groupSynced: Bool)
        /// One or more other boards, driven directly; nothing on the phone's
        /// screens changes except through the boards' own status echoes.
        case direct([BoardConnection])
    }

    private var phoneControlTarget: ControlTarget {
        ControlTarget.resolved(storedGroupIDString: deps.controlTargetStorage(), in: deps.groupStore)
    }

    /// The phone's Control Center routes prev/next/auto through the group
    /// cycler only while a group is targeted *and* the fan-out has a primary.
    private var phoneGroupSynced: Bool {
        if case .group = phoneControlTarget { return deps.fanOut.primaryID != nil }
        return false
    }

    private func members(of group: BoardGroup) -> [BoardSession] {
        group.members.compactMap { deps.sessions.session(matchingGroupMember: $0.physicalBoardID) }
    }

    private func targetChoices() -> [WatchTargetChoice] {
        var choices: [WatchTargetChoice] = []
        let active = deps.sessions.active
        let phoneName: String
        if case .group(let id) = phoneControlTarget,
           let group = deps.groupStore.groups.first(where: { $0.id == id }), phoneGroupSynced {
            phoneName = group.name
        } else {
            phoneName = active.connection.deviceName ?? active.name
        }
        choices.append(WatchTargetChoice(id: WatchTargetChoice.phoneID, kind: .phone, name: phoneName,
                                         isConnected: active.connection.connectionState == .connected,
                                         connectedCount: 1, memberCount: 1))
        for session in deps.sessions.sessions where session.connection.connectionState == .connected {
            choices.append(WatchTargetChoice(id: "board:\(session.id.uuidString)", kind: .board,
                                             name: session.connection.deviceName ?? session.name,
                                             isConnected: true, connectedCount: 1, memberCount: 1))
        }
        for group in deps.groupStore.groups {
            let connected = members(of: group).filter { $0.connection.connectionState == .connected }.count
            choices.append(WatchTargetChoice(id: "group:\(group.id.uuidString)", kind: .group, name: group.name,
                                             isConnected: connected > 0,
                                             connectedCount: connected, memberCount: group.members.count))
        }
        return choices
    }

    /// Resolves the watch's selection. A board that has since gone away (or
    /// a deleted group) resets the selection to following the phone and
    /// reports `resolved == false`: the snapshot then shows the phone's
    /// board, but a command that was aimed at the vanished target is
    /// dropped rather than executed on a board the user never chose.
    private func route() -> (route: Route, choice: WatchTargetChoice, resolved: Bool) {
        let choices = targetChoices()
        let phone = choices[0]
        let phoneRoute = Route.phoneActive(deps.sessions.active.connection, groupSynced: phoneGroupSynced)
        guard selectedTargetID != WatchTargetChoice.phoneID else { return (phoneRoute, phone, true) }
        guard let choice = choices.first(where: { $0.id == selectedTargetID }) else {
            selectedTargetID = WatchTargetChoice.phoneID
            return (phoneRoute, phone, false)
        }
        switch choice.kind {
        case .phone:
            return (phoneRoute, phone, true)
        case .board:
            let raw = String(choice.id.dropFirst("board:".count))
            guard let session = deps.sessions.sessions.first(where: { $0.id.uuidString == raw }) else {
                selectedTargetID = WatchTargetChoice.phoneID
                return (phoneRoute, phone, false)
            }
            if session === deps.sessions.active {
                // The watch picked the phone's own board explicitly: same
                // path as following the phone, minus the group routing —
                // the user asked for *this board*, not the phone's group.
                return (.phoneActive(session.connection, groupSynced: false), choice, true)
            }
            return (.direct([session.connection]), choice, true)
        case .group:
            let raw = String(choice.id.dropFirst("group:".count))
            guard let id = UUID(uuidString: raw),
                  let group = deps.groupStore.groups.first(where: { $0.id == id }) else {
                selectedTargetID = WatchTargetChoice.phoneID
                return (phoneRoute, phone, false)
            }
            // The phone's own synced group: reuse its fan-out/cycler so every
            // member keeps receiving identical frames.
            if phoneControlTarget == .group(id), phoneGroupSynced {
                return (.phoneActive(deps.sessions.active.connection, groupSynced: true), choice, true)
            }
            let connections = members(of: group)
                .filter { $0.connection.connectionState == .connected }
                .map(\.connection)
            return (.direct(connections), choice, true)
        }
    }

    /// The phone's synced group, when that is what the route drives.
    private var phoneSyncedGroup: BoardGroup? {
        guard phoneGroupSynced, case .group(let id) = phoneControlTarget else { return nil }
        return deps.groupStore.groups.first { $0.id == id }
    }

    /// True while the group coordinator is driving (or holding paused) a
    /// group-timed scroll for `group` — the only scroll a synced group has.
    private func groupScrollActive(_ group: BoardGroup) -> Bool {
        deps.groupCoordinator.activeGroupID == group.id
            && (deps.groupCoordinator.isPlaying || deps.groupCoordinator.isPaused)
    }

    // MARK: Snapshot

    /// The phone's current view of the watch's target. Every property read
    /// here is observable, so `observe()` re-publishes on any change.
    func snapshot() -> WatchBoardSnapshot {
        let (route, choice, _) = route()
        let connection: BoardConnection?
        let groupSynced: Bool
        switch route {
        case .phoneActive(let c, let synced):
            connection = c
            groupSynced = synced
        case .direct(let connections):
            connection = connections.first
            groupSynced = false
        }
        let status = connection?.status
        let renderer = status?.renderer
        let isConnected = connection?.connectionState == .connected
        let model = deps.controlCenter

        let board = WatchBoardSnapshot.Board(
            name: choice.name,
            isConnected: choice.kind == .group ? choice.isConnected : isConnected,
            batteryPercent: {
                if case .level(let percent)? = connection?.batteryReading { return percent }
                return nil
            }(),
            isCharging: connection?.isBatteryCharging ?? false,
            connectedCount: choice.connectedCount,
            memberCount: choice.memberCount
        )

        // The phone's own board reads through the Control Center drafts, so
        // the watch shows the same value the phone's slider does mid-drag.
        let usesPhoneDrafts: Bool
        if case .phoneActive = route { usesPhoneDrafts = true } else { usesPhoneDrafts = false }
        let brightness = usesPhoneDrafts ? model.draftBrightness
            : (renderer?.brightness ?? RinaLinkConstants.brightnessDefault)
        let intervalSeconds = usesPhoneDrafts ? model.autoIntervalDraft
            : Double(renderer?.autoIntervalMs ?? RinaLinkConstants.autoIntervalDefaultMs) / 1000
        let colorHex = usesPhoneDrafts ? model.colorHexDraft : (renderer?.color ?? model.colorHexDraft)
        let isAuto: Bool
        if groupSynced {
            isAuto = deps.groupAutoCycler.isRunning
        } else if usesPhoneDrafts {
            isAuto = model.isAutoMode(status: status)
        } else {
            isAuto = renderer?.mode == "auto"
        }
        let faceIndex = usesPhoneDrafts ? model.effectiveFaceIndex(status: status) : renderer?.autoFaceIndex

        let controls = WatchBoardSnapshot.Controls(
            brightnessRaw: brightness,
            brightnessMin: RinaLinkConstants.brightnessMin,
            brightnessMax: RinaLinkConstants.brightnessMax,
            isAutoMode: isAuto,
            autoIntervalSeconds: intervalSeconds,
            autoIntervalMinSeconds: Double(RinaLinkConstants.autoIntervalMinMs) / 1000,
            autoIntervalMaxSeconds: Double(RinaLinkConstants.autoIntervalMaxMs) / 1000,
            colorHex: colorHex,
            faceIndex: faceIndex,
            faceCount: renderer?.autoFaceCount,
            presets: (model.colorPresets?.parents ?? []).map { .init(name: $0.name, hex: $0.color) },
            isScrollActive: groupSynced
                ? phoneSyncedGroup.map(groupScrollActive) == true
                : isConnected && renderer?.firmwareScrollActive == true,
            scrollFps: TextViewModel.boardFps(intervalMs: renderer?.scrollIntervalMs, uiFps: renderer?.uiFps)
                ?? renderer?.scrollFps,
            scrollFpsMin: RinaLinkConstants.scrollFpsMin,
            scrollFpsMax: RinaLinkConstants.scrollFpsMax
        )

        let lip = deps.lipSync
        let permission: WatchBoardSnapshot.LipSync.Permission
        switch lip.permission {
        case .undetermined: permission = .undetermined
        case .granted: permission = .granted
        case .denied: permission = .denied
        }
        let lipSyncAvailable: Bool
        switch route {
        case .phoneActive: lipSyncAvailable = true
        case .direct(let connections): lipSyncAvailable = connections.count == 1
        }
        let lipSync = WatchBoardSnapshot.LipSync(
            isRunning: lip.isRunning,
            isStarting: lip.isStarting,
            canEditOptions: lip.canEditOptions,
            sensitivityDb: Double(lip.sensitivityDb),
            sensitivityMinDb: Self.sensitivityRange.lowerBound,
            sensitivityMaxDb: Self.sensitivityRange.upperBound,
            permission: permission,
            isAvailable: lipSyncAvailable
        )

        return WatchBoardSnapshot(
            targets: targetChoices(),
            selectedTargetID: selectedTargetID,
            board: board,
            controls: controls,
            lipSync: lipSync,
            errorMessage: lastCommandError
        )
    }

    /// The same span as the Lip Sync tab's 麦克风灵敏度 slider.
    static let sensitivityRange: ClosedRange<Double> = -70...(-10)

    // MARK: Commands

    func handle(_ command: WatchCommand) async {
        lastCommandError = nil
        if case .selectTarget(let id) = command {
            selectedTargetID = id
            _ = route() // validates, falling back to the phone if unknown
            return
        }
        let (route, _, resolved) = route()
        // The target the watch was showing is gone (board dropped, group
        // deleted): the selection has just been reset, and this command was
        // never meant for the board it would now land on.
        guard resolved else { return }
        switch command {
        case .requestState, .selectTarget:
            return
        case .setBrightness(let raw):
            await forEach(route,
                          phone: { model, c, _ in model.setBrightness(raw, connection: c) },
                          direct: { c in _ = try await c.command(.setBrightness(raw: Self.clamp(raw, RinaLinkConstants.brightnessMin, RinaLinkConstants.brightnessMax))) })
        case .stepFace(let direction):
            await forEach(route,
                          phone: { model, c, synced in
                              if synced { await self.deps.groupAutoCycler.step(direction: direction) }
                              else { await model.step(face: direction, connection: c) }
                          },
                          direct: { c in try await Self.step(direction: direction, on: c) })
        case .setAutoMode(let enabled):
            await forEach(route,
                          phone: { model, c, synced in
                              if synced {
                                  if enabled { _ = self.deps.groupAutoCycler.start() } else { self.deps.groupAutoCycler.stop() }
                              } else if model.isAutoMode(status: c.status) != enabled {
                                  await model.toggleAutoMode(connection: c)
                              }
                          },
                          direct: { c in try await Self.setAutoMode(enabled, on: c) })
        case .setAutoInterval(let seconds):
            await forEach(route,
                          phone: { model, c, _ in model.setAutoInterval(seconds, connection: c) },
                          direct: { c in
                              let ms = Self.clamp(Int((seconds * 1000).rounded()),
                                                  RinaLinkConstants.autoIntervalMinMs, RinaLinkConstants.autoIntervalMaxMs)
                              _ = try await c.command(.setAutoInterval(ms: ms))
                          })
        case .setColor(let hex):
            guard let (r, g, b) = RGBHex.parseHex(hex) else { return }
            let normalized = RGBHex.formatHex(r: r, g: g, b: b)
            await forEach(route,
                          phone: { model, c, _ in await model.setColor(hex: normalized, connection: c) },
                          direct: { c in _ = try await c.command(.setColor(hex: normalized)) })
        case .setScrollFps(let fps):
            let clamped = Self.clamp(fps, RinaLinkConstants.scrollFpsMin, RinaLinkConstants.scrollFpsMax)
            await forEach(route,
                          phone: { _, c, synced in
                              if synced {
                                  // A stitched group scroll is re-anchored as
                                  // one unit; retuning the primary alone
                                  // would tear the stitch apart.
                                  guard let group = self.phoneSyncedGroup, self.groupScrollActive(group) else { return }
                                  self.deps.text.requestedFps = Double(clamped)
                                  await self.deps.groupCoordinator.updatePlayback(group: group, fps: clamped, loop: nil)
                                  return
                              }
                              // The Text tab owns this board's scroll: retune
                              // through it so its speed slider follows.
                              if self.deps.text.boundTimelineId != nil {
                                  self.deps.text.setRequestedFps(Double(clamped), connection: c)
                              } else if c.status?.renderer?.firmwareScrollActive == true {
                                  try await Self.setScrollFps(clamped, on: c)
                              }
                          },
                          direct: { c in
                              guard c.status?.renderer?.firmwareScrollActive == true else { return }
                              try await Self.setScrollFps(clamped, on: c)
                          })
        case .lipSyncStart:
            guard let connection = lipSyncConnection(for: route) else {
                lastCommandError = String(localized: "多板组未同步时无法从手表开始口型同步")
                return
            }
            if deps.lipSync.isRunning { deps.lipSync.stop(connection: runningLipSyncConnection) }
            watchLipSyncConnection = connection
            await deps.lipSync.start(connection: connection)
        case .lipSyncStop:
            deps.lipSync.stop(connection: runningLipSyncConnection)
            watchLipSyncConnection = nil
        case .setLipSyncSensitivity(let db):
            guard deps.lipSync.canEditOptions else { return }
            deps.lipSync.sensitivityDb = Float(min(Self.sensitivityRange.upperBound,
                                                   max(Self.sensitivityRange.lowerBound, db)))
        }
    }

    /// Where the running lip sync is putting its mouth: the board the watch
    /// started it on, or the phone's active board when the phone started it.
    private var runningLipSyncConnection: BoardConnection {
        watchLipSyncConnection ?? deps.sessions.active.connection
    }

    private func lipSyncConnection(for route: Route) -> BoardConnection? {
        switch route {
        case .phoneActive(let c, _): return c
        case .direct(let connections): return connections.count == 1 ? connections.first : nil
        }
    }

    /// Runs a command down whichever route the target resolves to. Direct
    /// boards run concurrently and independently: one member failing must not
    /// stop the others.
    private func forEach(
        _ route: Route,
        phone: @MainActor (BoardControlCenterModel, BoardConnection, _ groupSynced: Bool) async throws -> Void,
        direct: @escaping @MainActor @Sendable (BoardConnection) async throws -> Void
    ) async {
        switch route {
        case .phoneActive(let connection, let synced):
            guard connection.connectionState == .connected else { return }
            do {
                try await phone(deps.controlCenter, connection, synced)
            } catch is CancellationError {
            } catch RatePumpError.dropped {
            } catch {
                lastCommandError = error.localizedDescription
            }
        case .direct(let connections):
            // One task per member, all awaited: members run concurrently and
            // independently, so one failing (or stalling) never stops the rest.
            let tasks = connections
                .filter { $0.connectionState == .connected }
                .map { connection in
                    Task { @MainActor () -> String? in
                        do {
                            try await direct(connection)
                            return nil
                        } catch is CancellationError {
                            return nil
                        } catch RatePumpError.dropped {
                            return nil
                        } catch {
                            return error.localizedDescription
                        }
                    }
                }
            var firstError: String?
            for task in tasks {
                if let message = await task.value, firstError == nil { firstError = message }
            }
            lastCommandError = firstError
        }
    }

    // MARK: Direct board operations (mirror `BoardControlCenterModel`)

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(high, max(low, value))
    }

    private static func setAutoMode(_ enabled: Bool, on connection: BoardConnection) async throws {
        let mode = enabled ? "auto" : "manual"
        guard (connection.status?.renderer?.mode == "auto") != enabled else { return }
        let token = connection.output.begin(enabled ? .automatic : .manual)
        try await connection.withOutput(token) { _ = try await connection.command(.setMode(mode: mode)) }
    }

    private static func step(direction: Int, on connection: BoardConnection) async throws {
        let token = connection.output.begin(.manual)
        if connection.status?.renderer?.firmwareScrollActive == true {
            try await connection.withOutput(token) {
                _ = try await connection.command(.stopScroll(restoreAuto: false, clear: false))
            }
        }
        let button = direction > 0 ? "B1" : "B2"
        try await connection.withOutput(token) { _ = try await connection.command(.button(button: button)) }
    }

    /// Retunes a scroll already on the board without claiming its output —
    /// taking the lease would pause whatever feature is driving it.
    private static func setScrollFps(_ fps: Int, on connection: BoardConnection) async throws {
        let intervalMs = ScrollRasterizer.intervalMs(forFps: fps)
        _ = try await connection.command(.setScrollInterval(intervalMs: intervalMs, fps: fps))
    }

    // MARK: Publishing

    /// Re-reads the snapshot under observation tracking and schedules a
    /// publish on the first change, then re-arms.
    private func observe() {
        withObservationTracking {
            _ = snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.snapshotDidChange() }
        }
    }

    private var pendingSince: ContinuousClock.Instant?

    private func snapshotDidChange() {
        observe()
        // Coalesce bursts (a slider drag, a status echo train) into one
        // update, but never starve: a stream of changes faster than the
        // debounce still publishes at least twice a second.
        let now = ContinuousClock.now
        let since = pendingSince ?? now
        pendingSince = since
        if now - since >= .milliseconds(500) {
            publishTask?.cancel()
            publish()
            return
        }
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    /// Pushes the snapshot: `applicationContext` so the watch app sees the
    /// latest state whenever it next opens, plus a live message while it is
    /// reachable. Skipped when nothing changed.
    func publish(force: Bool = false) {
        pendingSince = nil
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let snap = snapshot()
        guard force || snap != lastPublished else { return }
        lastPublished = snap
        // The error rode along once; the next snapshot must not re-raise it.
        lastCommandError = nil
        guard let data = try? WatchLinkCodec.encode(snap) else { return }
        let envelope = WatchLinkCodec.envelope(data)
        try? session.updateApplicationContext(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }
}
