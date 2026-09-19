import Foundation

/// Pure decision logic for `GroupScrollPreview`: what a cell should draw,
/// with no SwiftUI/`TimelineView` involved, so it can be unit tested. The
/// governing invariant (see the caller): a preview cell animates iff the app
/// has positive evidence that the physical board is running that exact
/// content right now — the coordinator is driving the group AND that member
/// is a live participant in it. Everything else is static.
enum GroupPreviewPolicy {
    enum Mode: Equatable {
        /// The coordinator is actively driving this group: animate, deriving
        /// the frame from the coordinator's clock.
        case playing
        /// The coordinator is driving this group but it's paused/stepped:
        /// every board sits on the coordinator's paused frame.
        case still
        /// Nothing uploaded to / synced from the boards (draft not sent, or a
        /// different group/tab owns them): no preview, every cell dark.
        case dark
    }

    /// - Parameters:
    ///   - snapshotGroupID: `BoardGroupCoordinator.playbackSnapshot?.groupID`.
    ///   - groupID: the group this preview instance is showing.
    ///   - isPaused: `BoardGroupCoordinator.isPaused`.
    static func mode(snapshotGroupID: UUID?, groupID: UUID, isPaused: Bool) -> Mode {
        guard snapshotGroupID == groupID else { return .dark }
        return isPaused ? .still : .playing
    }

    /// Whether one member cell has positive evidence that its physical board
    /// is showing the group's content right now — false draws a dark
    /// placeholder frame instead of a re-render of the bitmap.
    static func cellIsLive(
        _ status: BoardGroupCoordinator.MemberStatus,
        isLiveParticipant: Bool,
        groupPaused: Bool
    ) -> Bool {
        guard isLiveParticipant else { return false }
        if groupPaused {
            switch status {
            case .ready, .playing: return true
            default: return false
            }
        }
        return status == .playing
    }
}
