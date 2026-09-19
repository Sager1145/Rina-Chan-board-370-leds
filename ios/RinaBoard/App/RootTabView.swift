import SwiftUI
import RinaCore

/// The primary destinations (design guide §4.1, §66).
enum AppTab: String, CaseIterable {
    case control, text, lipSync, presetLive, settings

    /// Accepts the older `-initialTab` values used by automated simulator
    /// runs, mapping the retired tabs onto their new homes.
    init(launchArgument raw: String) {
        switch raw {
        case "control", "faces": self = .control
        case "text": self = .text
        // `liveVideo` was the single placeholder tab both live features grew
        // out of; it opens the one that needs no material to show something.
        case "lipSync", "lipsync": self = .lipSync
        case "presetLive", "liveVideo": self = .presetLive
        case "video":
            // 视频 is a page inside the 演出 tab; open the tab on that page.
            UserDefaults.standard.set(PerformanceTabMode.video.rawValue, forKey: PerformanceTabMode.storageKey)
            self = .presetLive
        case "settings", "debug", "connect": self = .settings
        default: self = .control
        }
    }

    /// The tab to open on launch: an explicit `-initialTab` launch argument
    /// (used by automated simulator runs) wins, then the remembered tab when
    /// "restore last tab" is on, then Control.
    static func initialSelection() -> AppTab {
        let defaults = UserDefaults.standard
        if let argument = defaults.string(forKey: "initialTab") {
            return AppTab(launchArgument: argument)
        }
        if defaults.bool(forKey: AppSettingsKey.restoreLastTab),
           let raw = defaults.string(forKey: AppSettingsKey.lastSelectedTab),
           let tab = AppTab(rawValue: raw) {
            return tab
        }
        return .control
    }
}

/// Root navigation: a native `TabView` with the five primary destinations,
/// plus the global Control Center.
///
/// The Control Center never replaces the selected tab. On iOS 26 it rides in
/// the system tab-bar bottom accessory and expands into a real detented
/// sheet; on iOS 17–25, where no such persistent system surface exists, it
/// lives at the top of Settings instead of being faked with a custom
/// draggable panel (§2, §4.2). The two-column iPad layout has neither: every
/// page carries the panel under its own board preview — see
/// `ControlCenterPlacement`.
struct RootTabView: View {
    @Environment(BoardSessionStore.self) private var sessions
    @Environment(AppRouter.self) private var router
    @Environment(PresetLiveModel.self) private var performance
    @Environment(VideoPlayerModel.self) private var video
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Environment(BootLoaderModel.self) private var bootLoader
    @Environment(ControlViewModel.self) private var editor
    @Environment(TextViewModel.self) private var textModel
    @Environment(LipSyncModel.self) private var lipSyncModel
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(FaceLibraryModel.self) private var faceLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(AppSettingsKey.keepScreenAwake) private var keepScreenAwake = false
    @AppStorage(AppSettingsKey.restoreLastTab) private var restoreLastTab = false

    @State private var didAutoReconnect = false
    @State private var reconnectModel = ConnectionViewModel(startBonjourBrowsing: false)
    private var selectedTab: AppTab { router.selectedTab }
    /// `-openControlCenter YES` presents the Control Center at launch, the
    /// same automated-simulator-run affordance as `-initialTab`.
    @State private var showControlCenter = UserDefaults.standard.bool(forKey: "openControlCenter")
    @State private var controlCenterDetent: PresentationDetent = .medium
    /// Ties the collapsed accessory to the expanded sheet so the system can
    /// zoom one into the other instead of sliding an unrelated sheet up.
    @Namespace private var controlCenterNamespace
    /// The loader is the first frame; the tabs mount one frame later so
    /// nothing is built before the animation is on screen.
    @State private var contentReady = false
    @State private var draftsRestored = false
    @State private var wasBackgrounded = false
    @State private var resumeGeneration = 0
    @State private var syncCoordinator = BoardSyncCoordinator()
    /// A live mirror of `scenePhase`, kept in `@State` (persistent storage
    /// shared across every `RootTabView` value SwiftUI creates while this
    /// task keeps running) rather than read directly from `@Environment`:
    /// the `.task(id:)` closure below only restarts when its id changes, so
    /// an `@Environment` property captured into that closure would freeze at
    /// whatever phase was current when the task started. `BoardSyncCoordinator`
    /// needs the current phase at every await inside a single run.
    @State private var liveScenePhase: ScenePhase = .active
    /// One scroll offset for the Control Center column every tab's
    /// `BoardSplitPage` shows on iPad, so the column stays put across tabs.
    @State private var controlCenterColumnScroll = ControlCenterColumnScroll()

