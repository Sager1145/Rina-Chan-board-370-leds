import AVFoundation
import PhotosUI
import SwiftUI
import RinaCore

/// 视频 page of the 演出 tab: import a local video (Photos or Files), play it
/// on the phone, and stream it to the board as on/off faces. Same shape as
/// 演出: the board preview on top, transport below, then the material and its
/// conversion.
///
/// Hosted by `PerformanceTabView`, which owns the list and page lifecycle;
/// this view only supplies the sections for one slice of the page — the board
/// preview is its own slice because the two-column layout puts it in the
/// other column.
struct VideoPlayerView: View {
    let part: PerformancePagePart

    @Environment(BoardConnection.self) private var connection
    @Environment(VideoPlayerModel.self) private var model

    @State private var isImportingFile = false
    @State private var isPickingPhoto = false
    @State private var photoSelection: PhotosPickerItem?

    /// Stop stays reachable whenever something is playing or parked mid-way,
    /// connected or not — it is what silences the audio.
    private var isTransportActive: Bool { model.isPlaying || model.hasPlaybackProgress }
    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        switch part {
        case .previewBoard:
            previewBoard
        case .previewStatus:
            previewStatus
        case .transport:
            playbackSection
        case .content:
            sourcePreviewSection
            videoSection
            conversionSection
        }
    }

    // MARK: Source preview

    /// The video itself as the phone plays it, next to the 22×18 board
    /// preview above. Shows the current frame while paused or stopped.
    private var sourcePreviewSection: some View {
        Section {
            ZStack {
                Color.black
                if let player = model.player {
                    PlayerLayerView(player: player)
                } else {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(sourcePreviewAspectRatio, contentMode: .fit)
            // Framed by the list card around it, so the black picture doesn't
            // dissolve into a dark-mode page. A stroke on a zero-inset row
            // doesn't work: the cell's own larger corner radius clips the
            // stroke's corners away.
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            .accessibilityElement()
            .accessibilityLabel(previewAccessibilityDescription)
        }
    }

    /// The video's own shape, clamped between square and 16:9 so a portrait
    /// clip doesn't push the controls below off screen.
    private var sourcePreviewAspectRatio: CGFloat {
        let size = model.videoSize
        guard size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return min(max(size.width / size.height, 1), 16.0 / 9.0)
    }

    // MARK: Preview

    @ViewBuilder
    private var previewBoard: some View {
        BoardPreviewRow(
            frame: model.previewFrame,
            accessibilityDescription: previewAccessibilityDescription
        )
    }

    @ViewBuilder
    private var previewStatus: some View {
        if model.isPlaying && isConnected && !model.needsBoardResume {
            BoardPreviewStatus("正在输出到面板", systemImage: "dot.radiowaves.left.and.right", tone: .live) {
                VideoPositionCounterView()
            }
        } else if model.isPlaying {
            BoardPreviewStatus("仅本地预览", systemImage: "iphone", tone: .pending) {
                VideoPositionCounterView()
            }
        } else if model.hasPlaybackProgress {
            BoardPreviewStatus("已暂停", systemImage: "pause.circle", tone: .neutral) {
                VideoPositionCounterView()
            }
        } else if !isConnected {
            BoardPreviewStatus("未连接", systemImage: "circle.slash", tone: .neutral) {
                VideoPositionCounterView()
            }
        } else {
            BoardPreviewStatus("未播放", systemImage: "stop.circle", tone: .neutral) {
                VideoPositionCounterView()
            }
        }
    }

    private var previewAccessibilityDescription: String {
        guard let title = model.title else {
            return NSLocalizedString("视频预览，暂无内容", comment: "empty video preview")
        }
        return String(format: NSLocalizedString("视频预览：%@", comment: "video preview accessibility summary"), title)
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
                .disabled(!model.isPlaying && (!model.hasVideo || model.isLoading))

                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(LocalizedStringKey("停止"))
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
            VideoTransportSliderView()

            if model.needsBoardResume && isConnected {
                Button {
                    model.resumeBoardOutput(connection: connection)
                } label: {
                    Label("继续输出到面板", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        }
    }

    fileprivate static func formatMs(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    // MARK: Video

    private var videoSection: some View {
        Section {
            LabeledContent(NSLocalizedString("视频", comment: "video file row")) {
                if model.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            isPickingPhoto = true
                        } label: {
                            Label("从相册选择", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            isImportingFile = true
                        } label: {
                            Label("从文件选择", systemImage: "folder")
                        }
                    } label: {
                        Text(model.title ?? NSLocalizedString("导入视频…", comment: "choose a video"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            // Presented from the row that opens them: inside a list,
            // modifiers on a multi-section view land on every row.
            .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.movie]) { result in
                if case .success(let url) = result {
                    Task { await model.importFile(from: url) }
                }
            }
            .photosPicker(isPresented: $isPickingPhoto, selection: $photoSelection, matching: .videos)
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                photoSelection = nil
                Task { await model.importFromPhotos(item) }
            }
        }
    }

    // MARK: Conversion

    private var conversionSection: some View {
        Section {
            Picker(NSLocalizedString("画面适配", comment: "video fit picker"), selection: setting(\.fit)) {
                Text("填充").tag(VideoFrameQuantizer.Fit.fill)
                Text("适应").tag(VideoFrameQuantizer.Fit.fit)
                Text("拉伸").tag(VideoFrameQuantizer.Fit.stretch)
            }
            .pickerStyle(.menu)
            .tint(.secondary)

            Picker(NSLocalizedString("转换方式", comment: "video quantize mode picker"), selection: setting(\.mode)) {
                Text("阈值").tag(VideoFrameQuantizer.Mode.threshold)
                Text("抖动").tag(VideoFrameQuantizer.Mode.dither)
            }
            .pickerStyle(.menu)
            .tint(.secondary)

            Toggle("自动阈值", isOn: setting(\.autoThreshold))

            if !model.settings.autoThreshold {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("阈值")
                        Spacer()
                        Text(verbatim: "\(Int((model.settings.threshold * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: setting(\.threshold), in: 0...1)
                }
            }

            Toggle("反相", isOn: setting(\.invert))
            Toggle("镜像", isOn: setting(\.mirror))

            Picker(NSLocalizedString("帧率", comment: "video send frame rate picker"), selection: Binding(
                get: { model.frameRate },
                set: { model.frameRate = $0 }
            )) {
                ForEach(VideoPlayerModel.frameRates, id: \.self) { rate in
                    Text(verbatim: "\(rate) fps").tag(rate)
                }
            }
            .pickerStyle(.menu)
            .tint(.secondary)
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<VideoFrameQuantizer.Settings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Isolated position readers
//
// `positionMs` republishes at ~10 Hz (see `VideoPlayerModel.tick`), well down
// from the ~10-30 Hz frame-loop tick, but it is still the fastest-changing
// value this tab observes. Confining its reads to these two small subviews
// keeps the rest of `VideoPlayerView`'s body — the transport buttons, the
// source/conversion pickers — from re-evaluating on every position update.

/// The "mm:ss / mm:ss · n fps" line shown as the preview status detail.
private struct VideoPositionCounterView: View {
    @Environment(VideoPlayerModel.self) private var model

    var body: some View {
        if model.hasVideo {
            Text(verbatim: "\(VideoPlayerView.formatMs(model.positionMs)) / \(VideoPlayerView.formatMs(model.durationMs)) · \(model.frameRate) fps")
        }
    }
}

/// The scrub slider and its mm:ss labels.
private struct VideoTransportSliderView: View {
    @Environment(VideoPlayerModel.self) private var model

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
            .disabled(!model.hasVideo)

            HStack {
                Text(VideoPlayerView.formatMs(isSeeking ? Int(seekPositionMs) : model.positionMs))
                Spacer()
                Text(VideoPlayerView.formatMs(model.durationMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// A bare `AVPlayerLayer`: the picture only. AVKit's `VideoPlayer` would add
/// its own transport, duplicating the controls above.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    final class PlayerLayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// No #Preview: VideoPlayerModel and BoardConnection are wired together by the
// app entry point (see PresetLiveView.swift's identical note).
