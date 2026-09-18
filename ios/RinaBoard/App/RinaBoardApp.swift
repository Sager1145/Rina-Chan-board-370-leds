import SwiftUI
import RinaCore

@main
struct RinaBoardApp: App {
    // Each board retains its own connection; tabs control the selected session.
    // Draft models remain app-scoped so switching tabs preserves unsent work.
    @State private var router = AppRouter()
    @State private var sessions = BoardSessionStore()
    @State private var boardStore = BoardStore()
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
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .background { KeyboardDismissal().allowsHitTesting(false) }
                .environment(sessions)
                .environment(sessions.active.connection)
                .environment(router)
                .environment(boardStore)
                .environment(bootLoader)
                .environment(controlCenter)
                .environment(faceLibrary)
                .environment(editor)
                .environment(textModel)
                .environment(lipSyncModel)
                .environment(presetLiveModel)
                .environment(videoModel)
        }
    }
}
