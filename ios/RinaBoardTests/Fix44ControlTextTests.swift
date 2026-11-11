import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Regression tests for the Control editor draft, the Control Center hex
/// field and the Text tab's upload/scrub state.
@MainActor
final class Fix44ControlTextTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fix44ControlTextTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Control draft: a mirrored board frame is not a user draft

    private func makeEditor() async -> ControlViewModel {
        let model = ControlViewModel(draftStorage: DraftStorage(directory: directory))
        await model.restoreDraft()
        return model
    }

    func testMirroredBoardFrameComesBackUntouchedAfterRelaunch() async {
        let model = await makeEditor()
        model.boardDidChange(to: "ble:A")
        var mirrored = PackedFrame()
        mirrored.set(369)
        model.adoptBoardFrameIfUntouched(mirrored)
        await model.persistDraft()

        let relaunched = await makeEditor()
        XCTAssertEqual(relaunched.draftFrame, mirrored)
        XCTAssertFalse(relaunched.hasUnsentChanges,
                       "a frame merely mirrored from the board must not come back as an unsent draft")

        relaunched.boardDidChange(to: "ble:A")
        var later = PackedFrame()
        later.set(42)
        relaunched.adoptBoardFrameIfUntouched(later)
        XCTAssertEqual(relaunched.draftFrame, later,
                       "the editor must keep mirroring the same board after a relaunch")
    }

    func testEditedDraftStaysUserOwnedAfterRelaunch() async {
        let model = await makeEditor()
        model.boardDidChange(to: "ble:A")
        model.toggle(led: 17, connection: BoardConnection())
        let drawn = model.draftFrame
        await model.persistDraft()

        let relaunched = await makeEditor()
        XCTAssertEqual(relaunched.draftFrame, drawn)
        XCTAssertTrue(relaunched.hasUnsentChanges)

        var board = PackedFrame()
        board.set(42)
        relaunched.adoptBoardFrameIfUntouched(board)
        XCTAssertEqual(relaunched.draftFrame, drawn)
    }

    /// Drafts written before the `userEdited` field existed still decode and
    /// keep their old meaning: user-owned, with unsent changes.
    func testDraftWithoutUserEditedFieldRestoresAsEdited() async throws {
        let storage = DraftStorage(directory: directory)
        let model = await makeEditor()
        var mirrored = PackedFrame()
        mirrored.set(369)
        model.adoptBoardFrameIfUntouched(mirrored)
        await model.persistDraft()

        let stored = try await storage.read("face")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(stored)) as? [String: Any]
        )
        XCTAssertEqual(object["userEdited"] as? Bool, false)
        object.removeValue(forKey: "userEdited")
        try await storage.write(try JSONSerialization.data(withJSONObject: object), name: "face")

        let relaunched = await makeEditor()
        XCTAssertEqual(relaunched.draftFrame, mirrored)
        XCTAssertTrue(relaunched.hasUnsentChanges)
        var board = PackedFrame()
        board.set(42)
        relaunched.adoptBoardFrameIfUntouched(board)
        XCTAssertEqual(relaunched.draftFrame, mirrored)
    }

    // MARK: Control Center: status must not replace a hex value being typed

    func testStatusDoesNotReplaceHexFieldWhileItIsBeingEdited() {
        let model = BoardControlCenterModel()
        let status = DeviceStatus(renderer: RendererStatus(color: "#123456"))

        model.hexFieldEditingChanged(true)
        model.hexFieldChanged("#12a")
        model.sync(from: status)

        XCTAssertEqual(model.hexFieldText, "#12a", "typed characters must survive a status push")
        XCTAssertFalse(model.hexFieldIsValid)
        XCTAssertEqual(model.colorHexDraft, "#123456", "the board colour itself is still adopted")

        model.hexFieldEditingChanged(false)
        model.sync(from: status)
        XCTAssertEqual(model.hexFieldText, "#123456")
        XCTAssertTrue(model.hexFieldIsValid)
    }

    // MARK: Text: a failed upload leaves the bound state alone

    func testFailedUploadLeavesNothingBoundAndNoTimeline() async throws {
        let (connection, transport) = try await connectedBoard()
        transport.rejectBlobBegin = true
        let model = TextViewModel()
        model.text = "Never uploaded"

        await model.send(connection: connection)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isUploading)
        XCTAssertNil(model.boundTimelineId)
        XCTAssertEqual(model.frameCount, 0,
                       "a timeline the board never accepted must not reach the preview or block the restore retry")
        XCTAssertEqual(model.previewFrame, PackedFrame())
    }

    func testFailedUploadKeepsThePreviouslyBoundTimeline() async throws {
        let (connection, transport) = try await connectedBoard()
        transport.rejectBlobBegin = true
        let model = TextViewModel()
        let bound = try makeTimeline()
        model.timeline = bound
        model.boundTimelineId = bound.timelineId
        model.text = "A different, never uploaded text"

        await model.send(connection: connection)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.boundTimelineId, bound.timelineId)
        XCTAssertEqual(model.timeline?.timelineId, bound.timelineId,
                       "the preview must keep describing the scroll the board is still running")
        XCTAssertEqual(model.frameCount, bound.frameCount)
    }

    // MARK: Text: a slider change without an editing phase

    func testUnbracketedScrubSeeksAndClearsTheScrub() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId

        model.updateScrub(toFrame: 2)
        XCTAssertEqual(model.scrubIndex, 2)
        await model.commitUnbracketedScrub(connection: connection)

        XCTAssertEqual(transport.scrollCommands.map(\.name), ["scroll_seek"])
        XCTAssertEqual(transport.scrollCommands.first?.fields["frameIndex"] as? Int, 2)
        XCTAssertNil(model.scrubIndex, "the preview must follow the board again")
    }

    func testUnbracketedScrubThatCannotBeSentIsDropped() async throws {
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId

        model.updateScrub(toFrame: 2)
        await model.commitUnbracketedScrub(connection: BoardConnection())

        XCTAssertNil(model.scrubIndex)
    }

    func testUnbracketedCommitLeavesARealDragAlone() async throws {
        let (connection, transport) = try await connectedBoard()
        let model = TextViewModel()
        let timeline = try makeTimeline()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId

        model.updateScrub(toFrame: 1)
        model.beginScrub()
        model.updateScrub(toFrame: 3)
        await model.commitUnbracketedScrub(connection: connection)

        XCTAssertTrue(transport.scrollCommands.isEmpty)
        XCTAssertEqual(model.scrubIndex, 3)
        XCTAssertTrue(model.isScrubbing)
    }

    // MARK: Helpers

    private func connectedBoard() async throws -> (BoardConnection, Fix44TextTransport) {
        let transport = Fix44TextTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        return (connection, transport)
    }

    private func makeTimeline(text: String = "Rina", fps: Int = 10) throws -> ScrollTimeline {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"),
                                "Hosted tests need the app's bundled font")
        let font = try ArkPixelFont.loadBundled(url: url)
        let timeline = try ScrollRasterizer.makeTimeline(text: text, font: font, fps: fps)
        XCTAssertGreaterThan(timeline.frameCount, 3)
        return timeline
    }
}

