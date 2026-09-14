import XCTest
@testable import RinaCore

/// PR-0 performance baseline: measures the CURRENT (unoptimized)
/// `LipSyncAnalyzer` / `LipSyncProfile` cost. No optimizations, no timing
/// asserts — the printed lines are the artifact for later comparison.
final class LipSyncPerformanceTests: XCTestCase {
    /// Returns (p50, p95) in milliseconds from `iterations` runs of `body`,
    /// after 5 untimed warm-up runs.
    private func timings(iterations: Int, _ body: () -> Void) -> (p50: Double, p95: Double) {
        for _ in 0..<5 { body() }
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let elapsed = clock.measure { body() }
            samples.append(millis(elapsed))
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95Index = min(samples.count - 1, Int(Double(samples.count) * 0.95))
        return (p50, samples[p95Index])
    }

    private func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private func report(_ name: String, _ result: (p50: Double, p95: Double)) {
        print("[LipSyncBench] \(name) p50=\(String(format: "%.4f", result.p50)) p95=\(String(format: "%.4f", result.p95))")
    }

    /// The model's own window: `fftSize * 3 + 512` at 48 kHz, per the
    /// analysis loop's currentWindow() sizing.
    private static let windowSampleCount = LipSyncConfig.default.fftSize * 3 + 512

    func testAnalyzeVoicedWindow() {
        let samples = LipSyncSignal.synthesizeVowel(formantsHz: [730, 1090, 2440],
                                                      pitchHz: 150,
                                                      sampleRate: 48_000,
                                                      count: Self.windowSampleCount).map { $0 * 0.5 }
        var analyzer = LipSyncAnalyzer()
        let result = timings(iterations: 200) {
            _ = analyzer.analyze(samples, sampleRate: 48_000)
        }
        report("analyze-voiced", result)
    }

    func testAnalyzeSilentWindow() {
        let samples = [Float](repeating: 0, count: Self.windowSampleCount)
        var analyzer = LipSyncAnalyzer()
        let result = timings(iterations: 200) {
            _ = analyzer.analyze(samples, sampleRate: 48_000)
        }
        report("analyze-silent", result)
    }

    func testMeasureVoicedWindow() {
        let samples = LipSyncSignal.synthesizeVowel(formantsHz: [730, 1090, 2440],
                                                      pitchHz: 150,
                                                      sampleRate: 48_000,
                                                      count: Self.windowSampleCount).map { $0 * 0.5 }
        let analyzer = LipSyncAnalyzer()
        let result = timings(iterations: 200) {
            _ = analyzer.measure(samples, sampleRate: 48_000)
        }
        report("measure-voiced", result)
    }

    func testSynthesizedProfilePerPreset() {
        for preset in LipSyncVoicePreset.allCases {
            let result = timings(iterations: 20) {
                _ = LipSyncProfile.synthesized(preset: preset)
            }
            report("synthesized-\(preset.rawValue)", result)
        }
    }
}
