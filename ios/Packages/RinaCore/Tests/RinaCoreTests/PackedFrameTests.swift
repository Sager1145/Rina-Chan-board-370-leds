import XCTest
@testable import RinaCore

final class PackedFrameTests: XCTestCase {
    func testEmptyFrameValid() {
        let frame = PackedFrame()
        XCTAssertTrue(frame.validate())
        XCTAssertEqual(frame.litCount, 0)
    }

    func testSetClearToggle() {
        var frame = PackedFrame()
        frame.set(0)
        XCTAssertTrue(frame[0])
        frame.toggle(0)
        XCTAssertFalse(frame[0])
        frame.set(369)
        XCTAssertTrue(frame[369])
        frame.clear(369)
        XCTAssertFalse(frame[369])
    }

    func testInvalidTailBitsRejected() {
        var bytes = [UInt8](repeating: 0, count: 47)
        bytes[46] = 0b1000_0000
        XCTAssertNil(PackedFrame(bytes: bytes))
    }

    func testWrongLengthRejected() {
        XCTAssertNil(PackedFrame(bytes: [UInt8](repeating: 0, count: 40)))
    }

    func testHex94RoundTrip() {
        var frame = PackedFrame()
        frame.set(5)
        frame.set(369)
        let hex = frame.hex94
        XCTAssertEqual(hex.count, 94)
        let decoded = PackedFrame(hex94: hex)
        XCTAssertEqual(decoded, frame)
    }

    func testBase64RoundTrip() {
        var frame = PackedFrame()
        frame.fill()
        let b64 = frame.base64
        let decoded = PackedFrame(base64: b64)
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded?.litCount, 370)
    }

    func testBitsArrayInit() {
        var bits = [Int](repeating: 0, count: 370)
        bits[0] = 1
        bits[100] = 1
        let frame = PackedFrame(bits: bits)
        XCTAssertNotNil(frame)
        XCTAssertTrue(frame![0])
        XCTAssertTrue(frame![100])
        XCTAssertEqual(frame!.litCount, 2)
    }

    func testInvert() {
        var frame = PackedFrame()
        frame.set(0)
        frame.invert()
        XCTAssertFalse(frame[0])
        XCTAssertTrue(frame[1])
        XCTAssertTrue(frame.validate())
        XCTAssertEqual(frame.litCount, 369)
    }

    func testFillThenClear() {
        var frame = PackedFrame()
        frame.fill()
        XCTAssertEqual(frame.litCount, 370)
        XCTAssertTrue(frame.validate())
        frame.clearAll()
        XCTAssertEqual(frame.litCount, 0)
    }

    func testUnion() {
        var a = PackedFrame()
        a.set(1)
        var b = PackedFrame()
        b.set(2)
        a.formUnion(b)
        XCTAssertTrue(a[1])
        XCTAssertTrue(a[2])
    }

    // MARK: parse(text:)

    func testParseHex94() throws {
        var frame = PackedFrame()
        frame.set(5)
        let parsed = try PackedFrame.parse(text: "  \(frame.hex94)  ")
        XCTAssertEqual(parsed, frame)
    }

    func testParseBase64() throws {
        var frame = PackedFrame()
        frame.set(10)
        let parsed = try PackedFrame.parse(text: frame.base64)
        XCTAssertEqual(parsed, frame)
    }

    func testParseIntArray() throws {
        var frame = PackedFrame()
        frame.set(1)
        let ints = frame.bytes.map { Int($0) }
        let json = "[\(ints.map(String.init).joined(separator: ","))]"
        let parsed = try PackedFrame.parse(text: json)
        XCTAssertEqual(parsed, frame)
    }

    func testParseEmptyThrows() {
        XCTAssertThrowsError(try PackedFrame.parse(text: "   ")) { error in
            XCTAssertEqual(error as? PackedFrameParseError, .empty)
        }
    }

    func testParseWrongIntCountThrows() {
        let json = "[" + Array(repeating: "0", count: 10).joined(separator: ",") + "]"
        XCTAssertThrowsError(try PackedFrame.parse(text: json)) { error in
            XCTAssertEqual(error as? PackedFrameParseError, .wrongIntCount(10))
        }
    }

    func testParseOutOfRangeIntThrows() {
        var ints = [Int](repeating: 0, count: PackedFrame.byteCount)
        ints[0] = 999
        let json = "[\(ints.map(String.init).joined(separator: ","))]"
        XCTAssertThrowsError(try PackedFrame.parse(text: json)) { error in
            XCTAssertEqual(error as? PackedFrameParseError, .intOutOfRange(999))
        }
    }

    func testParseGarbageThrowsInvalidFormat() {
        XCTAssertThrowsError(try PackedFrame.parse(text: "not a frame")) { error in
            XCTAssertEqual(error as? PackedFrameParseError, .invalidFormat)
        }
    }

    // MARK: hex94 strict decoding (R22)

    /// `UInt8(_:radix: 16)` accepts a leading sign, which is not a valid hex
    /// digit; a pair like `"+1"` or `"-0"` must be rejected, not parsed as 1/0.
    func testHex94RejectsSignedPairs() {
        let tail = String(repeating: "0", count: PackedFrame.byteCount * 2 - 2)
        XCTAssertNil(PackedFrame(hex94: "+1" + tail))
        XCTAssertNil(PackedFrame(hex94: "-0" + tail))
    }

    func testHex94RejectsFullWidthDigits() {
        var hex = Array(String(repeating: "0", count: PackedFrame.byteCount * 2))
        hex[0] = "\u{FF10}" // fullwidth '0'
        hex[1] = "\u{FF10}"
        XCTAssertNil(PackedFrame(hex94: String(hex)))
    }

    func testHex94RejectsWrongLengths() {
        let tooShort = String(repeating: "0", count: PackedFrame.byteCount * 2 - 1)
        let tooLong = String(repeating: "0", count: PackedFrame.byteCount * 2 + 1)
        XCTAssertNil(PackedFrame(hex94: tooShort))
        XCTAssertNil(PackedFrame(hex94: tooLong))
    }

    func testHex94StillDecodesValidInputIdentically() {
        var frame = PackedFrame()
        frame.set(3)
        frame.set(200)
        let hex = frame.hex94
        XCTAssertEqual(hex.count, PackedFrame.byteCount * 2)
        XCTAssertEqual(PackedFrame(hex94: hex), frame)
    }
}
