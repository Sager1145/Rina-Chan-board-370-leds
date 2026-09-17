import SwiftUI
import UniformTypeIdentifiers
import RinaCore

/// Preset Live tab: play a local audio file and drive the board's face off a
/// keyframe script (`.rinalive`, see `LivePerformanceScript.swift`), clocked
/// off the audio player's real playback position.
///
/// Hosted by `PerformanceTabView`, which owns the list and page lifecycle;
/// this view only supplies the sections for one half of the page.
struct PresetLiveView: View {
    let part: PerformancePagePart

    @Environment(BoardConnection.self) private var connection
    @Environment(PresetLiveModel.self) private var model

    @State private var isImportingAudio = false
    @State private var isImportingScript = false

    /// Whether the model has something running (or paused mid-way) that a
    /// stop/pause tap must still be able to reach. Disconnection must never
    /// disable this: `push` already no-ops while disconnected, and a running
    /// performance is still meaningful as local audio + preview playback with
    /// the board simply not receiving frames — but it must always be
    /// stoppable, or an audio session an app dropped off Wi-Fi leaves the
    /// speaker playing with dead transport buttons.
    private var isTransportActive: Bool { model.isPlaying || model.hasPlaybackProgress }
    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        switch part {
        case .transport:
            previewSection
            playbackSection
        case .content:
            songSection
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        Section {
            BoardPreviewRow(
                frame: model.previewFrame,
                accessibilityDescription: previewAccessibilityDescription
            )
        } footer: {
            previewStatus
        }
    }

    @ViewBuilder
    private var previewStatus: some View {
        if model.isPlaying && isConnected && !model.needsBoardResume {
            BoardPreviewStatus("正在输出到面板", systemImage: "dot.radiowaves.left.and.right", tone: .live) {
                PresetLiveKeyframeCounterView()
            }
        } else if model.isPlaying {
            BoardPreviewStatus("仅本地预览", systemImage: "iphone", tone: .pending) {
                PresetLiveKeyframeCounterView()
            }
        } else if model.hasPlaybackProgress {
            BoardPreviewStatus("已暂停", systemImage: "pause.circle", tone: .neutral) {
                PresetLiveKeyframeCounterView()
            }
        } else if !isConnected {
            BoardPreviewStatus("未连接", systemImage: "circle.slash", tone: .neutral) {
                PresetLiveKeyframeCounterView()
            }
        } else {
            BoardPreviewStatus("未播放", systemImage: "stop.circle", tone: .neutral) {
                PresetLiveKeyframeCounterView()
            }
        }
    }

    private var previewAccessibilityDescription: String {
        if let script = model.script, let index = model.currentKeyframeIndex {
            return String(format: NSLocalizedString("演出预览，第 %1$lld 关键帧，共 %2$lld 个",
                                                     comment: "preset live preview accessibility summary"),
                          index + 1, script.keyframes.count)
        }
        return NSLocalizedString("演出预览，暂无内容", comment: "empty preset live preview")
    }

    // MARK: Playback

