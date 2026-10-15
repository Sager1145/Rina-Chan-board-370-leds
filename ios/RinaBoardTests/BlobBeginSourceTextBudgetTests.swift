import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// J3: a source text whose own UTF-8 fits in 4096 bytes can still make the
/// BLOB_BEGIN document exceed `RinaLinkFrameConstants.maxPayloadBytes`. All
/// three upload paths omit `sourceText` in that case and still upload.
@MainActor
final class BlobBeginSourceTextBudgetTests: XCTestCase {
    func testFourKilobyteSourceTextUploadsWithoutSourceTextKey() async throws {
        let text = "A" + String(repeating: "\u{200D}", count: 1365)
        XCTAssertEqual(text.utf8.count, 4096)
        try await upload(sourceText: text, expectText: false)
    }

    func testShortSourceTextRemainsInBegin() async throws {
        try await upload(sourceText: "Hi", expectText: true)
    }

    private func upload(sourceText: String, expectText: Bool) async throws {
        let timeline = try makeTimeline()
        let transport = BeginBudgetTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)

        _ = try await connection.startScrollUpload(
            frames: [PackedFrame()],
            fps: 10,
            timelineId: "raw",
            fontId: ScrollRasterizer.fontId,
            generatorVersion: ScrollRasterizer.generatorVersion,
            sourceText: sourceText
        )
        try assertBegin(transport.lastBlobBegin, kind: "scroll", sourceText: expectText ? sourceText : nil, path: "raw")

        transport.blobEndReply = [
            "ok": true,
            "frames": timeline.frameCount,
            "rotation": timeline.rotation,
        ]
        _ = try await connection.startScrollBitmapUpload(timeline: timeline, fps: 10, sourceText: sourceText)
        try assertBegin(transport.lastBlobBegin, kind: "scroll_bitmap", sourceText: expectText ? sourceText : nil, path: "bitmap")
        let bitmapBegin = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.lastBlobBegin) as? [String: Any])
        XCTAssertNil(bitmapBegin["viewportX"], "bitmap begin is not a group viewport upload")

        let bitmap = timeline.bitmap
        XCTAssertGreaterThanOrEqual(bitmap.width, 22)
        _ = try await connection.uploadGroupScrollBitmap(
            bitmap: bitmap,
            packedBytes: bitmap.packedBytes(),
            viewportX: 0,
            virtualWidth: 22,
            fps: 10,
            intervalMs: timeline.intervalMs,
            timelineId: timeline.timelineId,
            sourceText: sourceText,
            start: false
        )
        try assertBegin(transport.lastBlobBegin, kind: "scroll_bitmap", sourceText: expectText ? sourceText : nil, path: "group")
        let groupBegin = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.lastBlobBegin) as? [String: Any])
        XCTAssertNotNil(groupBegin["viewportX"])
        XCTAssertNotNil(groupBegin["virtualWidth"])
    }

    private func assertBegin(_ payload: Data, kind: String, sourceText: String?, path: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertLessThanOrEqual(payload.count, RinaLinkFrameConstants.maxPayloadBytes,
                                 "\(path) BEGIN is \(payload.count) bytes", file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any], file: file, line: line)
        XCTAssertEqual(object["kind"] as? String, kind as String?, path, file: file, line: line)
        if let sourceText {
            XCTAssertEqual(object["sourceText"] as? String, sourceText, path, file: file, line: line)
        } else {
            XCTAssertNil(object["sourceText"], "\(path) BEGIN must omit sourceText", file: file, line: line)
        }
    }

    private func makeTimeline() throws -> ScrollTimeline {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"),
                                "Hosted tests need the app's bundled font")
        let font = try ArkPixelFont.loadBundled(url: url)
        return try ScrollRasterizer.makeTimeline(text: "Hi", font: font, fps: 10)
    }
}

/// Records BLOB_BEGIN payloads and ACKs chunks the way `RecordingTextTransport`
/// and `GroupFakeTransport` do, with a caller-supplied BLOB_END body so a
/// bitmap upload can satisfy the timeline check.
@MainActor
private final class BeginBudgetTransport: @MainActor RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var blobEndReply: [String: Any] = ["ok": true]
    private(set) var blobBegins: [Data] = []
    var lastBlobBegin: Data { blobBegins[blobBegins.count - 1] }

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            let messageType = RinaLinkMessageType(rawValue: request.type)
            var reply = Data(#"{"ok":true}"#.utf8)
            if messageType == .blobBegin {
                blobBegins.append(request.payload)
                reply = Data(#"{"ok":true,"offset":0,"chunkMax":512}"#.utf8)
            } else if messageType == .blobChunk, request.payload.count >= 4 {
                let bytes = [UInt8](request.payload.prefix(4))
                let offset = bytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                reply = try JSONSerialization.data(withJSONObject: [
                    "ok": true, "offset": offset + request.payload.count - 4,
                ])
            } else if messageType == .blobEnd {
                reply = try JSONSerialization.data(withJSONObject: blobEndReply)
            }
            incomingContinuation?.yield(try RinaLinkEncoder.encode(
                RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: reply)
            ))
        }
    }
}
