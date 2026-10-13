import SwiftUI

/// Which of the phone's boards the watch drives: follow the phone, any
/// connected board, or any board group. Choosing here changes only the
/// watch's target — the phone keeps its own selection and whatever it is
/// currently playing.
struct WatchTargetPickerView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 20

    var body: some View {
        List {
            ForEach(model.snapshot?.targets ?? []) { choice in
                let selected = choice.id == model.snapshot?.selectedTargetID
                Button {
                    watchPlaySelectionHaptic()
                    model.selectTarget(choice.id)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: choice.kind))
                            .foregroundStyle(choice.isConnected ? Color.accentColor : .secondary)
                            .frame(width: iconWidth)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name)
                                .lineLimit(1)
                            Text(subtitle(for: choice))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 2)
                }
                // Without this the whole row takes the accent tint and the
                // board names stop reading as content.
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .navigationTitle("控制对象")
    }

    private func icon(for kind: WatchTargetChoice.Kind) -> String {
        switch kind {
        case .phone: return "iphone"
        case .board: return "rectangle.on.rectangle"
        case .group: return "square.grid.2x2"
        }
    }

    private func subtitle(for choice: WatchTargetChoice) -> String {
        switch choice.kind {
        case .phone:
            return NSLocalizedString("跟随 iPhone 当前选择", comment: "watch target: follow phone")
        case .board:
            // The row is the only place the watch says whether a board it is
            // not pointed at is even up.
            return choice.isConnected
                ? NSLocalizedString("已连接的板子", comment: "watch target: a connected board")
                : NSLocalizedString("未连接", comment: "watch: board not connected")
        case .group:
            return String(format: NSLocalizedString("多板组 · 在线 %lld / %lld", comment: "watch target: group members online"),
                          choice.connectedCount, choice.memberCount)
        }
    }
}
