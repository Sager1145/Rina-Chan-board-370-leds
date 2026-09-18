import SwiftUI

/// Scrolling-text transport row (design guide §24). System buttons and SF
/// Symbols only — no custom icon artwork.
///
/// Five pills, no separate send row: play/pause and stop sit on the left,
/// frame stepping in the middle and the loop toggle on the right. The second
/// slot is the stop button while the board is scrolling a bound timeline, and
/// turns into "send and play" once there is nothing to stop.
struct TextPlaybackControls: View {
    var isConnected: Bool
    var hasTimeline: Bool
    /// The board reports a scroll of its own, bound here or not.
    var boardHasScroll: Bool
    var isPaused: Bool
    var isUploading: Bool
    var isGeneratingFont: Bool
    var canSend: Bool
    @Binding var loopPlayback: Bool
    var loopDisabled: Bool
    /// Board-group mode (BOARD_GROUP_SPEC.md §3, v1 has no timed pause): when
    /// `true`, pause/play and frame-step stay visible but greyed out — only
    /// the send/stop pill and the loop toggle keep working.
    var transportLimitedToSendStop: Bool = false
    var onSend: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onStop: () -> Void
    var onStepBackward: () -> Void
    var onStepForward: () -> Void

    /// Stepping, pausing and stopping act on the board's scroll session, so
    /// they only need one to exist there, not a timeline bound in the app.
    private var hasBoardScroll: Bool { hasTimeline || boardHasScroll }
    private var transportEnabled: Bool { isConnected && hasBoardScroll && !transportLimitedToSendStop }

    var body: some View {
        HStack(spacing: 8) {
            if isPaused {
                control("play.fill", label: "继续", action: onPlay)
                    .disabled(!transportEnabled)
            } else {
                control("pause.fill", label: "暂停", action: onPause)
                    .disabled(!transportEnabled)
            }
            stopOrSendControl
            control("backward.frame.fill", label: "上一帧", action: onStepBackward)
                .disabled(!transportEnabled)
            control("forward.frame.fill", label: "下一帧", action: onStepForward)
                .disabled(!transportEnabled)
            Toggle(isOn: $loopPlayback) {
                RepeatSymbol(isOn: loopPlayback)
                    .frame(maxWidth: .infinity)
            }
            .toggleStyle(.pill)
            .accessibilityLabel(LocalizedStringKey("循环播放"))
            .disabled(loopDisabled)
        }
        .buttonStyle(.pill)
        .pillButtonRow()
    }

    @ViewBuilder
    private var stopOrSendControl: some View {
        if hasBoardScroll {
            // Stop keeps working in group mode, like send.
            control("stop.fill", label: "停止并清屏", action: onStop)
                .disabled(!isConnected)
        } else {
            Button(action: onSend) {
                Group {
                    if isUploading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: isGeneratingFont ? "hourglass" : "play.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill)
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
