import SwiftUI
import RinaCore

@main
struct RinaBoardApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Board-group control fan-out addendum: the same persisted "控制对象"
    /// selection `Settings`/`BoardControlCenterView`/etc. read, watched here
    /// so `groupControlFanOut` can track it without those views needing a
    /// hard dependency on this type.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""
    /// Distinguishes the launch-time restore of `controlTargetGroupIDStorage`
    /// (its `onChange(initial: true)` first call) from every later, genuine
    /// change — see that `onChange` handler and `GroupControlFanOut.setTarget`.
    @State private var hasRestoredControlTarget = false
    // Each board retains its own connection; tabs control the selected session.
    // Draft models remain app-scoped so switching tabs preserves unsent work.
    @State private var router = AppRouter()
    @State private var sessions: BoardSessionStore
    @State private var boardStore = BoardStore()
    @State private var boardGroupStore: BoardGroupStore
    @State private var boardGroupCoordinator: BoardGroupCoordinator
    @State private var groupControlFanOut: GroupControlFanOut
    /// Auto-connects every member of a targeted board group in the
    /// background (user requirement: "切换到多板组时自动连接多个板子"; root cause of
    /// "多板组同步功能没有生效" — `GroupControlFanOut` only mirrors to members
    /// already connected). Kept alongside `groupControlFanOut` and driven by
    /// the same "控制对象" `onChange` below.
    @State private var groupAutoConnector: GroupAutoConnector
    /// Synced group auto face cycling (BOARD_GROUP_SPEC.md §3 addendum, user
    /// requirement "自动轮播表情必须同步"): built in `init()` alongside
    /// `groupControlFanOut` since it needs live references to
    /// `controlCenter`/`faceLibrary`, which are likewise built as `init()`
    /// locals below rather than via their own property-default expressions.
    @State private var groupAutoCycler: GroupAutoCycler
    @State private var bootLoader = BootLoaderModel()
    @State private var controlCenter: BoardControlCenterModel
    @State private var settingsWorkspace = SettingsWorkspace()
    @State private var faceLibrary: FaceLibraryModel
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
        let boardStore = BoardStore()
        _boardStore = State(initialValue: boardStore)
        let boardGroupStore = BoardGroupStore()
        let coordinator = BoardGroupCoordinator(store: boardGroupStore, sessions: sessions)
        sessions.isGroupOwned = { [weak coordinator] session in coordinator?.isGroupOwned(session) ?? false }
        _sessions = State(initialValue: sessions)
        _boardGroupStore = State(initialValue: boardGroupStore)
        _boardGroupCoordinator = State(initialValue: coordinator)
        let groupControlFanOut = GroupControlFanOut(
            sessions: sessions, groups: boardGroupStore, coordinator: coordinator
        )
        _groupControlFanOut = State(initialValue: groupControlFanOut)
        _groupAutoConnector = State(initialValue: GroupAutoConnector(
            sessions: sessions, groupStore: boardGroupStore, boardStore: boardStore
        ))
        let controlCenter = BoardControlCenterModel()
        let faceLibrary = FaceLibraryModel()
        _controlCenter = State(initialValue: controlCenter)
        _faceLibrary = State(initialValue: faceLibrary)
        _groupAutoCycler = State(initialValue: GroupAutoCycler(
            fanOut: groupControlFanOut,
            faceLibrary: faceLibrary,
            intervalProvider: { [controlCenter] in controlCenter.autoIntervalDraft }
        ))
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
                .environment(groupControlFanOut)
                .environment(groupAutoConnector)
                .environment(groupAutoCycler)
                .environment(bootLoader)
                .environment(controlCenter)
                .environment(settingsWorkspace)
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
                    // "App backgrounded" stop condition: pause the loop
                    // without clearing the user's auto intent, so a later
                    // foreground resumes it if the group is still targeted.
                    // `.inactive` (e.g. the app switcher, a system sheet, or
                    // Control Center momentarily covering the app) must not
                    // suspend the cycle — only a real background transition
                    // does (L2).
                    if newPhase == .active {
                        groupAutoCycler.resumeForForeground()
                        // Re-kick the auto-connector on every foreground, not
                        // just launch — a member that dropped while
                        // backgrounded (no reconnect loop runs off-screen)
                        // needs a fresh attempt now that the app is back.
                        // Not explicit: a foreground must not clear a
                        // member's user-disconnect block or retry cap.
                        groupAutoConnector.setTarget(
                            ControlTarget(storedGroupIDString: controlTargetGroupIDStorage), isExplicit: false
                        )
                    } else if newPhase == .background {
                        groupAutoCycler.suspendForBackground()
                    }
                }
                .onChange(of: controlTargetGroupIDStorage, initial: true) { _, stored in
                    // The very first call (`initial: true`) is a launch-time
                    // restore of the persisted target, not a user choice —
                    // `isExplicit: false` so it never force-selects a primary
                    // the user didn't pick (F6: only explicit choices switch
                    // control). Every later call is a real change to the
                    // stored value, i.e. an explicit selection.
                    let newTarget = ControlTarget(storedGroupIDString: stored)
                    let isExplicitChange = hasRestoredControlTarget
                    groupControlFanOut.setTarget(newTarget, isExplicit: isExplicitChange)
                    hasRestoredControlTarget = true
                    // Auto-connect every member of a freshly-targeted group —
                    // both an explicit "控制对象" choice and this launch-time
                    // restore (requirement: "切换到多板组时自动连接多个板子" and "on
                    // app launch/foreground when the persisted target is a
                    // group"). Only an explicit change clears user-
                    // disconnect blocks and retry caps.
                    groupAutoConnector.setTarget(newTarget, isExplicit: isExplicitChange)
                    // "target → single" stop condition: leaving group control
                    // must not leave the cycler still sending to the old
                    // primary underneath the now-single-board UI.
                    if newTarget == .single { groupAutoCycler.stop() }
                }
                .task {
                    // Wired once; both models are app-scoped for the app's
                    // lifetime, so there's no teardown to mirror.
                    groupControlFanOut.faceFrameResolver = { [faceLibrary] connection, reply in
                        faceLibrary.boardFaceFrame(
                            id: reply.autoFaceId, index: reply.autoFaceIndex,
                            generation: connection.connectionGeneration
                        )
                    }
                    groupControlFanOut.draftPromotionHook = { [editor] boardID in
                        editor.retagDraftForGroupPromotion(to: boardID)
                    }
                    // M2: a freshly-established group primary that's still in
                    // firmware auto keeps the user's auto intent alive via
                    // the synced cycler instead of just forcing it manual.
                    groupControlFanOut.primaryWasAutoHook = { [groupAutoCycler] in
                        groupAutoCycler.start()
                    }
                }
        }
    }
}
