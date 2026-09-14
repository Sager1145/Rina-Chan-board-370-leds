import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// MB-05 (docs/STRESS_TEST_UI_PLAN_ZH.md): an unsaved editor drawing is
/// discarded when another board becomes current, and never comes back.
@MainActor
final class ControlDraftBoardSwitchTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlDraftBoardSwitchTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() async -> ControlViewModel {
        let model = ControlViewModel(draftStorage: DraftStorage(directory: directory))
        await model.restoreDraft()
        return model
    }

    private func drawSomething(on model: ControlViewModel) {
        let connection = BoardConnection()
        model.toggle(led: 0, connection: connection)
        model.invert(connection: connection)
        model.saveName = "unsaved"
    }

    func testFirstBoardClaimsAnEarlierDraftAndReconnectingKeepsIt() async {
        let model = await makeModel()
        drawSomething(on: model)
        let drawn = model.draftFrame

        model.boardDidChange(to: "ble:A")
        model.boardDidChange(to: "ble:A")

        XCTAssertEqual(model.draftBoardID, "ble:A")
        XCTAssertEqual(model.draftFrame, drawn)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.saveName, "unsaved")
    }

    func testSwitchingBoardsDiscardsTheDraftUndoAndSaveTarget() async throws {
        let model = await makeModel()
        model.boardDidChange(to: "ble:A")
        drawSomething(on: model)
        model.editingFaceId = "face_on_A"

        model.boardDidChange(to: "ble:B")

        let library = try XCTUnwrap(model.library)
        XCTAssertEqual(model.draftBoardID, "ble:B")
        XCTAssertEqual(model.draftFrame, library.compose(call: .defaultCall))
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.hasUnsentChanges)
        XCTAssertNil(model.editingFaceId)
        XCTAssertEqual(model.saveName, "parts_face")

        // Untouched again, so the new board's display populates the editor.
        var boardFrame = PackedFrame()
        boardFrame[5] = true
        model.adoptBoardFrameIfUntouched(boardFrame)
        XCTAssertEqual(model.draftFrame, boardFrame)

        // Switching back does not bring the old drawing back.
        model.boardDidChange(to: "ble:A")
        XCTAssertEqual(model.draftFrame, library.compose(call: .defaultCall))
        XCTAssertFalse(model.canUndo)
    }

    func testBoardKeyUsesTheBoardsOwnIdOverEveryTransport() {
        let viaWifiStatus = BoardConnection.normalizedBoardIdentity(wifiBoardID: "80b54ef48e09", defaultName: nil)
        let viaInfo = BoardConnection.normalizedBoardIdentity(wifiBoardID: nil, defaultName: "RinaBoard-80B54EF48E09")
        XCTAssertEqual(viaWifiStatus, "80B54EF48E09")
        XCTAssertEqual(viaInfo, "80B54EF48E09")
        XCTAssertNil(BoardConnection.normalizedBoardIdentity(wifiBoardID: " ", defaultName: "RinaBoard-"))

        let peripheral = UUID()
        XCTAssertEqual(BoardConnection.boardKey(identity: viaInfo, transportKind: .bluetooth, peripheralID: peripheral),
                       BoardConnection.boardKey(identity: viaWifiStatus, transportKind: .wifi(host: "10.0.0.5", port: 5370),
                                                peripheralID: nil))
        XCTAssertEqual(BoardConnection.boardKey(identity: nil, transportKind: .bluetooth, peripheralID: peripheral),
                       "ble:\(peripheral.uuidString)")
        XCTAssertNil(BoardConnection.boardKey(identity: nil, transportKind: .hotspot, peripheralID: nil))
    }

    func testDiscardedDraftIsNotRestoredAfterRelaunch() async throws {
        let model = await makeModel()
        model.boardDidChange(to: "ble:A")
        drawSomething(on: model)
        await model.persistDraft()

        model.boardDidChange(to: "ble:B")
        // Let the removal task and any cancelled debounced save settle.
        try await Task.sleep(for: .milliseconds(400))

        let relaunched = await makeModel()
        XCTAssertNil(relaunched.draftBoardID)
        XCTAssertEqual(relaunched.saveName, "parts_face")
        XCTAssertFalse(relaunched.hasUnsentChanges)
    }

    func testRestoredDraftRemembersItsBoardAndIsDiscardedOnAnotherBoard() async throws {
        let model = await makeModel()
        model.boardDidChange(to: "wifi:10.0.0.5")
        drawSomething(on: model)
        await model.persistDraft()

        let relaunched = await makeModel()
        XCTAssertEqual(relaunched.draftBoardID, "wifi:10.0.0.5")
        XCTAssertEqual(relaunched.saveName, "unsaved")

        relaunched.boardDidChange(to: "ble:B")
        XCTAssertEqual(relaunched.saveName, "parts_face")
        XCTAssertEqual(relaunched.draftBoardID, "ble:B")
    }
}
