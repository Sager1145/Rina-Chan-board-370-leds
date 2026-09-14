import SwiftUI
import RinaCore

@main
struct RinaBoardApp: App {
    // Each board retains its own connection; tabs control the selected session.
    // Draft models remain app-scoped so switching tabs preserves unsent work.
    // Each construction is wrapped in a signpost interval (PR-14 measurement)
    // so Instruments can attribute launch time per model; `RinaPerf.measure`
    // returns its block's result unchanged, so this does not affect
    // construction order or semantics. `@State` initial-value expressions run
    // once, during this struct's synthesized init.
    @State private var router = RinaPerf.measure("ModelInit.router") { AppRouter() }
    @State private var sessions = RinaPerf.measure("ModelInit.sessions") { BoardSessionStore() }
    @State private var boardStore = RinaPerf.measure("ModelInit.boardStore") { BoardStore() }
    @State private var bootLoader = RinaPerf.measure("ModelInit.bootLoader") { BootLoaderModel() }
    @State private var controlCenter = RinaPerf.measure("ModelInit.controlCenter") { BoardControlCenterModel() }
    @State private var faceLibrary = RinaPerf.measure("ModelInit.faceLibrary") { FaceLibraryModel() }
    @State private var editor = RinaPerf.measure("ModelInit.editor") { ControlViewModel() }
    @State private var textModel = RinaPerf.measure("ModelInit.text") { TextViewModel() }
    @State private var lipSyncModel = RinaPerf.measure("ModelInit.lipSync") { LipSyncModel() }
    @State private var presetLiveModel = RinaPerf.measure("ModelInit.presetLive") { PresetLiveModel() }
    @State private var videoModel = RinaPerf.measure("ModelInit.video") { VideoPlayerModel() }

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
                .environment(sessions.active.bleTransport)
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
