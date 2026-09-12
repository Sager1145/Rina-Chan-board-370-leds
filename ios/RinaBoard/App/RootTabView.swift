import SwiftUI
import RinaCore

/// The four primary destinations (design guide §4.1, §66).
enum AppTab: String, CaseIterable {
    case control, text, liveVideo, settings

    /// Accepts the older `-initialTab` values used by automated simulator
    /// runs, mapping the retired tabs onto their new homes.
    init(launchArgument raw: String) {
        switch raw {
        case "control", "faces": self = .control
        case "text": self = .text
        case "liveVideo", "video": self = .liveVideo
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

/// Root navigation: a native `TabView` with the four primary destinations,
/// plus the global Control Center.
///
/// The Control Center never replaces the selected tab. On iOS 26 it rides in
/// the system tab-bar bottom accessory and expands into a real detented
/// sheet; on iOS 17–25, where no such persistent system surface exists, it
/// lives at the top of Settings instead of being faked with a custom
/// draggable panel (§2, §4.2).
struct RootTabView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Environment(BLETransport.self) private var bleTransport
    @Environment(BootLoaderModel.self) private var bootLoader
    @Environment(ControlViewModel.self) private var editor
    @Environment(TextViewModel.self) private var textModel
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(FaceLibraryModel.self) private var faceLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(AppSettingsKey.keepScreenAwake) private var keepScreenAwake = false
    @AppStorage(AppSettingsKey.restoreLastTab) private var restoreLastTab = false

    @State private var didAutoReconnect = false
    @State private var selectedTab = AppTab.initialSelection()
    /// `-openControlCenter YES` presents the Control Center at launch, the
    /// same automated-simulator-run affordance as `-initialTab`.
    @State private var showControlCenter = UserDefaults.standard.bool(forKey: "openControlCenter")
    @State private var resyncTask: Task<Void, Never>?
    @State private var controlCenterDetent: PresentationDetent = .medium
    /// Ties the collapsed accessory to the expanded sheet so the system can
    /// zoom one into the other instead of sliding an unrelated sheet up.
    @Namespace private var controlCenterNamespace

    var body: some View {
        ZStack {
            tabs
                .tint(Color("AccentColor"))
                .modifier(ControlCenterPresenter(isPresented: $showControlCenter,
                                                 detent: $controlCenterDetent,
                                                 namespace: controlCenterNamespace))
                .task {
                    // Board status fetch begins only after the loader is gone.
                    await bootLoader.waitUntilDone()
                    await autoReconnect()
                }
                .onChange(of: selectedTab) { _, tab in
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
                    }
                }

            if bootLoader.isVisible {
                BootLoaderOverlay()
            }
        }
        .onAppear {
            bootLoader.start(reduceMotion: reduceMotion)
            controlCenter.loadDefaultsIfNeeded()
            textModel.loadDefaultsIfNeeded()
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            ControlView()
                .tabItem { Label("控制", systemImage: "square.grid.3x3.fill") }
                .tag(AppTab.control)

            ScrollTextView()
                .tabItem { Label("文字", systemImage: "textformat") }
                .tag(AppTab.text)

            LiveVideoView()
                .tabItem { Label("实时视频", systemImage: "video.fill") }
                .tag(AppTab.liveVideo)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
    }

    /// §40: after a (re)connection, re-read the board's authoritative state
    /// and reconcile drafts — never the other way round.
    private func resynchronizeWithBoard() async {
        _ = try? await connection.getStatus()
        // `onChange(of: connection.status)` only fires when the value actually
        // differs, so a reconnect that reports identical status — or a
        // `getStatus` that fails without mutating it — would otherwise leave
        // the Control Center showing the previous session's values.
        controlCenter.sync(from: connection.status)
        guard !Task.isCancelled else { return }

        if let frame = try? await connection.getFrame() {
            editor.adoptBoardFrameIfUntouched(frame)
        }
        guard !Task.isCancelled else { return }

        await textModel.restoreOnConnect(connection: connection)
        guard !Task.isCancelled else { return }

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
