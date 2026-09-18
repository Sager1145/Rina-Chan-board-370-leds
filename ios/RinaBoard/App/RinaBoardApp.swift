import SwiftUI
import RinaCore

@main
struct RinaBoardApp: App {
    @Environment(\.scenePhase) private var scenePhase
    // Each board retains its own connection; tabs control the selected session.
    // Draft models remain app-scoped so switching tabs preserves unsent work.
    @State private var router = AppRouter()
    @State private var sessions: BoardSessionStore
    @State private var boardStore = BoardStore()
    @State private var boardGroupStore: BoardGroupStore
    @State private var boardGroupCoordinator: BoardGroupCoordinator
    @State private var bootLoader = BootLoaderModel()
    @State private var controlCenter = BoardControlCenterModel()
    @State private var faceLibrary = FaceLibraryModel()
    @State private var editor = ControlViewModel()
    @State private var textModel = TextViewModel()
    @State private var lipSyncModel = LipSyncModel()
    @State private var presetLiveModel = PresetLiveModel()
    @State private var videoModel = VideoPlayerModel()

    init() {
        AppSettingsKey.registerDefaults()
        // The loader is the first thing on screen; get its texture and
        // images ready in the background before the first frame.
        BootLoaderOverlay.prewarm()

        // Board groups (BOARD_GROUP_SPEC.md §3): the coordinator needs the
        // same session store instance the app injects everywhere else, and
        // `sessions.select(_:)` needs a way to ask the coordinator whether a
        // session is currently group-owned without a hard dependency on it.
        let sessions = BoardSessionStore()
        let boardGroupStore = BoardGroupStore()
        let coordinator = BoardGroupCoordinator(store: boardGroupStore, sessions: sessions)
        sessions.isGroupOwned = { [weak coordinator] session in coordinator?.isGroupOwned(session) ?? false }
        _sessions = State(initialValue: sessions)
        _boardGroupStore = State(initialValue: boardGroupStore)
        _boardGroupCoordinator = State(initialValue: coordinator)
        #if DEBUG
        Self.seedDemoGroupIfNeeded(store: boardGroupStore)
        #endif
    }

    #if DEBUG
    /// Screenshot-tooling only: `-seedDemoGroup YES` creates a fixed
    /// three-board demo group (if one by this name doesn't already exist)
    /// and points the "控制对象" menu at it, so a fresh simulator can be
    /// screenshotted in multi-board mode without pairing real hardware.
    /// Compiled out of Release.
    private static func seedDemoGroupIfNeeded(store: BoardGroupStore) {
        guard UserDefaults.standard.string(forKey: "seedDemoGroup") == "YES" else { return }
        let name = "演示组"
        if let existing = store.groups.first(where: { $0.name == name }) {
            UserDefaults.standard.set(existing.id.uuidString, forKey: ControlTargetKey.groupID)
            return
        }
        let group = store.create(name: name)
        let members: [(id: String, displayName: String)] = [
            ("DEMO-A", "璃奈板 A"),
            ("DEMO-B", "璃奈板 B"),
            ("DEMO-C", "璃奈板 C"),
        ]
        for member in members {
            try? store.addMember(
                groupID: group.id,
                member: BoardGroup.Member(physicalBoardID: member.id, displayName: member.displayName)
            )
        }
        store.setMode(id: group.id, mode: .stitched)
        try? store.setGap(groupID: group.id, afterSlot: 0, columns: 2)
        try? store.setGap(groupID: group.id, afterSlot: 1, columns: 2)
        UserDefaults.standard.set(group.id.uuidString, forKey: ControlTargetKey.groupID)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .background { KeyboardDismissal().allowsHitTesting(false) }
                .environment(sessions)
                .environment(sessions.active.connection)
                .environment(router)
                .environment(boardStore)
                .environment(boardGroupStore)
                .environment(boardGroupCoordinator)
                .environment(bootLoader)
                .environment(controlCenter)
                .environment(faceLibrary)
                .environment(editor)
                .environment(textModel)
                .environment(lipSyncModel)
                .environment(presetLiveModel)
                .environment(videoModel)
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    // BOARD_GROUP_SPEC §3 / M1: re-anchoring only runs while
                    // the app is active; it must not exit a running group
                    // play just because the app went to the background.
                    boardGroupCoordinator.isAppActive = newPhase == .active
                }
        }
    }
}
