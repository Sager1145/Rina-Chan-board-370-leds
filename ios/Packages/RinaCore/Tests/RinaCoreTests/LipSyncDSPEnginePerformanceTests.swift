import XCTest
@testable import RinaCore

/// PR-3 performance gate: reference (rebuild-everything) `LipSyncAnalyzer`
/// path vs the cached `LipSyncDSPEngine` path. Skipped unless
/// `RINA_PERF_GATE=1`, and only asserts a speed ratio in release builds,
/// since debug builds are dominated by bounds-check/ARC overhead that a
/// cache does not change proportionally.
final class LipSyncDSPEnginePerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["RINA_PERF_GATE"] == "1" else {
            throw XCTSkip("set RINA_PERF_GATE=1 to run")
        }
    }

    private func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double) {
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        return (p50, sorted[p95Index])
    }

    /// Times `reference` and `engine` interleaved, one call of each per
    /// iteration on the same input, so a scheduler hiccup lands in both
    /// samples rather than skewing whichever block happened to run second.
    private func interleavedTimings(iterations: Int,
                                    reference: () -> Void,
                                    engine: () -> Void) -> (reference: (p50: Double, p95: Double), engine: (p50: Double, p95: Double)) {
        for _ in 0..<5 {
            reference()
            engine()
        }
        let clock = ContinuousClock()
        var referenceSamples: [Double] = []
        var engineSamples: [Double] = []
        referenceSamples.reserveCapacity(iterations)
        engineSamples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            referenceSamples.append(millis(clock.measure(reference)))
            engineSamples.append(millis(clock.measure(engine)))
        }
        return (percentiles(referenceSamples), percentiles(engineSamples))
    }

    private func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private static let windowSampleCount = LipSyncConfig.default.fftSize * 3 + 512

    private static let voicedWindow: [Float] = LipSyncSignal.synthesizeVowel(
        formantsHz: [730, 1090, 2440],
        pitchHz: 150,
        sampleRate: 48_000,
        count: windowSampleCount
    ).map { $0 * 0.5 }

    func testAnalyzeVoicedWindowRatio() {
        let samples = Self.voicedWindow
        var reference = LipSyncAnalyzer()
        var engineAnalyzer = LipSyncAnalyzer()
        var engine = LipSyncDSPEngine(config: engineAnalyzer.config)

        let (referenceResult, engineResult) = interleavedTimings(
            iterations: 200,
            reference: { _ = reference.analyze(samples, sampleRate: 48_000) },
            engine: { _ = engineAnalyzer.analyze(samples, sampleRate: 48_000, engine: &engine) }
        )

        let ratioP95 = engineResult.p95 / referenceResult.p95
        print("[DSPEngineBench] analyze-voiced reference p50=\(String(format: "%.4f", referenceResult.p50)) p95=\(String(format: "%.4f", referenceResult.p95)) engine p50=\(String(format: "%.4f", engineResult.p50)) p95=\(String(format: "%.4f", engineResult.p95)) ratioP95=\(String(format: "%.4f", ratioP95))")

        #if !DEBUG
        XCTAssertLessThanOrEqual(engineResult.p50, 0.65 * referenceResult.p50)
        #endif
    }

    func testMeasureVoicedWindowRatio() {
        let samples = Self.voicedWindow
        let reference = LipSyncAnalyzer()
        let engineAnalyzer = LipSyncAnalyzer()
        var engine = LipSyncDSPEngine(config: engineAnalyzer.config)

        let (referenceResult, engineResult) = interleavedTimings(
            iterations: 200,
            reference: { _ = reference.measure(samples, sampleRate: 48_000) },
            engine: { _ = engineAnalyzer.measure(samples, sampleRate: 48_000, engine: &engine) }
        )

        print("[DSPEngineBench] measure-voiced reference p50=\(String(format: "%.4f", referenceResult.p50)) p95=\(String(format: "%.4f", referenceResult.p95)) engine p50=\(String(format: "%.4f", engineResult.p50)) p95=\(String(format: "%.4f", engineResult.p95)) ratioP95=\(String(format: "%.4f", engineResult.p95 / referenceResult.p95))")
    }
}
