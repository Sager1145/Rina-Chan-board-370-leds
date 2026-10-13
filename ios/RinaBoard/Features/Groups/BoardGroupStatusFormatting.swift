import SwiftUI
import RinaCore

/// Shared Simplified Chinese labels for `BoardGroupCoordinator.MemberStatus`,
/// used by both the group editor and the play panel (BOARD_GROUP_SPEC.md §3).
enum BoardGroupStatusFormatting {
    static func text(_ status: BoardGroupCoordinator.MemberStatus) -> String {
        switch status {
        case .offline: return String(localized: "离线")
        case .connected: return String(localized: "已连接")
        case .unsupported: return String(localized: "不支持")
        case .uploading(let progress): return String(localized: "上传中 \(Int(progress * 100))%")
        case .ready: return String(localized: "就绪")
        case .playing: return String(localized: "播放中")
        case .error(let message): return String(localized: "错误：\(message)")
        }
    }

    static func color(_ status: BoardGroupCoordinator.MemberStatus) -> Color {
        switch status {
        case .offline, .connected, .ready: return .secondary
        case .unsupported, .error: return .red
        case .uploading: return .orange
        case .playing: return .rinaPink
        }
    }
}
