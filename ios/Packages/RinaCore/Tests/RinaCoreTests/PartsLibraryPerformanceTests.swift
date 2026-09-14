import XCTest
@testable import RinaCore

/// PR-10 performance gate: pre-PR-10 decode-per-call `compose`/`matchingCall`
/// vs the PR-10 cached-`Part.packedFrame` implementation. Skipped unless
/// `RINA_PERF_GATE=1`; ratio only asserted in release builds, following
/// `LipSyncDSPEnginePerformanceTests`.
final class PartsLibraryPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["RINA_PERF_GATE"] == "1" else {
            throw XCTSkip("set RINA_PERF_GATE=1 to run")
        }
    }

    static var resourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RinaBoard/Resources")
    }

    func loadLibrary() throws -> PartsLibrary? {
        let url = Self.resourcesURL.appendingPathComponent("expression_parts.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try PartsLibrary(jsonData: data)
    }

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

    private func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double) {
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }

    private func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private func interleavedTimings(iterations: Int, reference: () -> Void, fast: () -> Void) -> (reference: (p50: Double, p95: Double), fast: (p50: Double, p95: Double)) {
        for _ in 0..<5 {
            reference()
            fast()
        }
        let clock = ContinuousClock()
        var referenceSamples: [Double] = []
        var fastSamples: [Double] = []
        for _ in 0..<iterations {
            referenceSamples.append(millis(clock.measure(reference)))
            fastSamples.append(millis(clock.measure(fast)))
        }
        return (percentiles(referenceSamples), percentiles(fastSamples))
    }

    func testComposeRatio() throws {
        guard let library = try loadLibrary() else {
            throw XCTSkip("expression_parts.json not found")
        }
        let call = PartsCall(leye: "115", reye: "215", mouth: "320", cheek: "403")
        let (reference, fast) = interleavedTimings(
            iterations: 500,
            reference: { _ = self.referenceCompose(library, call: call) },
            fast: { _ = library.compose(call: call) }
        )
        let ratioP50 = fast.p50 / reference.p50
        print("[PartsLibraryBench] compose reference p50=\(String(format: "%.5f", reference.p50))ms fast p50=\(String(format: "%.5f", fast.p50))ms ratioP50=\(String(format: "%.5f", ratioP50))")
        #if !DEBUG
        XCTAssertLessThanOrEqual(fast.p50, reference.p50)
        #endif
    }

    func testMatchingCallRatio() throws {
        guard let library = try loadLibrary() else {
            throw XCTSkip("expression_parts.json not found")
        }
        let call = PartsCall(leye: "115", reye: "215", mouth: "320", cheek: "403")
        let composed = library.compose(call: call)
        let (reference, fast) = interleavedTimings(
            iterations: 200,
            reference: { _ = self.referenceMatchingCall(library, for: composed) },
            fast: { _ = library.matchingCall(for: composed) }
        )
        let ratioP50 = fast.p50 / reference.p50
        print("[PartsLibraryBench] matchingCall reference p50=\(String(format: "%.5f", reference.p50))ms fast p50=\(String(format: "%.5f", fast.p50))ms ratioP50=\(String(format: "%.5f", ratioP50))")
        #if !DEBUG
        XCTAssertLessThanOrEqual(fast.p50, reference.p50)
        #endif
    }
}
