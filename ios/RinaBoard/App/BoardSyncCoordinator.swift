import SwiftUI
import RinaCore

/// Runs the connection-lifecycle synchronization that used to live directly
/// in `RootTabView`'s `.task(id:)` closure (§40: after a (re)connection,
/// re-read the board's authoritative state and reconcile drafts — never the
/// other way round). Extracted so host-level tests can drive board-session
/// switches without going through SwiftUI's view body.
///
/// Also fixes: a resume-only re-run (foreground return bumping
/// `resumeGeneration` with the same connection generation and the same
/// active session) must still perform its resync reads, but must not run the
/// destructive "connection changed" clearing that a real generation/session
/// change requires — otherwise returning from background can cancel an
/// in-flight text upload (`TextViewModel.releaseOutput()`, which
/// `connectionChanged()` calls, cancels `uploadTask`).
@MainActor
final class BoardSyncCoordinator {
    private struct HandledKey: Equatable {
        let generation: UUID
        let sessionID: UUID?
        let connected: Bool
    }
    private var lastHandledKey: HandledKey?
    /// True once any board has answered a control connection this app run —
    /// gates the one-time "connected" greeting vs. the "connected again"
    /// reconnect greeting (design guide secondary-copy pass, 2026-09-17).
    private var hasConnectedSuccessfullyThisRun = false

    /// The environment objects `RootTabView`'s `.task(id:)` closure used to
    /// capture directly. Grouped so call sites (and tests) pass them once.
    struct Dependencies {
        let sessions: BoardSessionStore
        let router: AppRouter
        let boardStore: BoardStore
        let editor: ControlViewModel
        let textModel: TextViewModel
        let lipSyncModel: LipSyncModel
        let controlCenter: BoardControlCenterModel
        let faceLibrary: FaceLibraryModel
        let performance: PresetLiveModel
        let video: VideoPlayerModel
        /// Reads `RootTabView`'s current `scenePhase` at the moment it is
        /// called, not a value captured when `synchronize` started. BLE round
        /// trips can suspend long enough for the app to background in
        /// between, and every site that gates a playback/mic start on the
        /// phase needs that answer, not a stale one from before the awaits.
        let scenePhase: @MainActor () -> ScenePhase
    }

    /// Mirrors the previous `.task(id:)` closure body exactly, except for the
    /// resume-only `textModel.connectionChanged()` guard described above.
    func synchronize(
        connection: BoardConnection,
        deps: Dependencies,
        draftsRestored: Bool,
        showControlCenter: Binding<Bool>,
        configureOutputHandlers: () -> Void
    ) async {
        configureOutputHandlers()
        deps.faceLibrary.synchronizeBoardGeneration(connection.connectionGeneration)

        let previousKey = lastHandledKey
        let key = HandledKey(generation: connection.connectionGeneration, sessionID: deps.sessions.active.id,
                             connected: connection.connectionState == .connected)
        let isResumeOnly = previousKey == key
        lastHandledKey = key
        // A genuine reconnect: the same session was connected before, dropped
        // (its `connected` flag went false, which only happens on a real
        // disconnect/reconnecting transition — see `HandledKey`), and is
        // connected again. The very first successful connection this run is
        // reported separately below, once the board actually answers.
        let isGenuineReconnect = key.connected && !isResumeOnly && hasConnectedSuccessfullyThisRun
            && previousKey?.sessionID == key.sessionID && previousKey?.connected == false
        let isFirstConnectionThisRun = key.connected && !isResumeOnly && !hasConnectedSuccessfullyThisRun

        deps.controlCenter.connectionChanged()
        // A pure resume (same generation, same active session) must not
        // cancel an in-flight text upload; a real generation/session change
        // still clears it exactly as before.
        if !isResumeOnly {
            deps.textModel.connectionChanged()
        }
        deps.editor.connectionChanged(generation: connection.connectionGeneration)
        if draftsRestored, connection.connectionState == .connected,
           let boardID = connection.boardKey {
            deps.editor.boardDidChange(to: boardID)
        }
        deps.lipSyncModel.stop()
        deps.performance.suspendBoardOutput()
        deps.video.suspendBoardOutput()
        if draftsRestored, connection.connectionState == .connected {
            await resynchronizeWithBoard(connection: connection, deps: deps,
                                         showControlCenter: showControlCenter,
                                         isFirstConnectionThisRun: isFirstConnectionThisRun,
                                         isGenuineReconnect: isGenuineReconnect)
        }
    }

