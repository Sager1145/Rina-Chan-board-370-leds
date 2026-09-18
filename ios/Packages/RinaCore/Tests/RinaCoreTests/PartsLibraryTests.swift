import XCTest
@testable import RinaCore

final class PartsLibraryTests: XCTestCase {
    static var resourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PartsLibraryTests.swift -> RinaCoreTests/
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

    func loadPhysicalToLogicalTable() throws -> [Int] {
        let url = Self.resourcesURL.appendingPathComponent("matrix_geometry.json")
        let data = try TestResources.data(at: url)
        struct Doc: Codable {
            let physicalToLogicalIndex: [Int]
            enum CodingKeys: String, CodingKey { case physicalToLogicalIndex = "physical_to_logical_index" }
        }
        return try JSONDecoder().decode(Doc.self, from: data).physicalToLogicalIndex
    }

    func testPartCount() throws {
        let library = try loadLibrary()
        XCTAssertEqual(library.parts.count, 92)
    }

    func testIdLists() throws {
        let library = try loadLibrary()
        var expectedLeye = ["0"]
        expectedLeye.append(contentsOf: (101...127).map(String.init))
        XCTAssertEqual(library.ids(for: .leye), expectedLeye)

        var expectedReye = ["0"]
        expectedReye.append(contentsOf: (201...227).map(String.init))
        XCTAssertEqual(library.ids(for: .reye), expectedReye)

        var expectedMouth = ["0"]
        expectedMouth.append(contentsOf: (301...332).map(String.init))
        XCTAssertEqual(library.ids(for: .mouth), expectedMouth)

        let expectedCheek = (400...405).map(String.init)
        XCTAssertEqual(library.ids(for: .cheek), expectedCheek)
    }

    func testHexFrameMatchesStripIndicesFrameForAllParts() throws {
        let library = try loadLibrary()
        let table = try loadPhysicalToLogicalTable()
        for (id, part) in library.parts {
            let hexFrame = library.frame(for: part)
            let stripFrame = library.frameFromStripIndices(part, physicalToLogicalIndex: table)
            XCTAssertEqual(hexFrame, stripFrame, "frame mismatch for part \(id) (\(part.name))")
        }
    }

    func testComposeDefaultCall() throws {
        let library = try loadLibrary()
        let composed = library.compose(call: .defaultCall)
        XCTAssertGreaterThan(composed.litCount, 0)

        let leyePart = library.resolvedPart(group: .leye, id: PartsCall.defaultCall.leye)
        let reyePart = library.resolvedPart(group: .reye, id: PartsCall.defaultCall.reye)
        let mouthPart = library.resolvedPart(group: .mouth, id: PartsCall.defaultCall.mouth)
        let cheekPart = library.resolvedPart(group: .cheek, id: PartsCall.defaultCall.cheek)

        var expected = PackedFrame()
        expected.formUnion(library.frame(for: leyePart))
        expected.formUnion(library.frame(for: reyePart))
        expected.formUnion(library.frame(for: mouthPart))
        expected.formUnion(library.frame(for: cheekPart))
        XCTAssertEqual(composed, expected)

        // Cheek default ("400") resolves to the empty part, so lit count should
        // equal leye+reye+mouth's combined lit counts when there's no overlap.
        if !overlaps(leyePart, reyePart, mouthPart, cheekPart) {
            XCTAssertEqual(composed.litCount, leyePart.litCount + reyePart.litCount + mouthPart.litCount + cheekPart.litCount)
        }
    }

    private func overlaps(_ parts: PartsLibrary.Part...) -> Bool {
        var seen = Set<Int>()
        for part in parts {
            for led in 0..<PackedFrame.ledCount where PackedFrame(hex94: part.frame)?[led] == true {
                if !seen.insert(led).inserted { return true }
            }
        }
        return false
    }

    func testComposeAllEmptyIsBlank() throws {
        let library = try loadLibrary()
        let emptyCall = PartsCall(leye: "0", reye: "0", mouth: "0", cheek: "400")
        let composed = library.compose(call: emptyCall)
        XCTAssertEqual(composed, PackedFrame())
        XCTAssertEqual(composed.litCount, 0)
    }

    func testMatchingCallReturnsDefaultCall() throws {
        let library = try loadLibrary()
        XCTAssertEqual(library.matchingCall(for: library.compose(call: .defaultCall)), .defaultCall)
    }

    func testMatchingCallReturnsAlternateCall() throws {
        let library = try loadLibrary()
        let expected = PartsCall(leye: "102", reye: "202", mouth: "305", cheek: "401")
        XCTAssertEqual(library.matchingCall(for: library.compose(call: expected)), expected)
    }

    func testMatchingCallReturnsEmptyCall() throws {
        let library = try loadLibrary()
        let expected = PartsCall(leye: "0", reye: "0", mouth: "0", cheek: "400")
        XCTAssertEqual(library.matchingCall(for: library.compose(call: expected)), expected)
    }

    func testMatchingCallRejectsUnmatchableFrame() throws {
        let library = try loadLibrary()
        var unmatched = PackedFrame()
        let everyPart = library.parts.values.reduce(into: PackedFrame()) { frame, part in
            frame.formUnion(library.frame(for: part))
        }
        guard let unusedLED = (0..<PackedFrame.ledCount).first(where: { !everyPart[$0] }) else {
            XCTFail("Expected at least one LED outside every part variant")
            return
        }
        unmatched.set(unusedLED)
        XCTAssertNil(library.matchingCall(for: unmatched))
    }

    func testMirroredEyeIdRoundTrips() throws {
        let library = try loadLibrary()
        for leyeId in library.ids(for: .leye) {
            guard let reyeId = library.mirroredEyeId(leyeId) else {
                XCTFail("no mirror for \(leyeId)")
                continue
            }
            XCTAssertEqual(library.mirroredEyeId(reyeId), leyeId)
        }
        // Index 1 -> "101" <-> "201" (parallel display index, not string substitution).
        XCTAssertEqual(library.mirroredEyeId("101"), "201")
        XCTAssertEqual(library.mirroredEyeId("201"), "101")
    }

    func testRandomCallNeverPicksEmptyEyesOrMouth() throws {
        let library = try loadLibrary()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let call = library.randomCall(using: &generator)
            XCTAssertNotEqual(call.leye, "0")
            XCTAssertNotEqual(call.reye, "0")
            XCTAssertNotEqual(call.mouth, "0")
            XCTAssertTrue(library.ids(for: .cheek).contains(call.cheek))
        }
    }
}