    var body: some View {
        ZStack {
            if contentReady {
                tabs
                .tint(Color("AccentColor"))
                .modifier(ControlCenterPresenter(isPresented: $showControlCenter,
                                                 detent: $controlCenterDetent,
                                                 namespace: controlCenterNamespace))
                .onChange(of: selectedTab) { previous, tab in
                    // Leaving 口型 releases the microphone. Beyond not leaving
                    // a recording indicator lit on a tab the user walked away
                    // from, this is what keeps the two live features from
                    // fighting over the audio session: 演出 sets the category
                    // to `.playback`, which would reconfigure the engine out
                    // from under a live input tap.
                    if previous == .lipSync, tab != .lipSync {
                        lipSyncModel.stop(connection: connection)
                    }
                    guard restoreLastTab else { return }
                    UserDefaults.standard.set(tab.rawValue, forKey: AppSettingsKey.lastSelectedTab)
                }
                .onChange(of: keepScreenAwake, initial: true) { _, enabled in
                    UIApplication.shared.isIdleTimerDisabled = enabled
                }
                .onChange(of: connection.status) { _, status in
                    controlCenter.sync(from: status)
                }
                .task(id: BoardSynchronizationID(generation: connection.connectionGeneration,
                                                  connected: connection.connectionState == .connected,
                                                  draftsRestored: draftsRestored,
                                                  resumeGeneration: resumeGeneration,
                                                  isBackgrounded: scenePhase == .background)) {
                    await syncCoordinator.synchronize(
                        connection: connection,
                        deps: BoardSyncCoordinator.Dependencies(
                            sessions: sessions, router: router, boardStore: boardStore,
                            editor: editor, textModel: textModel, lipSyncModel: lipSyncModel,
                            controlCenter: controlCenter, faceLibrary: faceLibrary,
                            performance: performance, video: video,
                            scenePhase: { liveScenePhase }
                        ),
                        draftsRestored: draftsRestored,
                        showControlCenter: $showControlCenter,
                        configureOutputHandlers: configureOutputHandlers
                    )
                }
                // 演出 and 视频 both play sound on the phone. Taking the board
                // already pauses the other while connected; this covers the
                // disconnected case, where no lease changes hands.
                .onChange(of: performance.isPlaying) { _, playing in
                    if playing { video.pause() }
                }
                .onChange(of: video.isPlaying) { _, playing in
                    if playing { performance.pause() }
                }
            }

            if bootLoader.isVisible {
                BootLoaderOverlay()
            }
        }
        .onChange(of: faceLibrary.pendingEditRequest) { _, request in
            guard let request else { return }
            editor.loadForEditing(request)
            router.selectedTab = .control
            faceLibrary.consumePendingEditRequest(id: request.id)
        }
        .errorAlert($reconnectModel.lastErrorMessage)
        .onChange(of: scenePhase, initial: true) { _, phase in
            liveScenePhase = phase
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasBackgrounded = true }
            if phase == .active, wasBackgrounded {
                wasBackgrounded = false
                resumeGeneration += 1
            }
            lipSyncModel.scenePhaseChanged(phase, connection: connection)
            if phase != .active {
                performance.pause()
                Task { await editor.persistDraft(); await textModel.persistDraft() }
            }
            // 视频 plays through brief .inactive moments (Notification Center,
            // the app-switcher peek); in the background the video output
            // stops delivering frames, so pause there.
            if phase == .background {
                video.pause()
            }
        }
        .onAppear {
            configureOutputHandlers()
            bootLoader.start(reduceMotion: reduceMotion)
        }
        .task {
            let initialSession = sessions.active
            let initialBoardID = initialSession.boardID
            // Let the overlay's first frame go out before the app is built.
            // A bare `Task.yield()` can resume inside the same run-loop turn,
            // before Core Animation commits; a timer hop crosses a real frame.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            controlCenter.loadDefaultsIfNeeded()
            textModel.loadDefaultsIfNeeded()
            // The timed loader can finish before disk reads do. Mount the
            // tabs first so slow draft restoration cannot leave an empty
            // window after the overlay disappears.
            contentReady = true
            RinaPerf.signposter.emitEvent("ContentReady")
            await editor.restoreDraft()
            await textModel.restoreDraft()
            guard !Task.isCancelled else { return }
            draftsRestored = true
            // Keep board synchronization behind draft restoration even
            // though the interface is already available.
            await autoReconnect(ifSelectionRemains: initialSession, boardID: initialBoardID)
        }
        .task {
            // `-replayBootAfter <seconds>`: the same automated-simulator-run
            // affordance as `-initialTab`, for recording the loader over a
            // given tab without tapping the Debug screen's replay button.
            let delay = UserDefaults.standard.double(forKey: "replayBootAfter")
            guard delay > 0 else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            bootLoader.replay()
        }
    }

    private var tabs: some View {
        TabView(selection: Bindable(router).selectedTab) {
            ControlView()
                .tabItem { Label("表情显示", image: "TabRinaFace") }
                .tag(AppTab.control)

            ScrollTextView()
                .tabItem { Label("文字滚动", systemImage: "t.square.fill") }
                .tag(AppTab.text)

            LipSyncView()
                .tabItem { Label("嘴形识别", systemImage: "waveform") }
                .tag(AppTab.lipSync)

            PerformanceTabView()
                .tabItem { Label("演出", systemImage: "music.note") }
                .tag(AppTab.presetLive)

            SettingsView()
                .tabItem { Label("设定", image: "TabRinaSettings") }
                .tag(AppTab.settings)
        }
        .environment(controlCenterColumnScroll)
    }

    private func configureOutputHandlers() {
        connection.output.register(.manual) {
            guard sessions.active.connection === connection else { return }
            editor.releaseOutput()
        }
        connection.output.register(.text) {
            guard sessions.active.connection === connection else { return }
            if connection.output.source != .text { textModel.releaseOutput() }
        }
        connection.output.register(.lipSync) {
            guard sessions.active.connection === connection else { return }
            lipSyncModel.stop()
        }
        connection.output.register(.performance) {
            guard sessions.active.connection === connection else { return }
            if connection.connectionState == .connected { performance.pause() }
            else { performance.suspendBoardOutput() }
        }
        connection.output.register(.video) {
            guard sessions.active.connection === connection else { return }
            video.releaseOutput(connected: connection.connectionState == .connected)
        }
    }

    /// On launch, try to reconnect to the most recently used board via its
    /// remembered preferred transport. Runs at most once per app launch; BLE
    /// readiness is handled inside `BLETransport.connect()`.
    private func autoReconnect(
        ifSelectionRemains initialSession: BoardSession,
        boardID initialBoardID: String?
    ) async {
        guard !didAutoReconnect else { return }
        didAutoReconnect = true
        guard let last = boardStore.boards.max(by: {
            ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast)
        }) else { return }
        guard let target = sessions.sessionForAutomaticReconnect(
            id: last.id,
            name: last.name,
            ifCurrent: initialSession,
            withBoardID: initialBoardID
        ) else { return }
        await reconnectModel.connectSavedBoard(
            last, ble: target.bleTransport,
            connection: target.connection, boardStore: boardStore,
            disconnectOtherHotspotSessions: {
                for session in sessions.sessions
                where session.connection !== target.connection && session.connection.transportKind == .hotspot {
                    session.connection.disconnect()
                }
            }
        )
    }
}

