import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// User-visible Control editor behavior against the frozen acceptance product.
///
/// These tests deliberately avoid `DraftStorage.shared`. Editing schedules a
/// weakly captured, delayed save in production; every synchronous test keeps
/// the model local and finishes without awaiting that delay. The one async
/// test sends the editor's unchanged initial frame, so it schedules no draft
/// write at all.
@MainActor
final class AcceptanceControlTests: XCTestCase {
    func testPaintWritesExplicitBrushValueAndRepeatedStrokeIsNoOp() {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let led = 17

        model.clear(connection: connection)
        model.brushOn = true
        XCTAssertTrue(model.paint(led: led, connection: connection))
        XCTAssertTrue(model.draftFrame[led])
        XCTAssertFalse(model.fromParts)
        XCTAssertFalse(model.paint(led: led, connection: connection),
                       "Crossing an already-lit LED must not toggle it or report another edit")
        XCTAssertTrue(model.draftFrame[led])

        model.brushOn = false
        XCTAssertTrue(model.paint(led: led, connection: connection))
        XCTAssertFalse(model.draftFrame[led])
        XCTAssertFalse(model.paint(led: led, connection: connection),
                       "Crossing an already-cleared LED must remain a no-op")
    }

    func testSyncedEyePaintMirrorsTheBrushValueInBothDirections() throws {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let topology = try XCTUnwrap(model.eyeTopology, "The shipped parts must provide a verified eye topology")
        let pair = try XCTUnwrap(topology.leftToRightPairs.first)

        model.clear(connection: connection)
        model.brushOn = true
        XCTAssertTrue(model.paint(led: pair.left, connection: connection))
        XCTAssertTrue(model.draftFrame[pair.left])
        XCTAssertFalse(model.draftFrame[pair.right], "Eye sync is still off")

        model.setSyncEyes(true, connection: connection)
        XCTAssertTrue(model.draftFrame[pair.left])
        XCTAssertTrue(model.draftFrame[pair.right], "Enabling sync must project the left eye immediately")

        model.brushOn = false
        XCTAssertTrue(model.paint(led: pair.right, connection: connection))
        XCTAssertFalse(model.draftFrame[pair.left])
        XCTAssertFalse(model.draftFrame[pair.right])
        XCTAssertFalse(model.paint(led: pair.right, connection: connection),
                       "A repeated mirrored erase must not report another edit")
    }

    func testEyePartSelectionStaysMirroredWhileSyncIsEnabled() throws {
        let (model, library) = try loadedModel()
        let connection = BoardConnection()
        model.setSyncEyes(true, connection: connection)

        let leftID = try differentPartID(in: .leye, from: model.selectedCall[.leye], library: library)
        let expectedRight = try XCTUnwrap(library.mirroredEyeId(leftID))
        model.selectPart(group: .leye, id: leftID, connection: connection)

        XCTAssertEqual(model.selectedCall[.leye], leftID)
        XCTAssertEqual(model.selectedCall[.reye], expectedRight)
        XCTAssertTrue(model.fromParts)
        XCTAssertEqual(model.draftFrame, library.compose(call: model.selectedCall))

        let rightID = try differentPartID(in: .reye, from: model.selectedCall[.reye], library: library)
        let expectedLeft = try XCTUnwrap(library.mirroredEyeId(rightID))
        model.selectPart(group: .reye, id: rightID, connection: connection)

        XCTAssertEqual(model.selectedCall[.reye], rightID)
        XCTAssertEqual(model.selectedCall[.leye], expectedLeft)
        XCTAssertEqual(model.draftFrame, library.compose(call: model.selectedCall))
    }

