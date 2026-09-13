import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class BoardControlCenterModelTests: XCTestCase {
    func testConnectionChangedLetsReplacementBoardStatusReplaceOptimisticDrafts() async {
        let model = BoardControlCenterModel()
        let connection = BoardConnection()

        model.setBrightness(180, connection: connection)
        model.setAutoInterval(14, connection: connection)
        await model.setColor(hex: "#abcdef", connection: connection)
        model.modeOverride = "auto"
        model.faceIndexOverride = 7

        model.connectionChanged()
        let replacement = DeviceStatus(renderer: RendererStatus(
            color: "#123456",
            brightness: 25,
            mode: "manual",
            autoIntervalMs: 3_000,
            autoFaceIndex: 2
        ))
        model.sync(from: replacement)

        XCTAssertEqual(model.brightnessDraft, 25)
        XCTAssertEqual(model.autoIntervalDraft, 3)
        XCTAssertEqual(model.colorHexDraft, "#123456")
        XCTAssertEqual(model.hexFieldText, "#123456")
        XCTAssertEqual(model.effectiveMode(status: replacement), "manual")
        XCTAssertEqual(model.effectiveFaceIndex(status: replacement), 2)
        XCTAssertNil(model.errorMessage)
    }
}