/// Attaches the collapsed Control Center to the system tab bar, and the
/// expanded sheet it opens into, where iOS provides that surface (26+).
///
/// Expanding and collapsing use the system zoom transition: the sheet grows
/// out of the accessory's summary region and shrinks back into it on
/// dismissal (including the interactive drag-to-dismiss), so the two surfaces
/// read as one control that changes size rather than two unrelated screens.
/// With Reduce Motion on, the transition falls back to the system default,
/// which is a plain cross-fade/slide with no scaling.
///
/// On earlier releases it adds nothing at all — not even the sheet — because
/// the Settings tab hosts the Control Center there; leaving the sheet attached
/// would give those releases a second, undocumented way in. The two-column
/// iPad layout gets no accessory and never presents the sheet, since every
/// page carries the panel in its preview column: the user asked for no
/// separate bottom bar there.
private struct ControlCenterPresenter: ViewModifier {
    @Environment(BoardConnection.self) private var connection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isPresented: Bool
    @Binding var detent: PresentationDetent
    var namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion resolved at the moment the sheet is opened, not read
    /// live: the zoom and the plain transition are different types, so the
    /// choice has to be a branch, and a branch that flips while the sheet is
    /// up would swap the `NavigationStack`'s identity and rebuild its content
    /// mid-presentation. It is only ever written while nothing is presented.
    ///
    /// Seeded from UIKit rather than defaulted to `true`, because
    /// `-openControlCenter YES` has the sheet presented on the very first
    /// update: the `onChange` below is already blocked by its own guard by
    /// then, and there is no ordering guarantee that it would run before the
    /// sheet's content is built anyway.
    @State private var useZoomTransition = !UIAccessibility.isReduceMotionEnabled

    static let transitionSourceID = "controlCenter"

    private var placement: ControlCenterPlacement {
        .resolve(splitLayout: BoardPageColumns.isSplit(horizontalSizeClass))
    }