    func testSelectingEveryPartGroupRecomposesTheDisplayedFrame() throws {
        let (model, library) = try loadedModel()
        let connection = BoardConnection()

        for group in PartGroup.allCases {
            let selected = try differentPartID(in: group, from: model.selectedCall[group], library: library)
            model.selectPart(group: group, id: selected, connection: connection)

            XCTAssertEqual(model.selectedCall[group], selected, "The chosen \(group) part must remain selected")
            XCTAssertTrue(model.fromParts)
            XCTAssertEqual(model.draftFrame, library.compose(call: model.selectedCall),
                           "The board preview must be the composition of all four current selections")
            let expectedIndex = try XCTUnwrap(library.displayIndex(of: selected, in: group))
            XCTAssertEqual(model.selectedIndex(in: group), expectedIndex)
        }
    }

    func testUndoStepsBackThroughStrokesTapsInvertAndClear() throws {
        let (model, _) = try loadedModel()
        let connection = BoardConnection()
        let partsFrame = model.draftFrame
        let partsCall = model.selectedCall
        XCTAssertFalse(model.canUndo)

        let unlit = (0..<PackedFrame.ledCount).filter { !partsFrame[$0] }
        XCTAssertGreaterThanOrEqual(unlit.count, 3)
        model.brushOn = true
        XCTAssertTrue(model.paint(led: unlit[0], connection: connection))
        XCTAssertTrue(model.paint(led: unlit[1], connection: connection))
        model.endStroke()
        let afterStroke = model.draftFrame
        XCTAssertTrue(model.canUndo)

        model.toggle(led: unlit[2], connection: connection)
        let afterTap = model.draftFrame

        model.invert(connection: connection)
        XCTAssertTrue(model.draftFrame.validate(), "Invert must keep the unused tail bits clear")
        let afterInvert = model.draftFrame

        model.clear(connection: connection)
        XCTAssertEqual(model.draftFrame.litCount, 0)
        XCTAssertFalse(model.fromParts)

        model.undo(connection: connection)
        XCTAssertEqual(model.draftFrame, afterInvert, "Undoing a clear brings the erased drawing back")
        model.undo(connection: connection)
        XCTAssertEqual(model.draftFrame, afterTap)
        model.undo(connection: connection)
        XCTAssertEqual(model.draftFrame, afterStroke)
        model.undo(connection: connection)
        XCTAssertEqual(model.draftFrame, partsFrame, "A whole drag stroke is one undo step")
        XCTAssertEqual(model.selectedCall, partsCall)
        XCTAssertTrue(model.fromParts)
        XCTAssertFalse(model.canUndo)
    }

    func testUndoingAPartChoiceReturnsToThePreviousChoiceWithoutItsDrawing() throws {
        let (model, library) = try loadedModel()
        let connection = BoardConnection()
        let firstCall = model.selectedCall
        let firstFrame = model.draftFrame

        let mouth = try differentPartID(in: .mouth, from: firstCall.mouth, library: library)
        model.selectPart(group: .mouth, id: mouth, connection: connection)
        let secondCall = model.selectedCall
        let secondFrame = model.draftFrame

        model.toggle(led: 0, connection: connection)
        model.toggle(led: 1, connection: connection)
        let eye = try differentPartID(in: .leye, from: secondCall[.leye], library: library)
        model.selectPart(group: .leye, id: eye, connection: connection)

        model.undo(connection: connection)
        XCTAssertEqual(model.selectedCall, secondCall)
        XCTAssertEqual(model.draftFrame, secondFrame)
        XCTAssertTrue(model.fromParts)

        model.undo(connection: connection)
        XCTAssertEqual(model.selectedCall, firstCall)
        XCTAssertEqual(model.draftFrame, firstFrame)
        XCTAssertFalse(model.canUndo)

        model.selectPart(group: .mouth, id: firstCall.mouth, connection: connection)
        XCTAssertFalse(model.canUndo, "Re-choosing the current part changes nothing and records nothing")
    }

