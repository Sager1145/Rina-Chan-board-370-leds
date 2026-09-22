import SwiftUI

/// Which of the phone's boards the watch drives: follow the phone, any
/// connected board, or any board group. Choosing here changes only the
/// watch's target — the phone keeps its own selection and whatever it is
/// currently playing.
struct WatchTargetPickerView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(model.snapshot?.targets ?? []) { choice in
                let selected = choice.id == model.snapshot?.selectedTargetID
                Button {
                    model.selectTarget(choice.id)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: icon(for: choice.kind))
                            .foregroundStyle(choice.isConnected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) {
                            Text(choice.name)
                                .lineLimit(1)
                            Text(subtitle(for: choice))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
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
            return NSLocalizedString("已连接的板子", comment: "watch target: a connected board")
        case .group:
            return String(format: NSLocalizedString("多板组 · 在线 %lld / %lld", comment: "watch target: group members online"),
                          choice.connectedCount, choice.memberCount)
        }
    }
}
