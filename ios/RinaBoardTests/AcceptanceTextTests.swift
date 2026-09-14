import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Offline preflight/state tests only. The frozen model schedules a weak-self
/// draft save on MainActor after 250ms and has no injectable draft store.
/// These tests never restore/persist drafts or start preview tasks. Each model
/// is explicitly released before returning/yielding from the tested synchronous
/// MainActor path. send() only takes guards that return before its first await.
/// Run in the dedicated acceptance simulator, not an installed user's app.
@MainActor
final class AcceptanceTextTests: XCTestCase {
    func testEditingMultilingualDraftPreservesEmojiAndLineBreaks() {
        var model: TextViewModel? = TextViewModel()
        weak var released = model
        let marker = UUID().uuidString
        let input = "a1-中文-日本語-👩🏽‍💻\n" + marker
        model?.editText(input)
        XCTAssertEqual(model?.text, input)
        XCTAssertEqual(model?.visibleCharCount, 49)
        XCTAssertEqual(model?.byteCount, 72)
        XCTAssertEqual(model?.userEditedText, true)
        XCTAssertEqual(model?.exceedsByteLimit, false)
        model = nil
        XCTAssertNil(released, "No model may survive to write a shared draft")
    }

    func testClearedEditorRestoresSampleTextOnBlur() {
        var model: TextViewModel? = TextViewModel()
        weak var released = model
        let sample = RinaResources.scrollTextDefaults(bundle: .main).defaultText
        model?.editText("abc")
        model?.restoreDefaultTextIfEmpty()
        XCTAssertEqual(model?.text, "abc")
        model?.editText(" \n")
        model?.restoreDefaultTextIfEmpty()
        XCTAssertEqual(model?.text, sample)
        XCTAssertEqual(model?.userEditedText, false)
        model = nil
        XCTAssertNil(released)
    }

    func testEditingEnforcesVisibleLimitWithoutSplittingEarlierContent() {
        var model: TextViewModel? = TextViewModel()
        weak var released = model
        let marker = UUID().uuidString
        model?.editText(marker + String(repeating: "文", count: 1001))
        XCTAssertEqual(model?.visibleCharCount, 1000)
        XCTAssertEqual(model?.text, marker + String(repeating: "文", count: 964))
        XCTAssertEqual(model?.userEditedText, true)
        model = nil
        XCTAssertNil(released)
    }

    func testEditingRetainsOverByteLimitDraftAndExposesExactBoundary() {
        var model: TextViewModel? = TextViewModel()
        weak var released = model
        // 273 composed emoji x 15 UTF-8 bytes + one ASCII = 4096 bytes,
        // only 547 visible codepoints, below the editor's visible limit.
        let boundary = String(repeating: "👩🏽‍💻", count: 273) + "a"
        model?.editText(boundary)
        XCTAssertEqual(model?.byteCount, 4096)
        XCTAssertEqual(model?.visibleCharCount, 547)
        XCTAssertEqual(model?.exceedsByteLimit, false)
        model?.editText(boundary + "b")
        XCTAssertEqual(model?.text, boundary + "b", "Byte overflow must stay editable rather than silently truncate")
        XCTAssertEqual(model?.byteCount, 4097)
        XCTAssertEqual(model?.exceedsByteLimit, true)
        model = nil
        XCTAssertNil(released)
    }

    func testInvalidSendDoesNotReplaceExistingBindingOrOutputOwner() async {
        let inputs = [" \n\t", String(repeating: "👩🏽‍💻", count: 274)]
        for input in inputs {
            let connection = BoardConnection()
            let owner = connection.output.begin(.manual)
            var model: TextViewModel? = TextViewModel()
            weak var released = model
            model?.editText(input)
            let oldBinding = "acceptance-old-\(UUID().uuidString)"
            model?.boundTimelineId = oldBinding
            model?.uploadSummary = "Previous successful upload"
            model?.localPhase = "ACTIVE"
            // Empty/over-limit validation returns before connection checks,
            // output claims, font loading, any task creation or suspension.
            await model?.send(connection: connection)
            XCTAssertEqual(model?.boundTimelineId, oldBinding)
            XCTAssertEqual(model?.uploadSummary, "Previous successful upload")
            XCTAssertEqual(model?.localPhase, "ACTIVE")
            XCTAssertEqual(model?.isUploading, false)
            XCTAssertNotNil(model?.errorMessage)
            XCTAssertTrue(connection.output.isCurrent(owner))
            XCTAssertEqual(connection.output.source, .manual)
            model = nil
            XCTAssertNil(released)
        }
    }

    func testDisconnectedSendKeepsDraftAndDoesNotLeaveRetryLocked() async {
        let connection = BoardConnection()
        var model: TextViewModel? = TextViewModel()
        weak var released = model
        let draft = "验收重试-\(UUID().uuidString)"
        model?.editText(draft)
        await model?.send(connection: connection)
        XCTAssertEqual(model?.text, draft)
        XCTAssertEqual(model?.userEditedText, true)
        XCTAssertEqual(model?.isUploading, false)
        XCTAssertEqual(model?.isGeneratingFont, false)
        XCTAssertNotNil(model?.errorMessage)
        XCTAssertNil(connection.output.session)
        model?.errorMessage = nil
        await model?.send(connection: connection)
        XCTAssertNotNil(model?.errorMessage, "A second attempt must run preflight rather than remain locked as uploading")
        XCTAssertEqual(model?.text, draft)
        XCTAssertEqual(model?.isUploading, false)
        model = nil
        XCTAssertNil(released)
    }

    func testConflictChoicesKeepDraftOrExplicitlyAdoptBoardText() {
        var model: TextViewModel? = TextViewModel()
        weak var released = model
        let draft = "本机-\(UUID().uuidString)"
        let board = "面板-\(UUID().uuidString)"
        model?.editText(draft)
        model?.boardText = board
        model?.restoreConflict = true
        model?.keepDraft()
        XCTAssertEqual(model?.text, draft)
        XCTAssertEqual(model?.userEditedText, true)
        XCTAssertEqual(model?.restoreConflict, false)
        XCTAssertNil(model?.boardText)

        model?.boardText = board
        model?.restoreConflict = true
        model?.useBoardText()
        XCTAssertEqual(model?.text, board)
        XCTAssertEqual(model?.userEditedText, false)
        XCTAssertEqual(model?.restoreConflict, false)
        XCTAssertNil(model?.boardText)
        model = nil
        XCTAssertNil(released)
    }

    func testReleaseOutputClearsPlaybackBindingAndPhaseButKeepsUnsentDraft() {
        var model: TextViewModel? = TextViewModel()
        weak var released = model
        let draft = "保留草稿-\(UUID().uuidString)"
        model?.editText(draft)
        model?.boundTimelineId = "acceptance-timeline"
        model?.localPhase = "UPLOADING"
        model?.releaseOutput()
        XCTAssertNil(model?.boundTimelineId)
        XCTAssertNil(model?.localPhase)
        XCTAssertEqual(model?.text, draft)
        XCTAssertEqual(model?.userEditedText, true)
        XCTAssertEqual(model?.isUploading, false)
        model = nil
        XCTAssertNil(released)
    }
}