    func testLoadingSavedPartsFaceStartsAFreshUndoHistoryAndNewFaceClearsIdentity() throws {
        let (model, library) = try loadedModel()
        let connection = BoardConnection()
        let mouth = try differentPartID(in: .mouth, from: PartsCall.defaultCall.mouth, library: library)
        let call = PartsCall(leye: PartsCall.defaultCall.leye,
                             reye: PartsCall.defaultCall.reye,
                             mouth: mouth,
                             cheek: PartsCall.defaultCall.cheek)
        let frame = library.compose(call: call)
        let uniqueName = "AcceptanceControl-\(UUID().uuidString)"
        let face = SavedFace(id: "acceptance-control-loaded-face",
                             name: uniqueName,
                             type: .parts,
                             frameBytes: frame.bytes.map(Int.init),
                             order: 1,
                             call: .init(leye: call.leye,
                                         reye: call.reye,
                                         mouth: call.mouth,
                                         cheek: call.cheek))

        model.loadForEditing(face)
        XCTAssertEqual(model.editingFaceId, face.id)
        XCTAssertEqual(model.saveName, uniqueName)
        XCTAssertEqual(model.selectedCall, call)
        XCTAssertEqual(model.draftFrame, frame)
        XCTAssertTrue(model.fromParts)
        XCTAssertFalse(model.canUndo)

        model.clear(connection: connection)
        XCTAssertTrue(model.canUndo)
        model.undo(connection: connection)
        XCTAssertEqual(model.draftFrame, frame)
        XCTAssertEqual(model.selectedCall, call)
        XCTAssertFalse(model.canUndo)

        model.startNewFace()
        XCTAssertNil(model.editingFaceId)
        XCTAssertEqual(model.saveName, "parts_face")
        XCTAssertEqual(model.draftFrame, frame,
                       "Starting a new save identity must not discard the face currently being edited")
    }

    func testUntouchedEditorAdoptsBoardFrameButEditedDraftRejectsLaterBoardFrame() {
        let model = ControlViewModel()
        let connection = BoardConnection()
        var firstBoardFrame = PackedFrame()
        firstBoardFrame.set(369)

        model.adoptBoardFrameIfUntouched(firstBoardFrame)
        XCTAssertEqual(model.draftFrame, firstBoardFrame)
        XCTAssertFalse(model.hasUnsentChanges)
        XCTAssertFalse(model.fromParts)

        model.brushOn = true
        XCTAssertTrue(model.paint(led: 10, connection: connection))
        let editedFrame = model.draftFrame
        XCTAssertTrue(model.hasUnsentChanges)

        var laterBoardFrame = PackedFrame()
        laterBoardFrame.set(42)
        model.adoptBoardFrameIfUntouched(laterBoardFrame)
        XCTAssertEqual(model.draftFrame, editedFrame,
                       "A reconnect must not overwrite a draft after the user has edited it")
    }

    func testSentStateIsBoundToTheConnectionGeneration() async {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let firstTransport = AcceptanceControlTransport()
        let firstConnected = await connection.connect(using: firstTransport)
        XCTAssertTrue(firstConnected)
        let firstGeneration = connection.connectionGeneration

        await model.send(connection: connection)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.wasSent(in: connection))
        XCTAssertFalse(model.hasUnsentChanges)

