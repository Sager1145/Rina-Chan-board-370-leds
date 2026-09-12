import SwiftUI

/// Scrolling-text transport row (design guide §24). System buttons and SF
/// Symbols only — no custom icon artwork.
///
/// Four buttons, no separate send row: the third slot is the stop button
/// while the board is scrolling a bound timeline, and turns into
/// "send and play" once there is nothing to stop.
struct TextPlaybackControls: View {
    var isConnected: Bool
    var hasTimeline: Bool
    var isPaused: Bool
    var isUploading: Bool
    var isGeneratingFont: Bool
    var canSend: Bool
    var onSend: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onStop: () -> Void
    var onStepBackward: () -> Void
    var onStepForward: () -> Void

    /// Stepping, pausing and stopping all need a timeline on the board.
    private var transportEnabled: Bool { isConnected && hasTimeline }

    var body: some View {
        HStack(spacing: 8) {
            control("backward.frame.fill", label: "上一帧", action: onStepBackward)
                .disabled(!transportEnabled)
            if isPaused {
                control("play.fill", label: "继续", action: onPlay)
                    .disabled(!transportEnabled)
            } else {
                control("pause.fill", label: "暂停", action: onPause)
                    .disabled(!transportEnabled)
            }
            centerControl
            control("forward.frame.fill", label: "下一帧", action: onStepForward)
                .disabled(!transportEnabled)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var centerControl: some View {
        if hasTimeline {
            control("stop.fill", label: "停止并清屏", action: onStop)
                .disabled(!transportEnabled)
        } else {
            Button(action: onSend) {
                Group {
                    if isUploading {
                        ProgressView()
                    } else {
                        Image(systemName: isGeneratingFont ? "hourglass" : "play.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(isGeneratingFont
                                ? LocalizedStringKey("加载字体…")
                                : LocalizedStringKey("发送并播放"))
            .disabled(!isConnected || isUploading || !canSend)
        }
    }

    private func control(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(label)
    }
}
