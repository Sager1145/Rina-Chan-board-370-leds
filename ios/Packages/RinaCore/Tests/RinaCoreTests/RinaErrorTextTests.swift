import XCTest
@testable import RinaCore

/// These tests never depend on a translation existing: they compare against
/// the same `NSLocalizedString` lookup the code performs (which returns the
/// zh-Hans key when the bundle has no catalog) or assert on structure.
final class RinaErrorTextTests: XCTestCase {
    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private let genericSystemFragments = ["couldn’t be completed", "couldn't be completed", "RinaCore."]

    private func assertSpecific(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(message.isEmpty, file: file, line: line)
        for fragment in genericSystemFragments {
            XCTAssertFalse(message.contains(fragment), "generic text leaked: \(message)", file: file, line: line)
        }
    }

    // MARK: Board table

    func testExactFirmwareTextMapsToItsOwnMessage() {
        let message = RinaErrorText.boardMessage("scroll upload already in progress", code: 409)
        XCTAssertEqual(message, localized("面板正在接收另一段滚动文字，请稍后重试"))
        XCTAssertFalse(message.contains("scroll upload already in progress"))
        XCTAssertTrue(RinaErrorText.isKnownBoardText("scroll upload already in progress"))
    }

    func testExactMatchIgnoresSurroundingWhitespaceAndCode() {
        XCTAssertEqual(RinaErrorText.boardMessage("  boot_mismatch\n", code: nil),
                       RinaErrorText.boardMessage("boot_mismatch", code: 409))
        XCTAssertEqual(RinaErrorText.boardMessage("boot_mismatch", code: 409),
                       localized("面板已重启，请重新同步后重试"))
    }

    func testPrefixMatchCarriesTheVariableTail() {
        let unknown = RinaErrorText.boardMessage("unknown command: set_sparkle", code: 400)
        XCTAssertEqual(unknown, String(format: localized("面板不支持指令 %@，请更新面板固件"), "set_sparkle"))
        XCTAssertTrue(unknown.contains("set_sparkle"))

        let missing = RinaErrorText.boardMessage("saved face not found: local_abc", code: 404)
        XCTAssertTrue(missing.contains("local_abc"))
        XCTAssertFalse(missing.contains("saved face not found"))

        let json = RinaErrorText.boardMessage("invalid JSON: IncompleteInput", code: 400)
        XCTAssertTrue(json.contains("IncompleteInput"))
    }

    func testPrefixMatchExtractsLimits() {
        let name = RinaErrorText.boardMessage("name too long (max 24 bytes)", code: 400)
        XCTAssertEqual(name, String(format: localized("面板名称过长，最多 %@ 字节"), "24"))

        let full = RinaErrorText.boardMessage("too many faces; firmware max is 64", code: 413)
        XCTAssertEqual(full, String(format: localized("面板表情库已满，最多保存 %@ 个表情"), "64"))

        let led = RinaErrorText.boardMessage("led must be -1 or 0..369", code: 400)
        XCTAssertTrue(led.contains("369"))
    }

    func testCommandPrefixedSavedFacesTextsMatch() {
        let parse = RinaErrorText.boardMessage("face_upsert: saved_faces.json parse failed: InvalidInput", code: 500)
        XCTAssertEqual(parse, String(format: localized("面板上的表情库文件已损坏：%@"), "InvalidInput"))

        let unreadable = RinaErrorText.boardMessage("face_delete: saved_faces.json not found or unreadable", code: 500)
        XCTAssertEqual(unreadable, localized("面板上的表情库文件无法读取"))
    }

