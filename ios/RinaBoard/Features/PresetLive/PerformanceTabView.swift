import SwiftUI

/// 演出 and 视频 share one tab. The iPhone tab bar holds five items; a sixth
/// pushes 视频 and 设置 into a system "More" list, where each page also gains
/// a back button the other tabs don't have.
enum PerformanceTabMode: String, CaseIterable {
    case performance, video

    static let storageKey = "performanceTabMode"
}

/// Which half of a page a view renders: the sections above the 演出 | 视频
/// switch, or the ones below it.
enum PerformancePagePart {
    case transport, content
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
            List {
                Group {
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
                .rinaTranslucentRows()
            }
            .listSectionSpacing(.compact)
            .rinaScrollBackground()
            .toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 0, for: .scrollContent)
            .errorAlert(Bindable(presetLive).errorMessage)
        }
        .errorAlert(Bindable(video).errorMessage)
        .onAppear { restore(mode) }
        .onChange(of: mode) { _, newMode in restore(newMode) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && mode == .performance {
                presetLive.pause()
            }
        }
    }

    private func restore(_ mode: PerformanceTabMode) {
        switch mode {
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
