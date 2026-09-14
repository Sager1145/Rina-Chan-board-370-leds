import XCTest
@testable import RinaCore

/// Bit-identical-cross-check for `LipSyncDSPEngine` against the reference
/// `LipSyncSignal.resample` + `mfcc(ofResampled:)` + `l2Normalized` path.
final class LipSyncDSPEngineTests: XCTestCase {
    private func referenceMFCC(_ samples: [Float], sampleRate: Double, config: LipSyncConfig) -> [Float] {
        let resampled = LipSyncSignal.resample(samples, from: sampleRate, to: config.targetSampleRate)
        return LipSyncSignal.l2Normalized(LipSyncSignal.mfcc(ofResampled: resampled, config: config))
    }

    private func assertMatchesReference(_ samples: [Float],
                                        sampleRate: Double,
                                        config: LipSyncConfig = .default,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        var engine = LipSyncDSPEngine(config: config)
        let engineResult = engine.normalizedMFCC(samples, sampleRate: sampleRate)
        let referenceResult = referenceMFCC(samples, sampleRate: sampleRate, config: config)
        XCTAssertEqual(engineResult, referenceResult, "sampleRate=\(sampleRate) count=\(samples.count)", file: file, line: line)
    }

    // MARK: Synthesized vowels across rates

    func testSynthesizedVowelsAcrossRatesForEveryPreset() {
        let rates: [(Double, Int)] = [
            (48_000, 3584),
            (44_100, 3291),
            (16_000, 1536),
            (16_000.5, 1536),
            (8_000, 1024),
            (96_000, 3584),
        ]
        for preset in LipSyncVoicePreset.allCases {
            for vowel in LipSyncVowel.allCases {
                let formants = vowel.referenceFormantsHz.map { $0 * preset.formantScale }
                for (rate, count) in rates {
                    let samples = LipSyncSignal.synthesizeVowel(formantsHz: formants,
                                                                pitchHz: preset.pitchHz,
                                                                sampleRate: rate,
                                                                count: count)
                    assertMatchesReference(samples, sampleRate: rate)
                }
            }
        }
    }

    func testAllZeroWindow() {
        assertMatchesReference([Float](repeating: 0, count: 3584), sampleRate: 48_000)
        assertMatchesReference([Float](repeating: 0, count: 1536), sampleRate: 16_000)
    }

    func testSeededWhiteNoise() {
        for amplitude: Float in [1e-4, 0.01, 0.5] {
            var rng = DSPEngineTestRNG(seed: 0xC0FFEE ^ UInt64(amplitude * 1_000_000))
            let samples = (0..<3584).map { _ in Float(rng.nextUnit() * 2 - 1) * amplitude }
            assertMatchesReference(samples, sampleRate: 48_000)
        }
    }