    func testEveryPlausibleFirmwareTextHasAnEntry() {
        let texts = [
            "failed to start wifi scan", "invalid ssid or password", "invalid mode", "invalid targetMode",
            "AP IP changes require Bluetooth",
            "invalid AP settings (private canonical IPv4 host 1-254 required) or AP start failed",
            "unknown command: x", "saved faces changed; reload before writing", "LittleFS is not mounted",
            "saved_faces.json exceeds firmware size limit", "faces document too large",
            "name must be 1..64 chars", "face.name must be 1..64 bytes", "name is not valid UTF-8",
            "cannot rename a default face", "cannot delete a default face", "cannot overwrite a default face",
            "cannot remove the last default face", "unknown face id", "face id already exists",
            "face changed since it was loaded; reload before overwriting",
            "ids must list every face exactly once (bad id: local_1)", "too many faces on disk for reorder",
            "boot_mismatch", "no_timeline", "sourceText too large", "saved faces unavailable",
            "insufficient memory for scroll meta", "insufficient memory for scroll upload",
            "insufficient memory for scroll_bitmap upload", "insufficient memory for scroll_bitmap expansion",
            "scroll frame buffer unavailable", "too many scroll frames", "scroll upload was superseded",
            "failed to write scroll frames", "insufficient memory for faces upload",
            "saved faces changed during upload", "saved_faces.json changed mid-transfer",
            "inbound overflow", "frame payload too large", "JSON response exceeds capacity",
            "unexpected chunk offset", "no active blob session", "incomplete blob upload",
            "face.frameHex must be 94 hex chars", "face.frameBytes must contain 47 bytes",
            "invalid scroll frame: packed frame has non-zero unused bits",
            "color must be #RRGGBB or RRGGBB (hex)", "mirror must be -1 or 0..369",
        ]
        for text in texts {
            XCTAssertTrue(RinaErrorText.isKnownBoardText(text), "no table entry for: \(text)")
            let message = RinaErrorText.boardMessage(text, code: 400)
            assertSpecific(message)
            XCTAssertNotEqual(message, text)
        }
    }

    // MARK: Board fallback

    func testUnknownTextFallsBackByCodeAndKeepsRawTextAndCode() {
        let cases: [(Int, String)] = [
            (400, "面板拒绝了请求"), (404, "面板上找不到请求的内容"), (409, "面板状态已变化，请刷新后重试"),
            (413, "发送的内容超出面板限制"), (500, "面板内部错误"), (503, "面板暂时无法处理请求"),
            (507, "面板内存不足"), (418, "面板返回了错误"),
        ]
        for (code, head) in cases {
            let raw = "some brand new firmware text \(code)"
            XCTAssertFalse(RinaErrorText.isKnownBoardText(raw))
            let message = RinaErrorText.boardMessage(raw, code: code)
            XCTAssertTrue(message.contains(raw), message)
            XCTAssertTrue(message.contains(String(code)), message)
            XCTAssertTrue(message.contains(localized(head)), message)
            XCTAssertEqual(message, String(format: localized("%1$@（%2$lld）：%3$@"), localized(head), code, raw))
        }
        let heads = Set(cases.map { RinaErrorText.boardMessage("x", code: $0.0) })
        XCTAssertEqual(heads.count, cases.count, "each code class has its own sentence")
    }

    func testFallbackWithOnlyTextOrOnlyCode() {
        let textOnly = RinaErrorText.boardMessage("denied by policy", code: nil)
        XCTAssertEqual(textOnly, String(format: localized("%1$@：%2$@"), localized("面板返回了错误"), "denied by policy"))
        XCTAssertTrue(textOnly.contains("denied by policy"))

        let codeOnly = RinaErrorText.boardMessage("", code: 503)
        XCTAssertEqual(codeOnly, String(format: localized("%1$@（%2$lld）"), localized("面板暂时无法处理请求"), 503))
        XCTAssertTrue(codeOnly.contains("503"))
    }

    func testNoTextAndNoCodeIsTheUnknownBoardError() {
        let expected = localized("面板返回了未知错误")
        XCTAssertEqual(RinaErrorText.boardMessage(nil, code: nil), expected)
        XCTAssertEqual(RinaErrorText.boardMessage("", code: nil), expected)
        XCTAssertEqual(RinaErrorText.boardMessage(" \n", code: nil), expected)
    }

    // MARK: RinaLinkError

    func testRinaLinkErrorDescriptionIsTheBoardMessageAndRawTextStays() {
        let error = RinaLinkError(error: "scroll upload was superseded", code: 409)
        XCTAssertEqual(error.error, "scroll upload was superseded")
        XCTAssertEqual(error.boardText, "scroll upload was superseded")
        XCTAssertEqual(error.errorDescription, RinaErrorText.boardMessage("scroll upload was superseded", code: 409))
        XCTAssertEqual(error.localizedDescription, error.errorDescription)
        XCTAssertEqual(RinaErrorText.message(for: error), error.errorDescription)
        XCTAssertEqual((error as any Error).rinaUserMessage, error.errorDescription)
    }

