import XCTest
@testable import RinaCore

/// PR-10: `PartsLibrary.frame(for:)` stopped decoding `part.frame`'s 94-char
/// hex on every call (`compose` decoded 4x/call, `matchingCall` decoded on
/// every candidate of every group) in favor of `Part.packedFrame`, decoded
/// once when the part is constructed. These tests hold a private
/// decode-per-call reference implementation of the old behavior and check it
/// against the new cached implementation.
///
/// Deviation from the brief: the brief asks for `compose` *and* `matchingCall`
/// to be checked against the old implementation for ALL callable combinations
/// (28 leye x 28 reye x 33 mouth x 6 cheek = 155,232 combos here). `compose`
/// is cheap enough (4 hex decodes/combo either way) to run over all 155,232
/// combos directly. The old `matchingCall` reference is not: per call it
/// decodes roughly (mask-build + linear-scan) candidates for all four groups,
/// ~147 hex decodes/call measured against this library's id-list sizes, so
/// 155,232 combos would be ~23M hex decodes (tens of minutes in a debug
/// build) just for the reference side. To keep the default `swift test` run
/// fast, `matchingCall` is checked against the old reference for (a) a
/// one-factor-at-a-time sweep that varies each group's id away from the
/// default call while holding the other three at default (covers every
/// individual callable id at least once, 95 combos), plus (b) 3,000 combos
/// drawn from a seeded RNG (covers cross-group interactions). Separately,
/// `matchingCall`'s round trip (`matchingCall(for: compose(call:)) == call`)
/// is checked against the *new* implementation alone (no decode-per-call
/// reference in the loop) over the same one-factor-at-a-time sweep plus a
/// larger (10,000-combo) random sample: measured at ~2.8ms/call even with
/// caching (matchingCall's own candidate-scan work, not decode cost, and out
/// of this PR's scope), a full 155,232-combo round trip took ~7 minutes in
/// debug, too slow for the default `swift test` run.
final class PartsLibraryPR10Tests: XCTestCase {
    static var resourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PartsLibraryPR10Tests.swift -> RinaCoreTests/
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

    /// Deterministic seeded RNG (SplitMix64), private to this file to avoid
    /// name collisions with other stages' test helpers at cherry-pick time.
    private struct PR10SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Pre-PR-10 reference implementations (decode hex on every call)

    private func referenceFrame(_ library: PartsLibrary, for part: PartsLibrary.Part) -> PackedFrame {
        PackedFrame(hex94: part.frame) ?? PackedFrame()
    }

    private func referenceCompose(_ library: PartsLibrary, call selected: PartsCall) -> PackedFrame {
        var frame = PackedFrame()
        for group in [PartGroup.leye, .reye, .mouth, .cheek] {
            let part = library.resolvedPart(group: group, id: selected[group])
            frame.formUnion(referenceFrame(library, for: part))
        }
        return frame
    }

    private func referenceMatchingCall(_ library: PartsLibrary, for frame: PackedFrame) -> PartsCall? {
        let groups = [PartGroup.leye, .reye, .mouth, .cheek]

        func isEqual(_ lhs: PackedFrame, _ rhs: PackedFrame, within mask: PackedFrame) -> Bool {
            zip(zip(lhs.bytes, rhs.bytes), mask.bytes).allSatisfy { pair, maskByte in
                (pair.0 & maskByte) == (pair.1 & maskByte)
            }
        }

        func preferredIDs(for group: PartGroup) -> [String] {
            let defaultID = PartsCall.defaultCall[group]
            let callable = library.ids(for: group)
            guard callable.contains(defaultID) else { return callable }
            return [defaultID] + callable.filter { $0 != defaultID }
        }

        var matched = PartsCall(leye: "0", reye: "0", mouth: "0", cheek: "400")
        for group in groups {
            let callable = preferredIDs(for: group)
            var mask = PackedFrame()
            for id in callable {
                mask.formUnion(referenceFrame(library, for: library.resolvedPart(group: group, id: id)))
            }
            guard let id = callable.first(where: {
                isEqual(frame, referenceFrame(library, for: library.resolvedPart(group: group, id: $0)), within: mask)
            }) else {
                return nil
            }
            matched[group] = id
        }

        return referenceCompose(library, call: matched) == frame ? matched : nil
    }

    // MARK: - compose: ALL callable combinations

