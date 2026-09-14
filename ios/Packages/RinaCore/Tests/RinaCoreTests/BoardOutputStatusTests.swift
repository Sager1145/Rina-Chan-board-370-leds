import XCTest
@testable import RinaCore

final class BoardOutputStatusTests: XCTestCase {
    func testStreamMetadataDecodesFromBothBoardSnapshots() throws {
        let fields = #"{"mode":"manual","playback":"idle","outputMode":"video","outputStreamID":"126FC15E-8B54-43BF-A2EC-31F347BDF791","outputPositionMs":42123}"#
        let status = try JSONDecoder().decode(DeviceStatus.self,
            from: Data("{\"renderer\":\(fields)}".utf8))
        let preview = try JSONDecoder().decode(PreviewSync.self, from: Data(fields.utf8))
        XCTAssertEqual(status.renderer?.outputMode, "video")
        XCTAssertEqual(status.renderer?.outputStreamID, preview.outputStreamID)
        XCTAssertEqual(status.renderer?.outputPositionMs, 42123)
        XCTAssertEqual(preview.outputPositionMs, 42123)
        let roundTrip = try JSONDecoder().decode(DeviceStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(roundTrip.renderer?.outputStreamID, preview.outputStreamID)
        XCTAssertEqual(roundTrip.renderer?.outputPositionMs, 42123)
    }

    func testOlderFirmwareDoesNotRequireStreamMetadata() throws {
        let fields = Data(#"{"mode":"manual","playback":"idle","lastReason":"lipsync"}"#.utf8)
        let renderer = try JSONDecoder().decode(RendererStatus.self, from: fields)
        let preview = try JSONDecoder().decode(PreviewSync.self, from: fields)
        XCTAssertNil(renderer.outputMode)
        XCTAssertNil(renderer.outputStreamID)
        XCTAssertNil(preview.outputPositionMs)
    }
}
