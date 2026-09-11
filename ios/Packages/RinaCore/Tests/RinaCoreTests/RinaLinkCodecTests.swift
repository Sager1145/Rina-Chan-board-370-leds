import XCTest
@testable import RinaCore

final class RinaLinkCodecTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let payload = "{\"ok\":true}".data(using: .utf8)!
        let frame = RinaLinkFrame(type: .getStatus, seq: 7, payload: payload)
        let data = RinaLinkEncoder.encode(frame)

        let decoder = RinaLinkDecoder()
        let frames = decoder.feed(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, RinaLinkMessageType.getStatus.rawValue)
        XCTAssertEqual(frames[0].seq, 7)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testSplitAcrossFeeds() {
        let payload = Data(repeating: 0xAB, count: 100)
        let frame = RinaLinkFrame(type: .getFrame, seq: 1, payload: payload)
        let data = RinaLinkEncoder.encode(frame)

        let decoder = RinaLinkDecoder()
        var frames: [RinaLinkFrame] = []
        // Feed one byte at a time.
        for byte in data {
            frames.append(contentsOf: decoder.feed(Data([byte])))
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testMultipleFramesInOneFeed() {
        let f1 = RinaLinkEncoder.encode(RinaLinkFrame(type: .ping, seq: 1, payload: Data()))
        let f2 = RinaLinkEncoder.encode(RinaLinkFrame(type: .ping, seq: 2, payload: Data()))
        var combined = f1
        combined.append(f2)

        let decoder = RinaLinkDecoder()
        let frames = decoder.feed(combined)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].seq, 1)
        XCTAssertEqual(frames[1].seq, 2)
    }

    func testResyncOnGarbagePrefix() {
        var garbage = Data([0x00, 0x11, 0x22, 0xFF])
        let real = RinaLinkEncoder.encode(RinaLinkFrame(type: .ping, seq: 3, payload: Data([1, 2, 3])))
        garbage.append(real)

        let decoder = RinaLinkDecoder()
        let frames = decoder.feed(garbage)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].seq, 3)
        XCTAssertEqual(frames[0].payload, Data([1, 2, 3]))
    }

    func testMoreFlagRoundTrip() {
        let frame = RinaLinkFrame(type: .getFaces, seq: 9, flags: RinaLinkFrameConstants.flagMore, payload: Data([1]))
        let data = RinaLinkEncoder.encode(frame)
        let decoded = RinaLinkDecoder().feed(data)
        XCTAssertEqual(decoded.first?.isMore, true)
    }

    func testErrorFrameDecodesToRinaLinkError() throws {
        let json = """
        {"ok":false,"error":"bad request","code":400}
        """.data(using: .utf8)!
        let frame = RinaLinkEncoder.encode(RinaLinkFrame(type: .error, seq: 1, payload: json))
        let decoded = RinaLinkDecoder().feed(frame)
        XCTAssertEqual(decoded.first?.isError, true)
        let err = try JSONDecoder().decode(RinaLinkError.self, from: decoded[0].payload)
        XCTAssertEqual(err.code, 400)
        XCTAssertEqual(err.error, "bad request")
    }
}