/// Replies `ok` to everything, records scroll `CMD`s, and can refuse every
/// BLOB_BEGIN the way the firmware does while another upload is in progress.
@MainActor
private final class Fix44TextTransport: @MainActor RinaTransport {
    struct Command {
        let name: String
        let fields: [String: Any]
    }

    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var rejectBlobBegin = false
    private(set) var scrollCommands: [Command] = []

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> {
        AsyncStream { stateContinuation = $0 }
    }

    func incomingStream() -> AsyncStream<Data> {
        AsyncStream { incomingContinuation = $0 }
    }

    func connect() async throws {
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            let messageType = RinaLinkMessageType(rawValue: request.type)
            var reply = Data(#"{"ok":true}"#.utf8)
            var replyType = request.type | 0x80
            if messageType == .cmd,
               let fields = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
               let name = fields["cmd"] as? String {
                if name.contains("scroll") {
                    scrollCommands.append(Command(name: name, fields: fields))
                }
            } else if messageType == .blobBegin, rejectBlobBegin {
                reply = try JSONEncoder().encode(
                    RinaLinkError(ok: false, error: "scroll upload already in progress", code: 409))
                replyType = RinaLinkMessageType.error.rawValue
            } else if messageType == .blobChunk, request.payload.count >= 4 {
                let offset = request.payload.prefix(4).enumerated().reduce(UInt32(0)) {
                    $0 | (UInt32($1.element) << ($1.offset * 8))
                }
                reply = try JSONSerialization.data(withJSONObject: [
                    "ok": true, "offset": Int(offset) + request.payload.count - 4,
                ])
            }
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: replyType, seq: request.seq, flags: 0, payload: reply)
            ))
        }
    }
}
