import Foundation
import XCTest
@testable import RinaBoard

/// Pure decision-table tests for `GroupPreviewPolicy` — no SwiftUI, no
/// `BoardGroupCoordinator` instance required for `mode`; `cellIsLive` only
/// needs a `MemberStatus` value.
final class GroupPreviewPolicyTests: XCTestCase {
    private let groupID = UUID()
    private let otherGroupID = UUID()

    func testIdleIsDark() {
        XCTAssertEqual(GroupPreviewPolicy.mode(snapshotGroupID: nil, groupID: groupID, isPaused: false), .dark)
    }

    /// The coordinator is driving a DIFFERENT group (another tab's target,
    /// or a superseded play): this preview must never show it.
    func testSnapshotForAnotherGroupIsDark() {
        XCTAssertEqual(GroupPreviewPolicy.mode(snapshotGroupID: otherGroupID, groupID: groupID, isPaused: false), .dark)
        XCTAssertEqual(GroupPreviewPolicy.mode(snapshotGroupID: otherGroupID, groupID: groupID, isPaused: true), .dark)
    }

    func testMatchingSnapshotPlays() {
        XCTAssertEqual(GroupPreviewPolicy.mode(snapshotGroupID: groupID, groupID: groupID, isPaused: false), .playing)
    }

    func testMatchingSnapshotPausedIsStill() {
        XCTAssertEqual(GroupPreviewPolicy.mode(snapshotGroupID: groupID, groupID: groupID, isPaused: true), .still)
    }

    // MARK: - cellIsLive

    func testCellIsLiveWhenParticipantPlayingAndGroupNotPaused() {
        XCTAssertTrue(GroupPreviewPolicy.cellIsLive(.playing, isLiveParticipant: true, groupPaused: false))
    }

    func testCellNotLiveWhenGroupPlayingButMemberStillOnlyReady() {
        // `.ready` (joined but not yet confirmed playing) must not animate
        // while the group is actually running.
        XCTAssertFalse(GroupPreviewPolicy.cellIsLive(.ready, isLiveParticipant: true, groupPaused: false))
    }

    func testCellIsLiveWhenPausedAndParticipantReady() {
        XCTAssertTrue(GroupPreviewPolicy.cellIsLive(.ready, isLiveParticipant: true, groupPaused: true))
    }

    func testCellIsLiveWhenPausedAndParticipantPlaying() {
        XCTAssertTrue(GroupPreviewPolicy.cellIsLive(.playing, isLiveParticipant: true, groupPaused: true))
    }

    /// The defining regression: a board that has gone offline mid-play must
    /// never keep animating just because the coordinator hasn't pruned its
    /// stale `.playing` status entry yet (BoardGroupCoordinator.status(for:)
    /// documents this lazy-clear).
    func testOfflineMemberNeverLiveEvenIfStatusStillReadsPlaying() {
        XCTAssertFalse(GroupPreviewPolicy.cellIsLive(.playing, isLiveParticipant: false, groupPaused: false))
        XCTAssertFalse(GroupPreviewPolicy.cellIsLive(.offline, isLiveParticipant: false, groupPaused: false))
    }

    func testNonLiveParticipantNeverLiveRegardlessOfStatus() {
        for status: BoardGroupCoordinator.MemberStatus in [
            .offline, .connected, .unsupported, .uploading(progress: 0.5), .ready, .playing, .error("x")
        ] {
            XCTAssertFalse(GroupPreviewPolicy.cellIsLive(status, isLiveParticipant: false, groupPaused: false),
                           "\(status) must never be live without isLiveParticipant")
            XCTAssertFalse(GroupPreviewPolicy.cellIsLive(status, isLiveParticipant: false, groupPaused: true),
                           "\(status) must never be live without isLiveParticipant, even paused")
        }
    }

    func testUploadingOrErrorNeverLiveEvenAsParticipant() {
        XCTAssertFalse(GroupPreviewPolicy.cellIsLive(.uploading(progress: 0.9), isLiveParticipant: true, groupPaused: false))
        XCTAssertFalse(GroupPreviewPolicy.cellIsLive(.error("boom"), isLiveParticipant: true, groupPaused: false))
        XCTAssertFalse(GroupPreviewPolicy.cellIsLive(.connected, isLiveParticipant: true, groupPaused: false))
    }
}
