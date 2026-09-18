import XCTest
@testable import RinaCore

final class ColorPresetsTests: XCTestCase {
    static var resourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorPresetsTests.swift -> RinaCoreTests/
            .deletingLastPathComponent() // RinaCoreTests -> Tests/
            .deletingLastPathComponent() // Tests -> RinaCore/ (package root)
            .deletingLastPathComponent() // RinaCore -> Packages/
            .deletingLastPathComponent() // Packages -> ios/
            .appendingPathComponent("RinaBoard/Resources")
    }

    func loadPresets() throws -> ColorPresets {
        let url = Self.resourcesURL.appendingPathComponent("color_presets.json")
        let data = try TestResources.data(at: url)
        return try ColorPresets(jsonData: data)
    }

    func testParentAndChildCounts() throws {
        let presets = try loadPresets()
        XCTAssertEqual(presets.parents.count, 6)
        let totalChildren = presets.children.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalChildren, 67)
    }

    func testLookupByHex() throws {
        let presets = try loadPresets()
        guard let firstParent = presets.parents.first(where: { presets.children(of: $0).isEmpty == false }) else {
            XCTFail("no parent with children")
            return
        }
        let child = presets.children(of: firstParent)[0]
        guard let (parent, foundChild) = presets.lookup(hex: child.hex) else {
            XCTFail("lookup failed for \(child.hex)")
            return
        }
        XCTAssertEqual(parent.id, firstParent.id)
        XCTAssertEqual(foundChild.hex.lowercased(), child.hex.lowercased())

        // Case-insensitive.
        XCTAssertNotNil(presets.lookup(hex: child.hex.uppercased()))
    }

    func testTeamColorsAreSelectableBeforeMembers() throws {
        let presets = try XCTUnwrap(loadPresets())
        for parent in presets.parents {
            let swatches = presets.swatches(of: parent)
            XCTAssertEqual(swatches.first?.name, parent.name)
            XCTAssertEqual(swatches.first?.hex, parent.color)
            XCTAssertEqual(Array(swatches.dropFirst()), presets.children(of: parent))
            XCTAssertEqual(presets.parent(containing: parent.color.uppercased()), parent)
            XCTAssertEqual(presets.parent(containing: String(parent.color.dropFirst())), parent)
        }
        XCTAssertNil(presets.parent(containing: "#123456"))
    }

    func testRGBHexParseAndFormat() {
        XCTAssertTrue(RGBHex.parseHex("#ec3fc7").map { $0 == (0xec, 0x3f, 0xc7) } ?? false)
        XCTAssertEqual(RGBHex.formatHex(r: 0xec, g: 0x3f, b: 0xc7), "#ec3fc7")
        XCTAssertNil(RGBHex.parseHex("not-a-hex"))
    }

    func testEstimatedWatts() {
        // 10 lit LEDs, full brightness (255), pure white (#ffffff):
        // 10 * 0.06 * 5 * (255/255) * (765/765) = 3.0
        let watts = RGBHex.estimatedWatts(litCount: 10, brightness: 255, hex: "#ffffff")
        XCTAssertEqual(watts, 3.0, accuracy: 0.0001)
    }

    func testDefaultFacesDocument() throws {
        let url = Self.resourcesURL.appendingPathComponent("default_faces.json")
        let data = try TestResources.data(at: url)
        struct DefaultFacesDoc: Codable {
            let faces: [FaceEntry]
            let startupDefaultId: String

            struct FaceEntry: Codable {
                let id: String
            }
        }
        let doc = try JSONDecoder().decode(DefaultFacesDoc.self, from: data)
        XCTAssertEqual(doc.faces.count, 11)
        XCTAssertEqual(doc.startupDefaultId, "face_08_triangle_eyes_frown")
    }
}