    func body(content: Content) -> some View {
        // The branch is on the OS version only, never on the width class.
        // Everything this modifier wraps is the root `TabView`, so a branch
        // that flips when a Stage Manager window is resized or snapped to
        // full screen would tear the tab bar down and rebuild it — the items
        // visibly re-tint and fade in mid-resize. The width class only turns
        // the accessory on and off; the sheet stays attached and is simply
        // never presented in the two-column layout.
        if #available(iOS 26.0, *), placement != .settingsLink {
            accessoryHost(content)
                // Reopening starts at the detent it was opened at, not the one
                // it was last dragged to: a sheet left at `.large` would
                // otherwise collapse across twice the distance next time, into
                // the same small region of the bar. Reset after the collapse
                // has finished, so it cannot re-detent mid-transition.
                .sheet(isPresented: sheetPresented, onDismiss: { detent = .medium }) {
                    expandedSheet
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    // A grouped-list sheet doesn't paint its own background on
                    // iOS 26, which lets the tab behind it ghost through.
                    .presentationBackground(Color(.systemGroupedBackground))
                }
                // Keeps the flag current while nothing is presented. The
                // launch-argument presentation is already up when this first
                // runs, so it is the seeded default above that covers that
                // path, not this.
                .onChange(of: reduceMotion, initial: true) { _, reduced in
                    guard !isPresented else { return }
                    useZoomTransition = !reduced
                }
                // Widening into the two-column layout closes the sheet, as
                // removing the modifier used to, so it does not reappear when
                // the window is narrowed again.
                .onChange(of: placement) { _, placement in
                    if placement != .tabBarAccessory { isPresented = false }
                }
        } else {
            content
        }
    }

    /// The sheet only exists in the single-column layout; the two-column one
    /// carries the panel in every preview column instead.
    private var sheetPresented: Binding<Bool> {
        Binding(get: { isPresented && placement == .tabBarAccessory },
                set: { isPresented = $0 })
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private func accessoryHost(_ content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: placement == .tabBarAccessory) {
                accessory
            }
        } else if placement == .tabBarAccessory {
            // iOS 26.0 has no way to switch the accessory off in place, so
            // only there does a width-class change still rebuild the tab bar.
            content.tabViewBottomAccessory { accessory }
        } else {
            content
        }
    }

    @available(iOS 26.0, *)
    private var accessory: some View {
        // The accessory hosts real controls, so it wires up its own expand
        // affordance instead of being wrapped in one button that would
        // swallow every tap.
        BoardControlCenterAccessory(transitionSourceID: Self.transitionSourceID,
                                    transitionNamespace: namespace) {
            // Never while presented: swapping the flag under a live sheet is
            // the identity change the flag exists to prevent. Unreachable
            // today, since the sheet covers the bar, but a smaller detent
            // would expose the accessory again.
            guard !isPresented else { return }
            useZoomTransition = !reduceMotion
            isPresented = true
        }
    }

    /// The zoom and the plain transition are different `NavigationTransition`
    /// types, so the choice has to be a branch, not a ternary — see
    /// `useZoomTransition` for why it is not read from the environment here.
    @available(iOS 26.0, *)
    @ViewBuilder
    private var expandedSheet: some View {
        let stack = NavigationStack {
            BoardControlCenterView(onDismiss: { isPresented = false })
        }
        if useZoomTransition {
            stack.navigationTransition(.zoom(sourceID: Self.transitionSourceID, in: namespace))
        } else {
            stack
        }
    }
}

/// Where the global Control Center lives. A property of the layout, not of
/// the OS version alone: the two-column iPad layout has a home for it on every
/// page and therefore wants neither the accessory nor the Settings link.
enum ControlCenterPlacement {
    /// The system tab-bar bottom accessory, which expands into a sheet
    /// (iOS 26+, single column).
    case tabBarAccessory
    /// Inline under each page's board preview (the two-column iPad layout).
    /// Settings has no preview and so shows no panel at all; it is one column
    /// away on every other tab.
    case previewColumn
    /// A pushed screen under Settings (iOS 17–25, single column), where no
    /// persistent system bottom surface exists and the guide forbids faking
    /// one (§2).
    case settingsLink

    static func resolve(splitLayout: Bool) -> ControlCenterPlacement {
        if splitLayout { return .previewColumn }
        if #available(iOS 26.0, *) { return .tabBarAccessory }
        return .settingsLink
    }
}

private struct BoardSynchronizationID: Hashable {
    let generation: UUID
    let connected: Bool
    let draftsRestored: Bool
    let resumeGeneration: Int
    /// True only for `.background` — entering it changes this id, which
    /// cancels any in-flight synchronize task via `.task(id:)` instead of
    /// leaving it to run to a restore/start that the background handler
    /// (this view's `onChange(of: scenePhase)`) already paused around.
    let isBackgrounded: Bool
}
