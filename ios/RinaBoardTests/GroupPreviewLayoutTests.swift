import XCTest
import SwiftUI
import UIKit
@testable import RinaBoard

@MainActor
final class GroupPreviewLayoutTests: XCTestCase {
    func testReorderStatusesDoNotChangePreviewRowHeight() {
        let statuses: [BoardGroupCoordinator.MemberStatus] = [
            .connected, .ready, .playing, .uploading(progress: 0), .uploading(progress: 1),
            .error(String(repeating: "Board connection interrupted while reordering. ", count: 5))
        ]
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for width: CGFloat in [70, 110, 220] {
                let heights = statuses.map { status in
                    UIHostingController(rootView: GroupPreviewMemberStatus(status: status)
                        .environment(\.dynamicTypeSize, typeSize))
                        .sizeThatFits(in: CGSize(width: width, height: 2000)).height
                }
                XCTAssertGreaterThan(heights[0], 0)
                for height in heights {
                    XCTAssertEqual(height, heights[0], accuracy: 0.5,
                                   "A longer upload/error status must not move a \(width)pt board preview at \(typeSize)")
                }
            }
        }
    }
}