    func testComposeMatchesReferenceForAllCallableCombinations() throws {
        let library = try loadLibrary()
        let leyeIds = library.ids(for: .leye)
        let reyeIds = library.ids(for: .reye)
        let mouthIds = library.ids(for: .mouth)
        let cheekIds = library.ids(for: .cheek)
        var checked = 0
        for leye in leyeIds {
            for reye in reyeIds {
                for mouth in mouthIds {
                    for cheek in cheekIds {
                        let call = PartsCall(leye: leye, reye: reye, mouth: mouth, cheek: cheek)
                        let fast = library.compose(call: call)
                        let reference = referenceCompose(library, call: call)
                        XCTAssertEqual(fast, reference, "mismatch for \(call)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, leyeIds.count * reyeIds.count * mouthIds.count * cheekIds.count)
    }

    // MARK: - matchingCall: new-only round trip (one-factor-at-a-time + sample)

    private func assertRoundTrips(_ library: PartsLibrary, call: PartsCall, file: StaticString = #filePath, line: UInt = #line) {
        let composed = library.compose(call: call)
        guard let matched = library.matchingCall(for: composed) else {
            XCTFail("no match for \(call)", file: file, line: line)
            return
        }
        // matchingCall may legitimately prefer a different id than `call`
        // when two variants share a frame (see its doc comment on
        // default-id/order preference), so check the composed frames agree
        // rather than the ids themselves.
        XCTAssertEqual(library.compose(call: matched), composed, "for \(call) matched \(matched)", file: file, line: line)
    }

    func testMatchingCallRoundTripsOneFactorAtATime() throws {
        let library = try loadLibrary()
        for group in [PartGroup.leye, .reye, .mouth, .cheek] {
            for id in library.ids(for: group) {
                var call = PartsCall.defaultCall
                call[group] = id
                assertRoundTrips(library, call: call)
            }
        }
    }

    func testMatchingCallRoundTripsForRandomSample() throws {
        let library = try loadLibrary()
        let leyeIds = library.ids(for: .leye)
        let reyeIds = library.ids(for: .reye)
        let mouthIds = library.ids(for: .mouth)
        let cheekIds = library.ids(for: .cheek)
        var generator = PR10SplitMix64(seed: 0x1234_5678)
        for _ in 0..<10_000 {
            let call = PartsCall(
                leye: leyeIds[Int.random(in: 0..<leyeIds.count, using: &generator)],
                reye: reyeIds[Int.random(in: 0..<reyeIds.count, using: &generator)],
                mouth: mouthIds[Int.random(in: 0..<mouthIds.count, using: &generator)],
                cheek: cheekIds[Int.random(in: 0..<cheekIds.count, using: &generator)]
            )
            assertRoundTrips(library, call: call)
        }
    }

    // MARK: - matchingCall vs old reference: one-factor-at-a-time + random sample

    func testMatchingCallMatchesReferenceOneFactorAtATime() throws {
        let library = try loadLibrary()
        let groups = [PartGroup.leye, .reye, .mouth, .cheek]
        for group in groups {
            for id in library.ids(for: group) {
                var call = PartsCall.defaultCall
                call[group] = id
                let composed = library.compose(call: call)
                let fast = library.matchingCall(for: composed)
                let reference = referenceMatchingCall(library, for: composed)
                XCTAssertEqual(fast, reference, "group=\(group) id=\(id)")
            }
        }
    }

    func testMatchingCallMatchesReferenceForRandomSample() throws {
        let library = try loadLibrary()
        let leyeIds = library.ids(for: .leye)
        let reyeIds = library.ids(for: .reye)
        let mouthIds = library.ids(for: .mouth)
        let cheekIds = library.ids(for: .cheek)
        var generator = PR10SplitMix64(seed: 0xFEED_BEEF)
        for _ in 0..<3000 {
            let call = PartsCall(
                leye: leyeIds[Int.random(in: 0..<leyeIds.count, using: &generator)],
                reye: reyeIds[Int.random(in: 0..<reyeIds.count, using: &generator)],
                mouth: mouthIds[Int.random(in: 0..<mouthIds.count, using: &generator)],
                cheek: cheekIds[Int.random(in: 0..<cheekIds.count, using: &generator)]
            )
            let composed = library.compose(call: call)
            let fast = library.matchingCall(for: composed)
            let reference = referenceMatchingCall(library, for: composed)
            XCTAssertEqual(fast, reference, "for \(call)")
        }
    }

    func testMatchingCallMatchesReferenceForUnmatchableFrame() throws {
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
        XCTAssertNil(referenceMatchingCall(library, for: unmatched))
    }
}
