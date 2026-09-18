import SwiftUI
import RinaCore

/// Shared Simplified Chinese labels for `BoardGroupCoordinator.MemberStatus`,
/// used by both the group editor and the play panel (BOARD_GROUP_SPEC.md §3).
enum BoardGroupStatusFormatting {
    static func text(_ status: BoardGroupCoordinator.MemberStatus) -> String {
        switch status {
        case .offline: return "离线"
        case .connected: return "已连接"
        case .unsupported: return "不支持"
        case .uploading(let progress): return "上传中 \(Int(progress * 100))%"
        case .ready: return "就绪"
        case .playing: return "播放中"
        case .error(let message): return "错误：\(message)"
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
