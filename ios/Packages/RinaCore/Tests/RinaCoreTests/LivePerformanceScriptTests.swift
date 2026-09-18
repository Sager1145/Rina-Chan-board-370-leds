import XCTest
@testable import RinaCore

final class LivePerformanceScriptTests: XCTestCase {
    static var resourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LivePerformanceScriptTests.swift -> RinaCoreTests/
            .deletingLastPathComponent() // RinaCoreTests -> Tests/
            .deletingLastPathComponent() // Tests -> RinaCore/ (package root)
            .deletingLastPathComponent() // RinaCore -> Packages/
            .deletingLastPathComponent() // Packages -> ios/
            .appendingPathComponent("RinaBoard/Resources")
    }

    func loadLibrary() throws -> PartsLibrary {
        let url = Self.resourcesURL.appendingPathComponent("expression_parts.json")
        let data = try TestResources.data(at: url)
        return try PartsLibrary(jsonData: data)
    }

    func testParsesOwnIdForm() throws {
        let library = try loadLibrary()
        let text = """
        #fps 10
        0!101,201,301,400
        5!102,202,305,401
        """
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        XCTAssertEqual(script.fps, 10)
        XCTAssertEqual(script.keyframes.count, 2)
        XCTAssertEqual(script.keyframes[0], LiveKeyframe(frame: 0, call: PartsCall(leye: "101", reye: "201", mouth: "301", cheek: "400")))
        XCTAssertEqual(script.keyframes[1], LiveKeyframe(frame: 5, call: PartsCall(leye: "102", reye: "202", mouth: "305", cheek: "401")))
    }

    func testParsesFlyAkariSmallIndexForm() throws {
        let library = try loadLibrary()
        // Index 1 into leye/reye ids ("0", "101"...) resolves to "101"/"201";
        // index 1 into cheek ids ("400"..."405") resolves to "401".
        let text = "0!1,1,1,1"
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        XCTAssertEqual(script.keyframes.count, 1)
        XCTAssertEqual(script.keyframes[0].call, PartsCall(leye: "101", reye: "201", mouth: "301", cheek: "401"))
    }

    func testParsesMixedFile() throws {
        let library = try loadLibrary()
        let text = """
        #fps 10
        0!101,201,301,400
        2!1,1,1,1
        """
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        XCTAssertEqual(script.keyframes.count, 2)
        XCTAssertEqual(script.keyframes[0].call.leye, "101")
        XCTAssertEqual(script.keyframes[1].call.leye, "101")
    }

    func testTrailingCommaAndWhitespaceTolerance() throws {
        let library = try loadLibrary()
        let text = "0! 101 , 201 , 301 , 400 ,"
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        XCTAssertEqual(script.keyframes.count, 1)
        XCTAssertEqual(script.keyframes[0].call, PartsCall(leye: "101", reye: "201", mouth: "301", cheek: "400"))
    }

    func testFpsAndTitleDirectives() throws {
        let library = try loadLibrary()
        let text = """
        # a comment
        #fps 24
        #title poppin_up
        0!101,201,301,400
        """
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        XCTAssertEqual(script.fps, 24)
        XCTAssertEqual(script.title, "poppin_up")
    }

    func testDefaultFpsIsTen() throws {
        let library = try loadLibrary()
        let text = "0!101,201,301,400"
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        XCTAssertEqual(script.fps, 10)
        XCTAssertEqual(LivePerformanceScriptParser.defaultFps, 10)
    }

    func testIndexAtMsBoundaries() throws {
        let library = try loadLibrary()
        let text = """
        #fps 10
        1!101,201,301,400
        3!102,202,305,401
        6!103,203,306,402
        """
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        // keyframe times (ms): frame*1000/fps -> 100, 300, 600
        XCTAssertNil(script.index(atMs: 0))
        XCTAssertNil(script.index(atMs: 99))
        XCTAssertEqual(script.index(atMs: 100), 0)
        XCTAssertEqual(script.index(atMs: 250), 0)
        XCTAssertEqual(script.index(atMs: 300), 1)
        XCTAssertEqual(script.index(atMs: 599), 1)
        XCTAssertEqual(script.index(atMs: 600), 2)
        XCTAssertEqual(script.index(atMs: 10_000), 2)
        XCTAssertEqual(script.durationMs, 600)
    }

    func testEmptyScriptThrows() throws {
        let library = try loadLibrary()
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("#fps 10\n# only comments\n", library: library)) { error in
            XCTAssertEqual(error as? LivePerformanceScriptError, .empty)
        }
    }

    func testBadFpsThrows() throws {
        let library = try loadLibrary()
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("#fps 0\n0!101,201,301,400", library: library)) { error in
            guard case .badFps = error as? LivePerformanceScriptError else {
                return XCTFail("expected badFps, got \(error)")
            }
        }
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("#fps 61\n0!101,201,301,400", library: library)) { error in
            guard case .badFps = error as? LivePerformanceScriptError else {
                return XCTFail("expected badFps, got \(error)")
            }
        }
    }

    func testBadKeyframeThrows() throws {
        let library = try loadLibrary()
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("not-a-keyframe-line", library: library)) { error in
            guard case .badKeyframe = error as? LivePerformanceScriptError else {
                return XCTFail("expected badKeyframe, got \(error)")
            }
        }
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("x!101,201,301,400", library: library)) { error in
            guard case .badKeyframe = error as? LivePerformanceScriptError else {
                return XCTFail("expected badKeyframe, got \(error)")
            }
        }
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("0!101,201,301", library: library)) { error in
            guard case .badKeyframe = error as? LivePerformanceScriptError else {
                return XCTFail("expected badKeyframe, got \(error)")
            }
        }
    }

    func testUnknownPartThrows() throws {
        let library = try loadLibrary()
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("0!999,201,301,400", library: library)) { error in
            guard case .unknownPart(_, let group, let value) = error as? LivePerformanceScriptError else {
                return XCTFail("expected unknownPart, got \(error)")
            }
            XCTAssertEqual(group, .leye)
            XCTAssertEqual(value, "999")
        }
    }

    func testNonMonotonicFrameThrows() throws {
        let library = try loadLibrary()
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("""
        5!101,201,301,400
        5!102,202,305,401
        """, library: library)) { error in
            guard case .nonMonotonicFrame(_, let frame) = error as? LivePerformanceScriptError else {
                return XCTFail("expected nonMonotonicFrame, got \(error)")
            }
            XCTAssertEqual(frame, 5)
        }
        XCTAssertThrowsError(try LivePerformanceScriptParser.parse("""
        5!101,201,301,400
        3!102,202,305,401
        """, library: library)) { error in
            guard case .nonMonotonicFrame = error as? LivePerformanceScriptError else {
                return XCTFail("expected nonMonotonicFrame, got \(error)")
            }
        }
    }

    func testFrameTooLargeThrows() throws {
        let library = try loadLibrary()
        XCTAssertThrowsError(
            try LivePerformanceScriptParser.parse("1000000000000000000!101,201,301,400", library: library)
        ) { error in
            guard case .frameTooLarge = error as? LivePerformanceScriptError else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }

    func testFrameAtBoundComputesDurationWithoutTrapping() throws {
        let library = try loadLibrary()
        let text = "\(LivePerformanceScriptParser.maxFrame)!101,201,301,400"
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        XCTAssertEqual(script.durationMs, LivePerformanceScriptParser.maxFrame * 1000 / LivePerformanceScriptParser.defaultFps)
    }

    func testEmptyKeyframesRejectedByMake() throws {
        XCTAssertThrowsError(try LivePerformanceScript.make(title: nil, fps: 10, keyframes: [])) { error in
            XCTAssertEqual(error as? LivePerformanceScriptError, .empty)
        }
    }

    func testComposedFramesMatchesKeyframeCountAndFirstEntry() throws {
        let library = try loadLibrary()
        let text = """
        0!101,201,301,400
        3!102,202,305,401
        6!103,203,306,402
        """
        let script = try LivePerformanceScriptParser.parse(text, library: library)
        let frames = script.composedFrames(using: library)
        XCTAssertEqual(frames.count, script.keyframes.count)
        XCTAssertEqual(frames[0], library.compose(call: script.keyframes[0].call))
    }
}
