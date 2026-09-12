import SwiftUI
import RinaCore

@main
struct RinaBoardApp: App {
    // One shared board connection/session for the whole app (§36): tabs never
    // establish their own. The editor, text and Control Center models are
    // app-scoped too, so an unsent draft survives switching tabs (§40).
    @State private var router = AppRouter()
    @State private var connection = BoardConnection()
    @State private var boardStore = BoardStore()
    @State private var bleTransport = BLETransport()
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
                .environment(connection)
                .environment(router)
                .environment(boardStore)
                .environment(bleTransport)
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
