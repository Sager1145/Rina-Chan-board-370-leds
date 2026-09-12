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
/// draggable panel (§2, §4.2).
struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PresetLiveModel.self) private var performance
    @Environment(VideoPlayerModel.self) private var video
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Environment(BLETransport.self) private var bleTransport
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
    private var selectedTab: AppTab { router.selectedTab }
    /// `-openControlCenter YES` presents the Control Center at launch, the
    /// same automated-simulator-run affordance as `-initialTab`.
    @State private var showControlCenter = UserDefaults.standard.bool(forKey: "openControlCenter")
    @State private var resyncTask: Task<Void, Never>?
    @State private var controlCenterDetent: PresentationDetent = .medium
    /// Ties the collapsed accessory to the expanded sheet so the system can
    /// zoom one into the other instead of sliding an unrelated sheet up.
    @Namespace private var controlCenterNamespace
    /// The loader is the first frame; the tabs mount one frame later so
    /// nothing is built before the animation is on screen.
    @State private var contentReady = false

    var body: some View {
        ZStack {
            if contentReady {
                tabs
                .tint(Color("AccentColor"))
                .modifier(ControlCenterPresenter(isPresented: $showControlCenter,
                                                 detent: $controlCenterDetent,
                                                 namespace: controlCenterNamespace))
                .task {
                    configureOutputHandlers()
                    await autoReconnect()
                }
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
                .onChange(of: connection.connectionState) { _, state in
                    if state == .connected {
                        // A flapping link can re-enter `.connected` while the
                        // previous resync is still in flight; without this the
                        // slower, older round trip could land last and
                        // overwrite fresher board state.
                        resyncTask?.cancel()
                        resyncTask = Task { await resynchronizeWithBoard() }
                    } else {
                        resyncTask?.cancel()
                        resyncTask = nil
                        textModel.suspendPreviewLoop()
                        editor.connectionChanged()
                        lipSyncModel.stop()
                        performance.suspendBoardOutput()
                        video.suspendBoardOutput()
                    }
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
        .onChange(of: scenePhase) { _, phase in
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
            // Let the overlay's first frame go out before the app is built.
            // A bare `Task.yield()` can resume inside the same run-loop turn,
            // before Core Animation commits; a timer hop crosses a real frame.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            controlCenter.loadDefaultsIfNeeded()
            textModel.loadDefaultsIfNeeded()
            await editor.restoreDraft()
            await textModel.restoreDraft()
            contentReady = true
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
                .tabItem { Label("控制", systemImage: "lightbulb.fill") }
                .tag(AppTab.control)

            ScrollTextView()
                .tabItem { Label("文字", systemImage: "t.square.fill") }
                .tag(AppTab.text)

            LipSyncView()
                .tabItem { Label("口型", systemImage: "waveform") }
                .tag(AppTab.lipSync)

            PerformanceTabView()
                .tabItem { Label("演出", systemImage: "music.note") }
                .tag(AppTab.presetLive)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
    }

    private func configureOutputHandlers() {
        connection.output.register(.manual) { editor.releaseOutput() }
        connection.output.register(.text) {
            if connection.output.source != .text { textModel.releaseOutput() }
        }
        connection.output.register(.lipSync) { lipSyncModel.stop() }
        connection.output.register(.performance) {
            if connection.connectionState == .connected { performance.pause() }
            else { performance.suspendBoardOutput() }
        }
        connection.output.register(.video) {
            video.releaseOutput(connected: connection.connectionState == .connected)
        }
    }

    /// §40: after a (re)connection, re-read the board's authoritative state
    /// and reconcile drafts — never the other way round.
    private func resynchronizeWithBoard() async {
        let generation = connection.connectionGeneration
        let session = connection.output.session
        guard let freshStatus = try? await connection.getStatus(),
              generation == connection.connectionGeneration,
              session == connection.output.session,
              !Task.isCancelled else { return }
        controlCenter.sync(from: freshStatus)

        if let frame = try? await connection.getFrame() {
            editor.adoptBoardFrameIfUntouched(frame)
        }
        guard !Task.isCancelled else { return }

        guard generation == connection.connectionGeneration, session == connection.output.session else { return }
        await textModel.restoreOnConnect(connection: connection)
        guard !Task.isCancelled, generation == connection.connectionGeneration,
              session == connection.output.session else { return }

        await faceLibrary.reload(connection: connection)
    }

    /// On launch, try to reconnect to the most recently used board via its
    /// remembered preferred transport. Runs at most once per app launch; BLE
    /// readiness is handled inside `BLETransport.connect()`.
    private func autoReconnect() async {
        guard !didAutoReconnect else { return }
        didAutoReconnect = true
        guard connection.connectionState == .disconnected else { return }
        guard let last = boardStore.boards.max(by: {
            ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast)
        }) else { return }
        switch last.preferredTransport {
        case "bluetooth":
            guard let uuid = UUID(uuidString: last.id) else { return }
            bleTransport.peripheralIdentifier = uuid
            _ = await connection.connect(using: bleTransport)
        case "wifi", "hotspot", "hotspot-tcp":
            guard let host = last.lastHost else { return }
            let kind: TransportKind = last.preferredTransport == "hotspot"
                ? .hotspot
                : .wifi(host: host, port: RinaLinkConstants.tcpPort)
            _ = await connection.connect(using: TCPTransport(host: host, kind: kind))
        default:
            break
        }
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
/// would give those releases a second, undocumented way in.
private struct ControlCenterPresenter: ViewModifier {
    @Environment(BoardConnection.self) private var connection
    @Binding var isPresented: Bool
    @Binding var detent: PresentationDetent
    var namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let transitionSourceID = "controlCenter"

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .tabViewBottomAccessory {
                    // The accessory hosts real controls, so it wires up its
                    // own expand affordance instead of being wrapped in one
                    // button that would swallow every tap.
                    BoardControlCenterAccessory(transitionSourceID: Self.transitionSourceID,
                                                transitionNamespace: namespace) {
                        isPresented = true
                    }
                }
                .sheet(isPresented: $isPresented) {
                    expandedSheet
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    // A grouped-list sheet doesn't paint its own background on
                    // iOS 26, which lets the tab behind it ghost through.
                    .presentationBackground(Color(.systemGroupedBackground))
                }
        } else {
            content
        }
    }

    /// The zoom and the plain transition are different `NavigationTransition`
    /// types, so the Reduce Motion choice has to be a branch, not a ternary.
    @available(iOS 26.0, *)
    @ViewBuilder
    private var expandedSheet: some View {
        let stack = NavigationStack {
            BoardControlCenterView(onDismiss: { isPresented = false })
        }
        if reduceMotion {
            stack
        } else {
            stack.navigationTransition(.zoom(sourceID: Self.transitionSourceID, in: namespace))
        }
    }
}

/// True where the system provides a persistent bottom accessory, so Settings
/// can omit its Control Center section instead of duplicating it.
enum ControlCenterPlacement {
    static var usesTabBarAccessory: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}