    /// §40: after a (re)connection, re-read the board's authoritative state
    /// and reconcile drafts — never the other way round.
    private func resynchronizeWithBoard(
        connection: BoardConnection,
        deps: Dependencies,
        showControlCenter: Binding<Bool>,
        isFirstConnectionThisRun: Bool = false,
        isGenuineReconnect: Bool = false
    ) async {
        let generation = connection.connectionGeneration
        let session = connection.output.session
        let initialTab = deps.router.selectedTab
        // A run only restores when it began in the foreground. After that,
        // only `.background` stops it: `.inactive` (a banner, the app
        // switcher, a permission alert) must let it finish, because nothing
        // re-triggers a sync when the phase returns to `.active` from there.
        let startedActive = deps.scenePhase() == .active
        guard connection.connectionState == .connected, !Task.isCancelled else { return }
        // Foreground recovery also needs fresh reads: the board can change
        // modes while this app is suspended without dropping the transport.
        guard let status = try? await connection.getStatus() else { return }
        let preview = try? await connection.getPreviewSync()
        // `deps.scenePhase()` is read live here, not a value captured before
        // the two awaits above: the app can background mid-round-trip, and
        // this is the last check before playback/mic restores start below.
        guard !Task.isCancelled, generation == connection.connectionGeneration,
              deps.sessions.active.connection === connection,
              session == connection.output.session,
              initialTab == deps.router.selectedTab,
              startedActive, deps.scenePhase() != .background else { return }
        // The board has answered and is still the active one — the proof
        // the greeting lines require, not merely the transport reporting
        // `.connected`.
        if isFirstConnectionThisRun {
            hasConnectedSuccessfullyThisRun = true
            deps.controlCenter.showConnectionGreeting(
                NSLocalizedString("已连接到璃奈板", comment: "secondary caption shown once after the first successful board connection this app run")
            )
        } else if isGenuineReconnect {
            deps.controlCenter.showConnectionGreeting(
                NSLocalizedString("已重新连接", comment: "secondary caption shown after reconnecting to the board following a genuine drop")
            )
        }
        deps.controlCenter.sync(from: status)

        if let mode = BoardResumeMode.resolve(status: status, preview: preview) {
            let stream = BoardResumeMode.streamState(status: status, preview: preview)
            let streamID = stream.id.flatMap { $0.isEmpty ? nil : $0 }
            if mode != .performance { deps.performance.pause() }
            if mode != .video { deps.video.pause() }
            // Mode first, preview second: the right tab is already showing
            // before anything is mirrored, and only the tab that owns the
            // board's mode mirrors it. A connection made from Settings stays
            // in Settings: the user is still managing boards there, and the
            // playback resumes below already skip when their tab isn't shown.
            let stayInSettings = initialTab == .settings
            if !stayInSettings { deps.router.showBoardMode(mode) }
            // Neither of these is user-initiated, and written back to back
            // they land in one SwiftUI update: the sheet's collapse and a tab
            // change then play over each other. Crossing a frame first lets
            // the tab change commit while it is still hidden behind the
            // sheet, so the collapse runs alone and reveals the destination
            // already in place. A bare `Task.yield()` can resume inside the
            // same run-loop turn, so this is a timer hop (see RootTabView's
            // boot sequence). Only when there is actually a sheet to collapse.
            if !stayInSettings, showControlCenter.wrappedValue {
                try? await Task.sleep(for: .milliseconds(16))
                // Live-read: this is the last await before the mode-specific
                // restores below start playback or the mic.
                guard !Task.isCancelled, generation == connection.connectionGeneration,
                      deps.scenePhase() != .background else { return }
                showControlCenter.wrappedValue = false
            }
            if mode == .control {
                deps.editor.boardModeSynchronized(generation: generation)
                await deps.editor.refreshBoardDisplay(connection: connection)
            }
            if mode != .text, BoardResumeMode.isPlaybackPaused(status: status, preview: preview) {
                deps.performance.pause()
                deps.video.pause()
                await deps.faceLibrary.reload(connection: connection)
                return
            }
            switch mode {
            case .control:
                break
            case .text:
                await deps.textModel.restoreOnConnect(connection: connection)
            case .lipSync:
                guard let streamID else {
                    deps.lipSyncModel.errorMessage = "面板未提供原同步记录，无法自动恢复嘴形同步。"
                    break
                }
                await deps.lipSyncModel.start(connection: connection, resumingStreamID: streamID) { [weak self] in
                    guard let self, deps.router.selectedTab == .lipSync else { return false }
                    return await self.boardStillMatches(mode, streamID: streamID, generation: generation,
                                                        session: session, connection: connection, deps: deps)
                }
            case .performance:
                guard let streamID else {
                    deps.performance.pause()
                    deps.performance.errorMessage = "面板未提供原播放记录，无法自动恢复演出。"
                    break
                }
                await deps.performance.restorePlaybackFromBoard(connection: connection,
                                                                 streamID: streamID, positionMs: stream.positionMs) { [weak self] in
                    guard let self, deps.router.selectedTab == .presetLive
                        && UserDefaults.standard.string(forKey: PerformanceTabMode.storageKey)
                            == PerformanceTabMode.performance.rawValue else { return false }
                    return await self.boardStillMatches(mode, streamID: streamID, generation: generation,
                                                        session: session, connection: connection, deps: deps)
                }
            case .video:
                guard let streamID else {
                    deps.video.pause()
                    deps.video.errorMessage = "面板未提供原播放记录，无法自动恢复视频。"
                    break
                }
                await deps.video.restorePlaybackFromBoard(connection: connection,
                                                           streamID: streamID, positionMs: stream.positionMs) { [weak self] in
                    guard let self, deps.router.selectedTab == .presetLive
                        && UserDefaults.standard.string(forKey: PerformanceTabMode.storageKey)
                            == PerformanceTabMode.video.rawValue else { return false }
                    return await self.boardStillMatches(mode, streamID: streamID, generation: generation,
                                                        session: session, connection: connection, deps: deps)
                }
            }
        }
        guard !Task.isCancelled, generation == connection.connectionGeneration,
              deps.sessions.active.connection === connection else { return }

        await deps.faceLibrary.reload(connection: connection)
    }

    /// Media loading and microphone permission can suspend long enough for
    /// another client or a GPIO button to take over. Recheck before sending.
    private func boardStillMatches(
        _ mode: BoardResumeMode, streamID: String?, generation: UUID, session: UUID?,
        connection: BoardConnection, deps: Dependencies
    ) async -> Bool {
        guard !Task.isCancelled, deps.scenePhase() != .background,
              deps.sessions.active.connection === connection,
              generation == connection.connectionGeneration,
              session == connection.output.session else { return false }
        guard let status = try? await connection.getStatus() else { return false }
        let preview = try? await connection.getPreviewSync()
        guard !Task.isCancelled, deps.scenePhase() != .background,
              deps.sessions.active.connection === connection,
              generation == connection.connectionGeneration,
              session == connection.output.session,
              BoardResumeMode.resolve(status: status, preview: preview) == mode,
              !BoardResumeMode.isPlaybackPaused(status: status, preview: preview) else { return false }
        let currentID = BoardResumeMode.streamState(status: status, preview: preview).id
            .flatMap { $0.isEmpty ? nil : $0 }
        return currentID == streamID
    }
}
