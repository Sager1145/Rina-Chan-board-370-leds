import SwiftUI

/// 演出 and 视频 share one tab. The iPhone tab bar holds five items; a sixth
/// pushes 视频 and 设置 into a system "More" list, where each page also gains
/// a back button the other tabs don't have.
enum PerformanceTabMode: String, CaseIterable {
    case performance, video

    static let storageKey = "performanceTabMode"

    /// The mode the tab will open in.
    static var stored: PerformanceTabMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .performance
    }

    /// Passive restoration of this mode's last material. Runs during the
    /// boot loader for the stored mode, and again whenever the mode changes.
    @MainActor
    func restore(presetLive: PresetLiveModel, video: VideoPlayerModel) {
        switch self {
        case .performance:
            // Restore first: its own `if script == nil` guard already yields
            // to a script the user previously imported, so the demo only
            // fills in when there is nothing to restore. Calling these in
            // the other order let the demo win every time, since it sets
            // `script` before restore ever got a chance to run.
            presetLive.restoreLastImportIfNeeded()
            presetLive.loadDemoScriptIfNeeded()
        case .video:
            video.restoreLastVideoIfNeeded()
        }
    }
}

/// Which slice of a page a view renders: the board preview and its status
/// line, the transport sections between it and the 演出 | 视频 switch, or the
/// ones below it.
///
/// The preview parts are their own slices rather than part of `.transport`
/// because the two-column iPad layout pins them above the other column
/// (`BoardSplitPage`).
enum PerformancePagePart {
    case previewBoard, previewStatus, transport, content
}

/// One list for both pages. Switching modes swaps only the sections above and
/// below the switch; the list, its scroll position and the switch itself stay
/// put, so the segmented control slides instead of the whole page reloading.
struct PerformanceTabView: View {
    @AppStorage(PerformanceTabMode.storageKey) private var mode: PerformanceTabMode = .performance
    @Environment(PresetLiveModel.self) private var presetLive
    @Environment(VideoPlayerModel.self) private var video
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            BoardSplitPage {
                switch mode {
                case .performance: PresetLiveView(part: .previewBoard)
                case .video: VideoPlayerView(part: .previewBoard)
                }
            } status: {
                switch mode {
                case .performance: PresetLiveView(part: .previewStatus)
                case .video: VideoPlayerView(part: .previewStatus)
                }
            } controls: {
                switch mode {
                case .performance: PresetLiveView(part: .transport)
                case .video: VideoPlayerView(part: .transport)
                }
                PerformanceModeSection()
                switch mode {
                case .performance: PresetLiveView(part: .content)
                case .video: VideoPlayerView(part: .content)
                }
            }
            .listSectionSpacing(.compact)
            .rinaScrollBackground()
            .toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 0, for: .scrollContent)
            .errorAlert(Bindable(presetLive).errorMessage)
        }
        .errorAlert(Bindable(video).errorMessage)
        .onAppear { mode.restore(presetLive: presetLive, video: video) }
        .onChange(of: mode) { _, newMode in newMode.restore(presetLive: presetLive, video: video) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && mode == .performance {
                presetLive.pause()
            }
        }
    }
}

/// The 演出 | 视频 switch. Both pages place it directly under the playback
/// controls, so the preview and transport sit in the same spot on either page.
struct PerformanceModeSection: View {
    @AppStorage(PerformanceTabMode.storageKey) private var mode: PerformanceTabMode = .performance

    var body: some View {
        Section {
            Picker("模式", selection: $mode) {
                Text("演出").tag(PerformanceTabMode.performance)
                Text("视频").tag(PerformanceTabMode.video)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }
}
