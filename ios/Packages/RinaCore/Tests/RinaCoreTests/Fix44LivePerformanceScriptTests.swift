import XCTest
@testable import RinaCore

/// A script saved with Windows (CRLF) or classic Mac (CR) line endings must
/// parse exactly like its LF form.
final class Fix44LivePerformanceScriptTests: XCTestCase {
    private func loadLibrary() throws -> PartsLibrary {
        let url = LivePerformanceScriptTests.resourcesURL.appendingPathComponent("expression_parts.json")
        return try PartsLibrary(jsonData: TestResources.data(at: url))
    }

    private let lfText = "#title demo\n#fps 12\n\n0!101,201,301,400\n5!102,202,305,401\n"

    func testParsesCRLFLineEndings() throws {
        let library = try loadLibrary()
        let expected = try LivePerformanceScriptParser.parse(lfText, library: library)
        let crlf = lfText.replacingOccurrences(of: "\n", with: "\r\n")

        let script = try LivePerformanceScriptParser.parse(crlf, library: library)

        XCTAssertEqual(script.title, "demo")
        XCTAssertEqual(script.fps, 12)
        XCTAssertEqual(script.keyframes, expected.keyframes)
        XCTAssertEqual(script.keyframes.count, 2)
    }

    func testParsesBareCRLineEndings() throws {
        let library = try loadLibrary()
        let expected = try LivePerformanceScriptParser.parse(lfText, library: library)
        let cr = lfText.replacingOccurrences(of: "\n", with: "\r")

        let script = try LivePerformanceScriptParser.parse(cr, library: library)

        XCTAssertEqual(script.fps, 12)
        XCTAssertEqual(script.keyframes, expected.keyframes)
    }

    func testCRLFErrorReportsTheOffendingLine() throws {
        let library = try loadLibrary()
        let text = "#fps 10\r\n0!101,201,301,400\r\nnot a keyframe\r\n"

        XCTAssertThrowsError(try LivePerformanceScriptParser.parse(text, library: library)) { error in
            guard case LivePerformanceScriptError.badKeyframe(let line, let lineText) = error else {
                return XCTFail("expected badKeyframe, got \(error)")
            }
            XCTAssertEqual(line, 3)
            XCTAssertEqual(lineText, "not a keyframe")
        }
    }
}