    /// Two sections: the pill row clears its cell background, so sharing a
    /// section with ordinary rows left it sitting on top of a broken card.
    @ViewBuilder
    private var playbackSection: some View {
        Section {
            HStack(spacing: 8) {
                Button {
                    if model.isPlaying {
                        model.pause()
                    } else {
                        model.play(connection: connection)
                    }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(model.isPlaying
                                    ? LocalizedStringKey("暂停")
                                    : LocalizedStringKey("播放"))
                // Starting needs a script and audio; connectivity never
                // gates this. Pausing an already-running performance must
                // always be reachable, connected or not.
                .disabled(!model.isPlaying && !model.canPlay)

                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(LocalizedStringKey("停止"))
                // Disconnection must never disable stop: it's the only thing
                // that deactivates the audio session, and a dropped board
                // connection is not a reason to strand a playing/paused
                // performance with no way to silence it.
                .disabled(!isTransportActive)

                Toggle(isOn: Binding(
                    get: { model.loops },
                    set: { model.loops = $0 }
                )) {
                    RepeatSymbol(isOn: model.loops)
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.pill)
                .accessibilityLabel(LocalizedStringKey("循环播放"))

                // On means sound on: the pill lights up while audio plays
                // and goes grey when muted.
                Toggle(isOn: Binding(
                    get: { !model.isMuted },
                    set: { model.isMuted = !$0 }
                )) {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.pill)
                .accessibilityLabel(LocalizedStringKey("声音"))
            }
            .buttonStyle(.pill)
            .pillButtonRow()
        }

        Section {
            PresetLiveTransportSliderView()
        }
    }

    fileprivate static func formatMs(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    // MARK: Built-in performances

    /// One row: a dropdown of every built-in performance, plus a 自定义…
    /// entry that opens the file importers.
    ///
    /// The song is the only thing a user normally picks here, so it gets a
    /// single control rather than a list of rows competing with a separate
    /// pair of audio/script importers. Importing is still reachable, but as
    /// one entry inside the same menu instead of a parallel section.
    private var songSection: some View {
        Section {
            Picker(NSLocalizedString("歌曲", comment: "song picker label"), selection: songSelection) {
                ForEach(model.builtInPerformances) { performance in
                    Text(songLabel(performance)).tag(performance.id as String?)
                }
                Divider()
                Text("自定义…").tag(Self.customSelection as String?)
            }
            .pickerStyle(.menu)

            songDetail

            if model.selectedBuiltIn == nil {
                // Only meaningful once the user is off the built-ins: show
                // what their own material is, and let them change it.
                LabeledContent(NSLocalizedString("音频", comment: "audio file row")) {
                    Button(model.audioTitle ?? NSLocalizedString("选择音频…", comment: "choose an audio file")) {
                        isImportingAudio = true
                    }
                }
                // Presented from the row that opens it: inside a list,
                // modifiers on a multi-section view land on every row.
                .fileImporter(isPresented: $isImportingAudio, allowedContentTypes: [.audio]) { result in
                    if case .success(let url) = result {
                        Task { await model.importAudio(from: url) }
                    }
                }
                LabeledContent(NSLocalizedString("脚本", comment: "script file row")) {
                    Button(model.scriptName ?? NSLocalizedString("选择脚本…", comment: "choose a script file")) {
                        isImportingScript = true
                    }
                }
                .fileImporter(isPresented: $isImportingScript, allowedContentTypes: [.plainText, .data]) { result in
                    if case .success(let url) = result {
                        Task { await model.importScript(from: url) }
                    }
                }
            } else if let performance = selectedPerformance, !performance.hasAudio {
                Text("这首没有音频文件。运行 tools/fetch_preset_live_audio.sh 获取，或改选「自定义…」导入你自己的音频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Sentinel tag for the "import my own" entry. A real performance id can
    /// never collide with it — those are all `performance_*` resource names.
    private static let customSelection = "__custom__"

    private var selectedPerformance: BuiltInPerformance? {
        model.builtInPerformances.first { $0.id == model.selectedBuiltIn }
    }

    private var songSelection: Binding<String?> {
        Binding(
            get: { model.selectedBuiltIn ?? Self.customSelection },
            set: { choice in
                guard let choice else { return }
                // Picking the sentinel means "leave this song, go back to my own
                // material". It used to be discarded here, and since nothing else
                // calls `enterCustom()`, custom mode became unreachable for the
                // rest of the install once any built-in had been selected.
                guard choice != Self.customSelection else {
                    model.enterCustom()
                    return
                }
                guard let performance = model.builtInPerformances.first(where: { $0.id == choice }) else { return }
                model.selectBuiltIn(performance)
            }
        )
    }

    /// Title only. A menu `Picker` renders the selected item's label inside
    /// the row, and title + artist + duration is long enough there to be
    /// truncated mid-word; the rest of the detail goes on its own line below.
    private func songLabel(_ performance: BuiltInPerformance) -> String {
        performance.title
    }

    /// Artist, duration and keyframe count for whatever is selected.
    @ViewBuilder
    private var songDetail: some View {
        if let performance = selectedPerformance {
            HStack(spacing: 6) {
                if !performance.artist.isEmpty {
                    Text(performance.artist)
                    Text("·")
                }
                Text(Self.formatMs(performance.durationMs)).monospacedDigit()
                Text("·")
                Text(String(format: NSLocalizedString("%lld 关键帧", comment: "keyframe count"),
                            performance.keyframes))
                    .monospacedDigit()
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Isolated position readers
//
// `positionMs` republishes at ~10 Hz (see `PresetLiveModel.tick`), well down
// from the ~33 Hz clock tick, but it is still the fastest-changing value this
// tab observes. Confining its reads to these two small subviews keeps the
// rest of `PresetLiveView`'s body — the transport buttons, the song picker —
// from re-evaluating on every position update.

/// The "mm:ss / mm:ss · 关键帧 n / m" line shown as the preview status detail.
private struct PresetLiveKeyframeCounterView: View {
    @Environment(PresetLiveModel.self) private var model

    var body: some View {
        if let script = model.script {
            Text(verbatim: "\(PresetLiveView.formatMs(model.positionMs)) / \(PresetLiveView.formatMs(model.durationMs)) · ")
                + Text("关键帧 \(model.currentKeyframeIndex.map { $0 + 1 } ?? 0) / \(script.keyframes.count)")
        }
    }
}

/// The scrub slider and its mm:ss labels.
private struct PresetLiveTransportSliderView: View {
    @Environment(PresetLiveModel.self) private var model

    @State private var isSeeking = false
    @State private var seekPositionMs: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(
                value: Binding(
                    get: { isSeeking ? seekPositionMs : Double(model.positionMs) },
                    set: { seekPositionMs = $0 }
                ),
                in: 0...Double(max(1, model.durationMs)),
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing {
                        model.seek(toMs: Int(seekPositionMs))
                    } else {
                        seekPositionMs = Double(model.positionMs)
                    }
                }
            )
            .disabled(!model.canPlay)

            HStack {
                Text(PresetLiveView.formatMs(isSeeking ? Int(seekPositionMs) : model.positionMs))
                Spacer()
                Text(PresetLiveView.formatMs(model.durationMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

// No #Preview: PresetLiveModel and BoardConnection are wired together by the
// app entry point, and a meaningful preview would need a live BoardConnection
// (see ConnectionView.swift's identical note).
