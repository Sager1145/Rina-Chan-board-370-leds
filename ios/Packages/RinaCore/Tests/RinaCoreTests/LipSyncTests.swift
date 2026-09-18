import XCTest
@testable import RinaCore

final class LipSyncTests: XCTestCase {
    static var resourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LipSyncTests.swift -> RinaCoreTests/
            .deletingLastPathComponent() // RinaCoreTests -> Tests/
            .deletingLastPathComponent() // Tests -> RinaCore/ (package root)
            .deletingLastPathComponent() // RinaCore -> Packages/
            .deletingLastPathComponent() // Packages -> ios/
            .appendingPathComponent("RinaBoard/Resources")
    }

    private func loadLibrary() throws -> PartsLibrary {
        let url = Self.resourcesURL.appendingPathComponent("expression_parts.json")
        let data = try TestResources.data(at: url)
        return try PartsLibrary(jsonData: data)
    }

    // MARK: Level gate

    func testRmsDbFloorsSilence() {
        XCTAssertEqual(LipSyncSignal.rmsDb([Float](repeating: 0, count: 512)), -80)
        XCTAssertEqual(LipSyncSignal.rmsDb([]), -80)
    }

    func testRmsDbOfFullScaleSquareWaveIsZero() {
        let samples = (0..<512).map { Float($0 % 2 == 0 ? 1 : -1) }
        XCTAssertEqual(LipSyncSignal.rmsDb(samples), 0, accuracy: 0.001)
    }

    func testRmsDbDropsSixDbPerHalving() {
        let loud = (0..<512).map { Float($0 % 2 == 0 ? 1 : -1) }
        let quiet = loud.map { $0 / 2 }
        XCTAssertEqual(LipSyncSignal.rmsDb(loud) - LipSyncSignal.rmsDb(quiet), 6.0206, accuracy: 0.01)
    }

    // MARK: FFT

    func testFftOfDcIsAllEnergyInBinZero() {
        var real = [Float](repeating: 1, count: 64)
        var imaginary = [Float](repeating: 0, count: 64)
        LipSyncSignal.fft(real: &real, imaginary: &imaginary)
        XCTAssertEqual(real[0], 64, accuracy: 0.001)
        for bin in 1..<64 {
            XCTAssertEqual(real[bin], 0, accuracy: 0.001)
            XCTAssertEqual(imaginary[bin], 0, accuracy: 0.001)
        }
    }

    func testMagnitudeSpectrumPeaksAtTheSineBin() {
        let n = 256
        let bin = 20
        let samples = (0..<n).map { Float(sin(2 * Double.pi * Double(bin) * Double($0) / Double(n))) }
        let spectrum = LipSyncSignal.magnitudeSpectrum(samples)
        XCTAssertEqual(spectrum.count, n / 2 + 1)
        let peak = spectrum.enumerated().max(by: { $0.element < $1.element })?.offset
        XCTAssertEqual(peak, bin)
    }

    // MARK: Mel

    func testMelScaleRoundTrips() {
        for hz in [50.0, 440.0, 1000.0, 4000.0, 7600.0] {
            XCTAssertEqual(LipSyncSignal.melToHz(LipSyncSignal.hzToMel(hz)), hz, accuracy: 0.01)
        }
    }

    func testMelFilterBankShapeAndOrdering() {
        let filters = LipSyncSignal.melFilterBank(channels: 24,
                                                  binCount: 513,
                                                  sampleRate: 16_000,
                                                  lowHz: 50,
                                                  highHz: 7_600)
        XCTAssertEqual(filters.count, 24)
        for filter in filters {
            XCTAssertEqual(filter.count, 513)
            XCTAssertTrue(filter.contains { $0 > 0 }, "every Mel filter must cover at least one bin")
            XCTAssertFalse(filter.contains { $0 < 0 || $0 > 1.0001 })
        }
        // Centres must climb monotonically up the spectrum.
        let centres = filters.map { filter in filter.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0 }
        XCTAssertEqual(centres, centres.sorted())
    }

    // MARK: DCT

    func testDctOfConstantPutsEnergyInCoefficientZero() {
        let output = LipSyncSignal.dct([Float](repeating: 3, count: 16))
        XCTAssertEqual(output[0], 48, accuracy: 0.001)
        for k in 1..<16 {
            XCTAssertEqual(output[k], 0, accuracy: 0.001)
        }
    }

    // MARK: Resampling

    func testResampleHalvesTheSampleCount() {
        let input = (0..<480).map { Float(sin(2 * Double.pi * 100 * Double($0) / 48_000)) }
        let output = LipSyncSignal.resample(input, from: 48_000, to: 16_000)
        XCTAssertEqual(output.count, 160)
    }

    func testResampleIsIdentityAtTheSameRate() {
        let input: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(LipSyncSignal.resample(input, from: 16_000, to: 16_000), input)
    }

    func testResamplePreservesAnInBandTone() {
        // A 440 Hz tone is far below the 8 kHz destination Nyquist, so
        // decimating must not eat its amplitude.
        let input = (0..<4800).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let output = LipSyncSignal.resample(input, from: 48_000, to: 16_000)
        // Skip the zero-padded convolution edges.
        let interior = Array(output[20..<(output.count - 20)])
        let peak = interior.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertEqual(peak, 1, accuracy: 0.1)
    }

    func testLowPassKernelHasUnityDcGain() {
        let kernel = LipSyncSignal.lowPassKernel(cutoffCyclesPerSample: 0.15, taps: 31)
        XCTAssertEqual(kernel.count, 31)
        XCTAssertEqual(kernel.reduce(0, +), 1, accuracy: 0.0001)
    }

    // MARK: Windowing

    func testHammingWindowEndpointsAndSymmetry() {
        let window = LipSyncSignal.hammingWindow(64)
        XCTAssertEqual(window.first!, 0.07672, accuracy: 0.0001)
        XCTAssertEqual(window.first!, window.last!, accuracy: 0.0001)
        XCTAssertEqual(window[31], window[32], accuracy: 0.0001)
    }

    func testPreEmphasisRemovesDc() {
        let dc = [Float](repeating: 1, count: 16)
        let output = LipSyncSignal.preEmphasized(dc, coefficient: 0.97)
        for value in output.dropFirst() {
            XCTAssertEqual(value, 0.03, accuracy: 0.0001)
        }
    }

    func testWindowedTrimsToTheMostRecentSamplesAndFrontPads() {
        XCTAssertEqual(LipSyncSignal.windowed([1, 2, 3, 4], count: 2), [3, 4])
        XCTAssertEqual(LipSyncSignal.windowed([1, 2], count: 4), [0, 0, 1, 2])
        XCTAssertEqual(LipSyncSignal.windowed([1, 2], count: 2), [1, 2])
    }

    // MARK: Profile

    func testSynthesizedProfileIsCompleteForEveryPreset() {
        let config = LipSyncConfig.default
        for preset in LipSyncVoicePreset.allCases {
            let profile = LipSyncProfile.synthesized(preset: preset, config: config)
            XCTAssertTrue(profile.isComplete(mfccCount: config.mfccCount), "\(preset) profile is incomplete")
            XCTAssertTrue(profile.calibrated.isEmpty)
            for vowel in LipSyncVowel.allCases {
                let vector = profile.reference(for: vowel)!
                let norm = vector.reduce(Double(0)) { $0 + Double($1) * Double($1) }.squareRoot()
                XCTAssertEqual(norm, 1, accuracy: 0.0001, "\(preset)/\(vowel) reference is not normalized")
            }
        }
    }

    func testSynthesizedVowelsAreMutuallyDistinguishable() {
        // The whole feature rests on this: five references that a nearest
        // neighbour search can actually tell apart.
        let profile = LipSyncProfile.synthesized(preset: .standard)
        for lhs in LipSyncVowel.allCases {
            for rhs in LipSyncVowel.allCases where rhs != lhs {
                let distance = LipSyncSignal.euclideanDistance(profile.reference(for: lhs)!,
                                                               profile.reference(for: rhs)!)
                XCTAssertGreaterThan(distance, 0.15, "\(lhs) and \(rhs) references are too close")
            }
        }
    }

    func testSynthesizedVowelIsClassifiedAsItself() {
        // Feed the analyzer the very waveform the profile was built from: each
        // vowel must come back as itself, at the configured rate and at 48 kHz.
        let config = LipSyncConfig.default
        let preset = LipSyncVoicePreset.standard
        for vowel in LipSyncVowel.allCases {
            let formants = vowel.referenceFormantsHz.map { $0 * preset.formantScale }
            for rate in [config.targetSampleRate, 48_000] {
                let samples = LipSyncSignal.synthesizeVowel(formantsHz: formants,
                                                            pitchHz: preset.pitchHz,
                                                            sampleRate: rate,
                                                            count: Int(rate * 0.2))
                var analyzer = LipSyncAnalyzer(config: config,
                                               profile: .synthesized(preset: preset, config: config))
                var last: LipSyncResult = .silent
                for _ in 0..<config.historyLength {
                    last = analyzer.analyze(samples, sampleRate: rate)
                }
                XCTAssertEqual(last.rawVowel, vowel, "\(vowel) misclassified at \(rate) Hz")
                XCTAssertEqual(last.vowel, vowel, "\(vowel) did not survive smoothing at \(rate) Hz")
                XCTAssertFalse(last.isSilent)
                XCTAssertEqual(last.distances.count, LipSyncVowel.allCases.count)
            }
        }
    }

    func testVowelsSurviveAPitchThatTheProfileWasNotBuiltAt() {
        // The profile for `.standard` is synthesized at 150 Hz. A real speaker
        // never matches that, and at 1024 points / 16 kHz the low Mel filters
        // are comparable in width to the harmonic spacing, so the MFCC can
        // partly encode f0 rather than the formant envelope. This pins down
        // how much headroom the nearest-neighbour search actually has: the
        // same vowels, voiced well off the profile's pitch, must still land on
        // themselves.
        let config = LipSyncConfig.default
        let preset = LipSyncVoicePreset.standard
        let profile = LipSyncProfile.synthesized(preset: preset, config: config)

        for pitch in [110.0, 190.0, 240.0] {
            for vowel in LipSyncVowel.allCases {
                let formants = vowel.referenceFormantsHz.map { $0 * preset.formantScale }
                let samples = LipSyncSignal.synthesizeVowel(formantsHz: formants,
                                                            pitchHz: pitch,
                                                            sampleRate: config.targetSampleRate,
                                                            count: config.fftSize * 2)
                var analyzer = LipSyncAnalyzer(config: config, profile: profile)
                let result = analyzer.analyze(samples, sampleRate: config.targetSampleRate)
                XCTAssertEqual(result.rawVowel, vowel,
                               "\(vowel) at \(pitch) Hz was heard as \(String(describing: result.rawVowel))")
            }
        }
    }

    func testCalibrationOverwritesAndMarksAVowel() {
        var profile = LipSyncProfile.synthesized(preset: .standard)
        let before = profile.reference(for: .a)!
        profile.calibrate(.a, with: [Float](repeating: 2, count: before.count))
        XCTAssertTrue(profile.isCalibrated(.a))
        XCTAssertFalse(profile.isCalibrated(.i))
        let after = profile.reference(for: .a)!
        XCTAssertNotEqual(after, before)
        let norm = after.reduce(Double(0)) { $0 + Double($1) * Double($1) }.squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 0.0001, "a calibrated vector must be normalized too")
    }

    func testResetCalibrationReturnsToTheSynthesizedPreset() {
        var profile = LipSyncProfile.synthesized(preset: .standard)
        profile.calibrate(.a, with: [Float](repeating: 2, count: LipSyncConfig.default.mfccCount))
        profile.resetCalibration(to: .female, config: .default)
        XCTAssertTrue(profile.calibrated.isEmpty)
        XCTAssertEqual(profile, LipSyncProfile.synthesized(preset: .female, config: .default))
    }

    func testProfileRoundTripsThroughJSON() throws {
        let profile = LipSyncProfile.synthesized(preset: .anime)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(LipSyncProfile.self, from: data), profile)
    }

    // MARK: Analyzer

    func testSilenceIsGatedBeforeClassification() {
        var analyzer = LipSyncAnalyzer()
        let result = analyzer.analyze([Float](repeating: 0, count: 2048), sampleRate: 16_000)
        XCTAssertTrue(result.isSilent)
        XCTAssertNil(result.vowel)
        XCTAssertTrue(result.mfcc.isEmpty)
        XCTAssertTrue(result.distances.isEmpty)
        XCTAssertEqual(result.volumeDb, -80)
    }

    func testAudioBelowTheSensitivityThresholdCountsAsSilence() {
        var config = LipSyncConfig.default
        config.minVolumeDb = -10  // deliberately harsh
        var analyzer = LipSyncAnalyzer(config: config)
        let quiet = LipSyncSignal.synthesizeVowel(formantsHz: LipSyncVowel.a.referenceFormantsHz,
                                                  pitchHz: 150,
                                                  sampleRate: 16_000,
                                                  count: 2048).map { $0 * 0.01 }
        XCTAssertTrue(analyzer.analyze(quiet, sampleRate: 16_000).isSilent)
    }

    func testHistorySmoothingRejectsASingleOutlier() {
        var analyzer = LipSyncAnalyzer()  // historyLength 6
        let a = LipSyncSignal.synthesizeVowel(formantsHz: LipSyncVowel.a.referenceFormantsHz.map { $0 * 1.08 },
                                              pitchHz: 150, sampleRate: 16_000, count: 2048)
        let i = LipSyncSignal.synthesizeVowel(formantsHz: LipSyncVowel.i.referenceFormantsHz.map { $0 * 1.08 },
                                              pitchHz: 150, sampleRate: 16_000, count: 2048)
        for _ in 0..<5 { _ = analyzer.analyze(a, sampleRate: 16_000) }
        let outlier = analyzer.analyze(i, sampleRate: 16_000)
        XCTAssertEqual(outlier.rawVowel, .i, "the raw read-out must still report what it heard")
        XCTAssertEqual(outlier.vowel, .a, "one stray frame must not flip the mouth")
    }

    func testResetClearsTheHistory() {
        var analyzer = LipSyncAnalyzer()
        let a = LipSyncSignal.synthesizeVowel(formantsHz: LipSyncVowel.a.referenceFormantsHz.map { $0 * 1.08 },
                                              pitchHz: 150, sampleRate: 16_000, count: 2048)
        for _ in 0..<6 { _ = analyzer.analyze(a, sampleRate: 16_000) }
        analyzer.reset()
        let afterReset = analyzer.analyze([Float](repeating: 0, count: 2048), sampleRate: 16_000)
        XCTAssertNil(afterReset.vowel, "a cleared history must not keep voting for the old vowel")
    }

    func testMeasureDoesNotDisturbTheHistory() {
        var analyzer = LipSyncAnalyzer()
        let a = LipSyncSignal.synthesizeVowel(formantsHz: LipSyncVowel.a.referenceFormantsHz.map { $0 * 1.08 },
                                              pitchHz: 150, sampleRate: 16_000, count: 2048)
        for _ in 0..<6 { _ = analyzer.analyze(a, sampleRate: 16_000) }
        let vector = analyzer.measure(a, sampleRate: 16_000)
        XCTAssertEqual(vector.count, LipSyncConfig.default.mfccCount)
        let next = analyzer.analyze(a, sampleRate: 16_000)
        XCTAssertEqual(next.vowel, .a)
    }

    // MARK: Mouth mapping

    func testDefaultMouthMappingUsesDistinctRealParts() throws {
        let library = try loadLibrary()
        let mapping = LipSyncMouthMapping.default
        let available = Set(library.ids(for: .mouth))
        XCTAssertTrue(available.contains(mapping.silence))
        var used: Set<String> = [mapping.silence]
        for vowel in LipSyncVowel.allCases {
            let id = mapping.mouthId(for: vowel)
            XCTAssertTrue(available.contains(id), "mouth \(id) for \(vowel) is not in expression_parts.json")
            XCTAssertTrue(used.insert(id).inserted, "\(vowel) reuses mouth \(id)")
        }
        XCTAssertEqual(mapping.mouthId(for: nil), mapping.silence)
    }

    func testSanitizingReplacesUnknownMouthIds() throws {
        let library = try loadLibrary()
        var mapping = LipSyncMouthMapping.default
        mapping.setMouthId("999", for: .a)
        mapping.setMouthId("nope", for: nil)
        let sanitized = mapping.sanitized(against: library)
        let available = Set(library.ids(for: .mouth))
        XCTAssertTrue(available.contains(sanitized.mouthId(for: .a)))
        XCTAssertTrue(available.contains(sanitized.silence))
        XCTAssertEqual(sanitized.mouthId(for: .i), mapping.mouthId(for: .i), "valid entries must be left alone")
    }

    func testMouthMappingRoundTripsThroughJSON() throws {
        let mapping = LipSyncMouthMapping.default
        let data = try JSONEncoder().encode(mapping)
        XCTAssertEqual(try JSONDecoder().decode(LipSyncMouthMapping.self, from: data), mapping)
    }
}