    func testErrorFramePayloadWellFormedDecodesExactly() throws {
        let original = RinaLinkError(error: "unexpected chunk offset", code: 400, expectedOffset: 188)
        let payload = try JSONEncoder().encode(original)
        XCTAssertEqual(RinaLinkError(errorFramePayload: payload), original)
        XCTAssertEqual(RinaLinkError(errorFramePayload: Data(#"{"error":"busy","code":409}"#.utf8)),
                       RinaLinkError(error: "busy", code: 409))
    }

    func testErrorFramePayloadReadsLooseFields() {
        let message = RinaLinkError(errorFramePayload: Data(#"{"ok":false,"message":"flash busy","code":"503"}"#.utf8))
        XCTAssertEqual(message, RinaLinkError(error: "flash busy", code: 503))

        let nested = RinaLinkError(errorFramePayload: Data(#"{"error":{"message":"nested"},"status":500}"#.utf8))
        XCTAssertEqual(nested, RinaLinkError(error: "nested", code: 500))

        let codeOnly = RinaLinkError(errorFramePayload: Data(#"{"ok":false,"code":507}"#.utf8))
        XCTAssertEqual(codeOnly, RinaLinkError(error: "", code: 507))
        XCTAssertTrue(RinaErrorText.message(for: codeOnly).contains("507"))

        let boolCode = RinaLinkError(errorFramePayload: Data(#"{"msg":"x","code":true}"#.utf8))
        XCTAssertEqual(boolCode, RinaLinkError(error: "x"))
    }

    func testErrorFramePayloadFallsBackToTextThenEmpty() {
        let truncated = RinaLinkError(errorFramePayload: Data(#"  {"ok":false,"error":"LittleFS is not mou"#.utf8))
        XCTAssertEqual(truncated.error, #"{"ok":false,"error":"LittleFS is not mou"#)
        XCTAssertNil(truncated.code)
        XCTAssertTrue(RinaErrorText.message(for: truncated).contains("LittleFS is not mou"))

        let fragment = RinaLinkError(errorFramePayload: Data(#""plain string""#.utf8))
        XCTAssertEqual(fragment.error, "plain string")

        let long = RinaLinkError(errorFramePayload: Data(String(repeating: "x", count: 5000).utf8))
        XCTAssertEqual(long.error.count, RinaLinkError.maxUndecodableTextLength + 1)

        let unknown = localized("面板返回了未知错误")
        XCTAssertEqual(RinaErrorText.message(for: RinaLinkError(errorFramePayload: Data())), unknown)
        XCTAssertEqual(RinaErrorText.message(for: RinaLinkError(errorFramePayload: Data([0xFF, 0xFE, 0x80]))), unknown)
        XCTAssertEqual(RinaErrorText.message(for: RinaLinkError(errorFramePayload: Data("{}".utf8))), unknown)
    }

    // MARK: Other errors

    func testTransportAndLocalizedErrorsUseTheirOwnDescription() {
        XCTAssertEqual(RinaErrorText.message(for: RinaTransportError.timeout), localized("面板响应超时"))
        XCTAssertEqual(RinaErrorText.message(for: RinaTransportError.underlying("具体原因")), "具体原因")
        XCTAssertEqual(RinaErrorText.message(for: PackedFrameParseError.wrongIntCount(3)),
                       String(format: localized("画面数据需要 47 个整数，实际是 %lld 个"), 3))
    }

    func testCancellationErrorUsesTheCancelledString() {
        XCTAssertEqual(RinaErrorText.message(for: CancellationError()), localized("操作已取消"))
        XCTAssertEqual(RinaErrorText.message(for: CancellationError()),
                       RinaErrorText.message(for: RinaTransportError.cancelled))
    }

    private struct Reply: Decodable {
        struct Face: Decodable { let frameHex: String }
        let faces: [Face]
        let gen: Int
    }

    private func decodingError(_ json: String) -> any Error {
        do {
            _ = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
            XCTFail("expected a decoding error")
            return CancellationError()
        } catch {
            return error
        }
    }

    func testDecodingErrorNamesTheField() {
        let missing = RinaErrorText.message(for: decodingError(#"{"faces":[{"frameHex":"00"},{}],"gen":1}"#))
        XCTAssertEqual(missing, String(format: localized("数据无法解析：缺少字段 %@"), "faces[1].frameHex"))

        let mismatch = RinaErrorText.message(for: decodingError(#"{"faces":[],"gen":"one"}"#))
        XCTAssertEqual(mismatch, String(format: localized("数据无法解析：字段 %@ 的类型不符"), "gen"))

        let null = RinaErrorText.message(for: decodingError(#"{"faces":[],"gen":null}"#))
        XCTAssertTrue(null.contains("gen"), null)

        let garbage = RinaErrorText.message(for: decodingError("not json"))
        XCTAssertEqual(garbage, localized("数据无法解析：格式不正确"))

        for message in [missing, mismatch, null, garbage] { assertSpecific(message) }
    }

    private enum PlainError: Error { case somethingOdd(Int) }

    func testPlainErrorKeepsItsDescribedValue() {
        let message = RinaErrorText.message(for: PlainError.somethingOdd(7))
        XCTAssertEqual(message, String(format: localized("发生未知错误：%@"), "somethingOdd(7)"))
        XCTAssertTrue(message.contains("somethingOdd(7)"))
        XCTAssertFalse(message.contains("couldn’t be completed"))
        XCTAssertEqual(PlainError.somethingOdd(7).rinaUserMessage, message)
    }

    private struct BlankDescription: LocalizedError {
        var errorDescription: String? { "  " }
    }

    func testBlankLocalizedDescriptionFallsThroughToGeneric() {
        let message = RinaErrorText.message(for: BlankDescription())
        XCTAssertTrue(message.contains("BlankDescription"), message)
    }

    func testSystemNSErrorUsesItsOwnLocalizedDescription() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "The file doesn’t exist."])
        XCTAssertEqual(RinaErrorText.message(for: error), "The file doesn’t exist.")

        let url = URLError(.notConnectedToInternet)
        XCTAssertEqual(RinaErrorText.message(for: url), (url as NSError).localizedDescription)
    }

    // MARK: Conformances added alongside

    func testCoreErrorEnumsDescribeTheirValues() {
        XCTAssertTrue(LivePerformanceScriptError.badKeyframe(line: 12, text: "3!oops").localizedDescription.contains("12"))
        XCTAssertTrue(LivePerformanceScriptError.badKeyframe(line: 12, text: "3!oops").localizedDescription.contains("3!oops"))
        let part = LivePerformanceScriptError.unknownPart(line: 4, group: .mouth, value: "999").localizedDescription
        XCTAssertTrue(part.contains("4") && part.contains("999") && part.contains(PartGroup.mouth.displayName), part)
        XCTAssertTrue(StitchedScreenLayout.LayoutError.invalidGap(index: 1, value: 12).localizedDescription.contains("12"))
        XCTAssertTrue(GroupScrollBitmap.BuildError.tooManyFrames(frameCount: 4000, limit: 3072)
            .localizedDescription.contains("4000"))
        XCTAssertTrue(RinaResources.LoaderError.resourceNotFound(name: "ark12", ext: "json")
            .localizedDescription.contains("ark12.json"))
        XCTAssertTrue(PackedFrameParseError.intOutOfRange(300).localizedDescription.contains("300"))
        XCTAssertTrue(ScrollRasterizer.RasterizerError.tooManyFrames(projected: 5000).localizedDescription.contains("5000"))
        let all: [any Error] = [
            ArkPixelFont.FontError.invalidFormat, ArkPixelFont.FontError.invalidGlyphTable,
            GroupScrollBitmap.BuildError.emptyText, LivePerformanceScriptError.empty,
            PackedFrameParseError.empty, ScrollRasterizer.RasterizerError.textTooLong,
            StitchedScreenLayout.LayoutError.invalidSlotCount(9),
        ]
        for error in all { assertSpecific(RinaErrorText.message(for: error)) }
    }
}
