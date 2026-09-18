import XCTest
@testable import RinaCore

/// `groupTimed` is set by the firmware (`protocol.cpp`) on status, preview-sync
/// and scroll-meta payloads while a multi-board group-timed scroll owns this
/// board's `.text` output. The single-board restore path must be able to see it.
final class GroupTimedDecodingTests: XCTestCase {
    func testRendererStatusDecodesGroupTimedTrue() throws {
        let fields = Data(#"{"mode":"manual","playback":"scroll","groupTimed":true}"#.utf8)
        let status = try JSONDecoder().decode(DeviceStatus.self, from: Data("{\"renderer\":\(String(data: fields, encoding: .utf8)!)}".utf8))
        XCTAssertEqual(status.renderer?.groupTimed, true)
    }

    func testRendererStatusGroupTimedNilWhenAbsent() throws {
        let fields = Data(#"{"mode":"manual","playback":"idle"}"#.utf8)
        let renderer = try JSONDecoder().decode(RendererStatus.self, from: fields)
        XCTAssertNil(renderer.groupTimed)
    }

    func testPreviewSyncDecodesGroupTimedTrue() throws {
        let fields = Data(#"{"mode":"manual","playback":"scroll","groupTimed":true}"#.utf8)
        let preview = try JSONDecoder().decode(PreviewSync.self, from: fields)
        XCTAssertEqual(preview.groupTimed, true)
    }

    func testPreviewSyncGroupTimedNilWhenAbsent() throws {
        let fields = Data(#"{"mode":"manual","playback":"idle"}"#.utf8)
        let preview = try JSONDecoder().decode(PreviewSync.self, from: fields)
        XCTAssertNil(preview.groupTimed)
    }

    func testScrollMetaDecodesGroupTimedTrue() throws {
        let fields = Data(#"{"ok":true,"scrollTimelineId":"abc","firmwareScrollActive":true,"groupTimed":true}"#.utf8)
        let meta = try JSONDecoder().decode(ScrollMeta.self, from: fields)
        XCTAssertEqual(meta.groupTimed, true)
    }

    func testScrollMetaGroupTimedNilWhenAbsent() throws {
        let fields = Data(#"{"ok":true,"scrollTimelineId":"abc","firmwareScrollActive":true}"#.utf8)
        let meta = try JSONDecoder().decode(ScrollMeta.self, from: fields)
        XCTAssertNil(meta.groupTimed)
    }
}