    func testShortWindowsFrontPad() {
        var rng = DSPEngineTestRNG(seed: 42)
        let samples100 = (0..<100).map { _ in Float(rng.nextUnit() * 2 - 1) }
        let samples1000 = (0..<1000).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples100, sampleRate: 48_000)
        assertMatchesReference(samples1000, sampleRate: 48_000)
    }

    func testWindowWithTrailingZeros() {
        var rng = DSPEngineTestRNG(seed: 7)
        var samples = (0..<3584).map { _ in Float(rng.nextUnit() * 2 - 1) }
        for i in (samples.count - 200)..<samples.count { samples[i] = 0 }
        assertMatchesReference(samples, sampleRate: 48_000)
    }

    func testEmptyArray() {
        assertMatchesReference([], sampleRate: 48_000)
    }

    // MARK: Degenerate window/rate combinations

    func testSingleSampleAt48kHz() {
        var rng = DSPEngineTestRNG(seed: 11)
        let samples = [Float(rng.nextUnit() * 2 - 1)]
        assertMatchesReference(samples, sampleRate: 48_000)
    }

    func testTenSamplesSmallerThanTheKernel() {
        var rng = DSPEngineTestRNG(seed: 12)
        let samples = (0..<10).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: 48_000)
    }

    func testTwentySamplesAtAMillionHzGivesOutputCountOne() {
        var rng = DSPEngineTestRNG(seed: 13)
        let samples = (0..<20).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: 1_000_000)
    }

    func testThreeHundredSamplesAt8kHzUpsamplesAndFrontPads() {
        var rng = DSPEngineTestRNG(seed: 14)
        let samples = (0..<300).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: 8_000)
    }

    // MARK: Kernel cache invalidation across rates

    func testEngineReusedAcrossDifferentSourceRatesInSequence() {
        var engine = LipSyncDSPEngine(config: .default)
        let vowel = LipSyncVowel.a
        let rates: [(Double, Int)] = [(48_000, 3584), (44_100, 3291), (48_000, 3584), (96_000, 3584), (44_100, 3291)]
        for (rate, count) in rates {
            let samples = LipSyncSignal.synthesizeVowel(formantsHz: vowel.referenceFormantsHz,
                                                        pitchHz: 150,
                                                        sampleRate: rate,
                                                        count: count)
            let engineResult = engine.normalizedMFCC(samples, sampleRate: rate)
            let referenceResult = referenceMFCC(samples, sampleRate: rate, config: .default)
            XCTAssertEqual(engineResult, referenceResult, "rate=\(rate)")
        }
    }

    func testEngineReusedAcrossDownsampleUpsampleDownsampleSequence() {
        var engine = LipSyncDSPEngine(config: .default)
        let vowel = LipSyncVowel.e
        // 48 kHz (downsample, builds the kernel for source=48000) -> 8 kHz
        // (upsample to the 16 kHz target, no kernel use) -> 48 kHz again
        // (downsample, must still use the cached 48000 kernel correctly).
        let rates: [(Double, Int)] = [(48_000, 3584), (8_000, 1024), (48_000, 3584)]
        for (rate, count) in rates {
            let samples = LipSyncSignal.synthesizeVowel(formantsHz: vowel.referenceFormantsHz,
                                                        pitchHz: 150,
                                                        sampleRate: rate,
                                                        count: count)
            let engineResult = engine.normalizedMFCC(samples, sampleRate: rate)
            let referenceResult = referenceMFCC(samples, sampleRate: rate, config: .default)
            XCTAssertEqual(engineResult, referenceResult, "rate=\(rate)")
        }
    }

    // MARK: Non-default config

    func testNonDefaultConfig() {
        let config = LipSyncConfig(fftSize: 512, melChannels: 20, mfccCount: 10)
        let samples = LipSyncSignal.synthesizeVowel(formantsHz: LipSyncVowel.i.referenceFormantsHz,
                                                    pitchHz: 150,
                                                    sampleRate: config.targetSampleRate,
                                                    count: config.fftSize * 2)
        assertMatchesReference(samples, sampleRate: config.targetSampleRate, config: config)
        assertMatchesReference(samples, sampleRate: 48_000, config: config)
    }

    func testNonPowerOfTwoFftSize() {
        // `fft` guards `n & (n - 1) == 0` and returns early for both paths,
        // so this only exercises everything around it (windowing, Mel, DCT).
        let config = LipSyncConfig(fftSize: 1000)
        var rng = DSPEngineTestRNG(seed: 21)
        let samples = (0..<1500).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: config.targetSampleRate, config: config)
        assertMatchesReference(samples, sampleRate: 48_000, config: config)
    }

    func testFftSizeOne() {
        // `normalizedMFCC`/`mfcc(ofResampled:)` both guard `fftSize > 1` and
        // return `[]` immediately.
        let config = LipSyncConfig(fftSize: 1)
        var rng = DSPEngineTestRNG(seed: 22)
        let samples = (0..<10).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: 48_000, config: config)
    }

    func testMelChannelsZero() {
        // `melFilterBank` returns `[]` for `channels <= 0`, so both paths
        // return `[]` after the (no-op) spectrum stage.
        let config = LipSyncConfig(melChannels: 0)
        var rng = DSPEngineTestRNG(seed: 23)
        let samples = (0..<3584).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: config.targetSampleRate, config: config)
    }

    func testMelChannelsOne() {
        // `upper = min(mfccCount, max(0, n - 1))` is 0 when `n == 1`, so both
        // paths return `[]` after computing the single log-energy band.
        let config = LipSyncConfig(melChannels: 1)
        var rng = DSPEngineTestRNG(seed: 24)
        let samples = (0..<3584).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: config.targetSampleRate, config: config)
    }

    func testMfccCountGreaterThanMelChannelsMinusOne() {
        // `mfccCount` (30) exceeds `melChannels - 1` (23 at the default 24
        // channels), so `upper` clamps to 23 in both paths.
        let config = LipSyncConfig(mfccCount: 30)
        var rng = DSPEngineTestRNG(seed: 25)
        let samples = (0..<3584).map { _ in Float(rng.nextUnit() * 2 - 1) }
        assertMatchesReference(samples, sampleRate: config.targetSampleRate, config: config)
    }

    // MARK: Sequence parity through LipSyncAnalyzer

    private func mixedWindows(seed: UInt64) -> [(samples: [Float], sampleRate: Double)] {
        var rng = DSPEngineTestRNG(seed: seed)
        var windows: [(samples: [Float], sampleRate: Double)] = []
        for i in 0..<80 {
            switch i % 4 {
            case 0:
                let vowel = LipSyncVowel.allCases[i % LipSyncVowel.allCases.count]
                let samples = LipSyncSignal.synthesizeVowel(formantsHz: vowel.referenceFormantsHz,
                                                            pitchHz: 150,
                                                            sampleRate: 48_000,
                                                            count: 3584)
                windows.append((samples, 48_000))
            case 1:
                windows.append(([Float](repeating: 0, count: 3584), 48_000))
            case 2:
                let samples = (0..<3584).map { _ in Float(rng.nextUnit() * 2 - 1) * 0.3 }
                windows.append((samples, 48_000))
            default:
                let vowel = LipSyncVowel.allCases[i % LipSyncVowel.allCases.count]
                let samples = LipSyncSignal.synthesizeVowel(formantsHz: vowel.referenceFormantsHz,
                                                            pitchHz: 180,
                                                            sampleRate: 44_100,
                                                            count: 3291).map { $0 * 0.01 }
                windows.append((samples, 44_100))
            }
        }
        return windows
    }

    func testAnalyzeSequenceParityDefaultProfile() {
        let config = LipSyncConfig.default
        let profile = LipSyncProfile.defaultProfile(preset: .standard, config: config)
        var reference = LipSyncAnalyzer(config: config, profile: profile)
        var engineAnalyzer = LipSyncAnalyzer(config: config, profile: profile)
        var engine = LipSyncDSPEngine(config: config)

        for window in mixedWindows(seed: 1) {
            let referenceResult = reference.analyze(window.samples, sampleRate: window.sampleRate)
            let engineResult = engineAnalyzer.analyze(window.samples, sampleRate: window.sampleRate, engine: &engine)
            XCTAssertEqual(referenceResult, engineResult)
        }
    }

    func testAnalyzeSequenceParityCalibratedProfile() {
        let config = LipSyncConfig.default
        var profile = LipSyncProfile.defaultProfile(preset: .female, config: config)
        var rng = DSPEngineTestRNG(seed: 99)
        let calibrationSamples = (0..<3584).map { _ in Float(rng.nextUnit() * 2 - 1) * 0.4 }
        let calibrationVector = LipSyncAnalyzer(config: config, profile: profile).measure(calibrationSamples, sampleRate: 48_000)
        profile.calibrate(.a, with: calibrationVector)

        var reference = LipSyncAnalyzer(config: config, profile: profile)
        var engineAnalyzer = LipSyncAnalyzer(config: config, profile: profile)
        var engine = LipSyncDSPEngine(config: config)

        for window in mixedWindows(seed: 2) {
            let referenceResult = reference.analyze(window.samples, sampleRate: window.sampleRate)
            let engineResult = engineAnalyzer.analyze(window.samples, sampleRate: window.sampleRate, engine: &engine)
            XCTAssertEqual(referenceResult, engineResult)
        }
    }

    func testMeasureParity() {
        let config = LipSyncConfig.default
        let analyzer = LipSyncAnalyzer(config: config)
        var engine = LipSyncDSPEngine(config: config)
        for window in mixedWindows(seed: 3) {
            let referenceResult = analyzer.measure(window.samples, sampleRate: window.sampleRate)
            let engineResult = analyzer.measure(window.samples, sampleRate: window.sampleRate, engine: &engine)
            XCTAssertEqual(referenceResult, engineResult)
        }
    }

    // MARK: isBuilt(for:)

    func testIsBuiltIgnoresNonSynthesisFields() {
        let config = LipSyncConfig.default
        let engine = LipSyncDSPEngine(config: config)
        var other = config
        other.minVolumeDb = -10
        other.historyLength = 42
        XCTAssertTrue(engine.isBuilt(for: other))
    }

    func testIsBuiltFalseForEachSynthesisField() {
        let base = LipSyncConfig.default
        let engine = LipSyncDSPEngine(config: base)

        var targetSampleRate = base
        targetSampleRate.targetSampleRate = 22_050
        XCTAssertFalse(engine.isBuilt(for: targetSampleRate))

        var fftSize = base
        fftSize.fftSize = 512
        XCTAssertFalse(engine.isBuilt(for: fftSize))

        var melChannels = base
        melChannels.melChannels = 20
        XCTAssertFalse(engine.isBuilt(for: melChannels))

        var mfccCount = base
        mfccCount.mfccCount = 10
        XCTAssertFalse(engine.isBuilt(for: mfccCount))

        var melLowHz = base
        melLowHz.melLowHz = 100
        XCTAssertFalse(engine.isBuilt(for: melLowHz))

        var melHighHz = base
        melHighHz.melHighHz = 6_000
        XCTAssertFalse(engine.isBuilt(for: melHighHz))

        var preEmphasis = base
        preEmphasis.preEmphasis = 0.9
        XCTAssertFalse(engine.isBuilt(for: preEmphasis))
    }

    func testAnalyzeEngineRebuildsAndMatchesReferenceAfterConfigChange() {
        let initialConfig = LipSyncConfig.default
        let newConfig = LipSyncConfig(fftSize: 512)
        var engine = LipSyncDSPEngine(config: initialConfig)

        var reference = LipSyncAnalyzer(config: newConfig)
        var engineAnalyzer = LipSyncAnalyzer(config: newConfig)

        let samples = LipSyncSignal.synthesizeVowel(formantsHz: LipSyncVowel.o.referenceFormantsHz,
                                                    pitchHz: 150,
                                                    sampleRate: 48_000,
                                                    count: 3584)
        let referenceResult = reference.analyze(samples, sampleRate: 48_000)
        let engineResult = engineAnalyzer.analyze(samples, sampleRate: 48_000, engine: &engine)
        XCTAssertTrue(engine.isBuilt(for: newConfig))
        XCTAssertEqual(referenceResult, engineResult)
    }
}

/// Small deterministic RNG so noise tests are reproducible without importing
/// GameplayKit.
struct DSPEngineTestRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in `[0, 1)`.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
