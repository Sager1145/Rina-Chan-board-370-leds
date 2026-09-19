import SwiftUI

/// Scrolling-text transport row (design guide §24). System buttons and SF
/// Symbols only — no custom icon artwork.
///
/// Five pills, no separate send row: play/pause, stop, loop, « and ». The
/// first slot is "send and play" while the board has nothing to scroll, and
/// pause/resume once it does; stop is greyed out until there is a scroll.
struct TextPlaybackControls: View {
    var isConnected: Bool
    var hasTimeline: Bool
    /// The board reports a scroll of its own, bound here or not.
    var boardHasScroll: Bool
    var isPaused: Bool
    var isUploading: Bool
    /// N6: determinate upload fraction (0...1), when known, shown as a small
    /// circular ring inside the send pill instead of the indeterminate
    /// spinner. `nil` while uploading falls back to the indeterminate
    /// spinner; ignored while `isUploading` is false.
    var uploadProgress: Double?
    var isGeneratingFont: Bool
    var canSend: Bool
    @Binding var loopPlayback: Bool
    var loopDisabled: Bool
    var onSend: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onStop: () -> Void
    var onStepBackward: () -> Void
    var onStepForward: () -> Void

    /// Stepping, pausing and stopping act on the board's scroll session, so
    /// they only need one to exist there, not a timeline bound in the app.
    private var hasBoardScroll: Bool { hasTimeline || boardHasScroll }
    private var transportEnabled: Bool { isConnected && hasBoardScroll }

    var body: some View {
        HStack(spacing: 8) {
            playPauseControl
            // Stop keeps working in group mode, like send.
            control("stop.fill", label: "停止并清屏", action: onStop)
                .disabled(!transportEnabled)
            Toggle(isOn: $loopPlayback) {
                RepeatSymbol(isOn: loopPlayback)
                    .frame(maxWidth: .infinity)
            }
            .toggleStyle(.pill)
            .accessibilityLabel(LocalizedStringKey("循环播放"))
            .disabled(loopDisabled)
            control("chevron.backward.2", label: "上一帧", action: onStepBackward)
                .disabled(!transportEnabled)
            control("chevron.forward.2", label: "下一帧", action: onStepForward)
                .disabled(!transportEnabled)
        }
        .buttonStyle(.pill)
        .pillButtonRow()
    }

    /// What the first pill does right now.
    private enum PrimaryAction { case send, play, pause }

    private var primaryAction: PrimaryAction {
        hasBoardScroll ? (isPaused ? .play : .pause) : .send
    }

    /// What the pill did when the finger went down on it; `nil` with no touch
    /// in progress (VoiceOver and keyboard activation never set it).
    @State private var pressedAction: PrimaryAction?

    /// The board's status can change what the pill does while a finger is on
    /// it. A press that began on "pause" must not lift as "send and play", so
    /// it is dropped instead, as it was when each state had its own button.
    private func performPrimaryAction() {
        defer { pressedAction = nil }
        if let pressedAction, pressedAction != primaryAction { return }
        switch primaryAction {
        case .send: onSend()
        case .play: onPlay()
        case .pause: onPause()
        }
    }

    private func pressChanged(_ isPressed: Bool) {
        if isPressed {
            pressedAction = primaryAction
        } else {
            // The button's action runs in the same event as the lift, before
            // this; a press dragged off the pill never runs it at all.
            Task { @MainActor in pressedAction = nil }
        }
    }

    /// One button rather than a branch per state, so its identity stays
    /// stable and the icon swap animates instead of the whole control
    /// popping in and out.
    private var playPauseControl: some View {
        Button(action: performPrimaryAction) {
            Group {
                if !hasBoardScroll && isUploading {
                    // N6: a determinate ring when we know how far along
                    // the upload is, so there's no separate progress row
                    // in either single-board or group mode.
                    if let uploadProgress {
                        ProgressView(value: uploadProgress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                } else {
                    SwapSymbol(systemName: hasBoardScroll
                               ? (isPaused ? "play.fill" : "pause.fill")
                               : (isGeneratingFont ? "hourglass" : "play.fill"))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.stateSwap, value: isUploading)
        }
        .buttonStyle(PillButtonStyle(onPressChanged: pressChanged))
        .accessibilityLabel(hasBoardScroll
                            ? (isPaused ? LocalizedStringKey("继续") : LocalizedStringKey("暂停"))
                            : (isGeneratingFont ? LocalizedStringKey("加载字体…") : LocalizedStringKey("发送并播放")))
        .disabled(hasBoardScroll ? !transportEnabled : (!isConnected || isUploading || !canSend))
    }

    private func control(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(label)
    }
}