        let secondTransport = AcceptanceControlTransport()
        let secondConnected = await connection.connect(using: secondTransport)
        XCTAssertTrue(secondConnected)
        XCTAssertNotEqual(connection.connectionGeneration, firstGeneration)
        XCTAssertFalse(model.wasSent(in: connection),
                       "A successful send on one board generation must not appear sent on the next")
        XCTAssertFalse(model.hasUnsentChanges,
                       "Changing connection identity must not mutate the local draft")
        connection.disconnect()
    }

    func testBoardFrameSelectsMatchingPartsAndClearsSelectionForCustomPixels() throws {
        let (model, library) = try loadedModel()
        var call = PartsCall.defaultCall
        call.mouth = try differentPartID(in: .mouth, from: call.mouth, library: library)
        let frame = library.compose(call: call)
        model.adoptBoardFrameIfUntouched(frame)
        XCTAssertEqual(model.draftFrame, frame)
        XCTAssertTrue(model.fromParts)
        XCTAssertEqual(library.compose(call: model.selectedCall), frame)
        XCTAssertEqual(model.selectedCall.mouth, call.mouth)
        XCTAssertFalse(model.hasUnsentChanges)

        var custom = frame
        custom.toggle(369)
        model.adoptBoardFrameIfUntouched(custom)
        XCTAssertEqual(model.draftFrame, custom)
        XCTAssertFalse(model.fromParts)
        XCTAssertFalse(model.canUndo)
    }

    func testRefreshPreservesDraftAfterSendingAnEdit() async throws {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let transport = AcceptanceControlTransport()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        model.livePreview = false
        model.toggle(led: 10, connection: connection)
        await model.send(connection: connection)
        XCTAssertFalse(model.hasUnsentChanges)

        var external = PackedFrame()
        external.set(369)
        transport.displayFrame = external
        await model.refreshBoardDisplay(connection: connection)
        XCTAssertNotEqual(model.draftFrame, external)
        XCTAssertTrue(model.draftFrame[10],
                      "A synced draft must survive unrelated board output after reconnect")
        XCTAssertFalse(model.hasUnsentChanges)

        model.toggle(led: 12, connection: connection)
        let draft = model.draftFrame
        transport.displayFrame = PackedFrame()
        await model.refreshBoardDisplay(connection: connection)
        XCTAssertEqual(model.draftFrame, draft, "An unsent local edit must survive preview reads")
        connection.disconnect()
    }

    func testBoardPreviewBeforeRestoreCannotOverwriteStoredDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-DraftRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = DraftStorage(directory: directory)
        let offline = BoardConnection()
        let writer = ControlViewModel(draftStorage: storage)
        writer.toggle(led: 17, connection: offline)
        writer.toggle(led: 93, connection: offline)
        let storedDraft = writer.draftFrame
        await writer.persistDraft()

        let restoring = ControlViewModel(draftStorage: storage)
        var boardPreview = PackedFrame()
        boardPreview.set(369)
        restoring.adoptBoardFrameIfUntouched(boardPreview)
        try await Task.sleep(for: .milliseconds(350))

        let storedData = try await storage.read("face")
        let dataBeforeRestore = try XCTUnwrap(storedData)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: dataBeforeRestore) as? [String: Any]
        )
        let storedHex = try XCTUnwrap(object["frame"] as? String)
        XCTAssertEqual(PackedFrame(hex94: storedHex), storedDraft,
                       "A launch-time board preview must not win the draft-save debounce race")

        await restoring.restoreDraft()
        XCTAssertEqual(restoring.draftFrame, storedDraft)
        XCTAssertNotEqual(restoring.draftFrame, boardPreview)
    }

    private func loadedModel(file: StaticString = #filePath,
                             line: UInt = #line) throws -> (ControlViewModel, PartsLibrary) {
        let model = ControlViewModel()
        let library = try XCTUnwrap(model.library,
                                    model.loadError ?? "The shipped parts library was unavailable",
                                    file: file,
                                    line: line)
        return (model, library)
    }

    private func differentPartID(in group: PartGroup,
                                 from current: String,
                                 library: PartsLibrary,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> String {
        let ids = library.ids(for: group)
        let visiblyDifferent = ids.first { id in
            id != current && id != "0" && !(group == .cheek && id == "400")
        }
        return try XCTUnwrap(visiblyDifferent ?? ids.first { $0 != current },
                      "The shipped \(group) group needs another selectable part",
                      file: file,
                      line: line)
    }
}

/// Minimal auto-reply carrier for the one send-state test. It exercises the
/// real `BoardConnection` session and generation behavior without Bluetooth,
/// sockets, clocks, or hardware.
@MainActor
private final class AcceptanceControlTransport: @MainActor RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512

    var displayFrame = PackedFrame()
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
            incomingContinuation?.yield(try! RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80,
                              seq: request.seq,
                              flags: 0,
                              payload: request.type == RinaLinkMessageType.getFrame.rawValue
                                ? Data(displayFrame.bytes) : Data(#"{"ok":true}"#.utf8))
            ))
        }
    }
}
