import XCTest
@testable import RinaCore

final class LipSyncDefaultProfilesTests: XCTestCase {
    /// Not a real test: with `RINA_REGENERATE_LIPSYNC_PROFILES=1` set, prints
    /// the Swift source for `LipSyncDefaultProfileData`, generated from
    /// `LipSyncProfile.synthesized(preset:config: .default)`. Paste the
    /// printed body into `LipSyncDefaultProfiles.swift`.
    func testGenerateDefaultProfileLiterals() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RINA_REGENERATE_LIPSYNC_PROFILES"] == "1",
                          "Set RINA_REGENERATE_LIPSYNC_PROFILES=1 to print the generated source.")

        var output = "enum LipSyncDefaultProfileData {\n"
        for preset in LipSyncVoicePreset.allCases {
            let profile = LipSyncProfile.synthesized(preset: preset, config: .default)
            output += "    static let \(preset.rawValue): [String: [Float]] = [\n"
            for vowel in LipSyncVowel.allCases {
                let vector = profile.reference(for: vowel) ?? []
                let literal = vector.map { $0.description }.joined(separator: ", ")
                output += "        \"\(vowel.rawValue)\": [\(literal)],\n"
            }
            output += "    ]\n\n"
        }
        output += "}"
        print(output)
    }

    func testDefaultProfileMatchesSynthesizedForEachPreset() {
        for preset in LipSyncVoicePreset.allCases {
            let synthesized = LipSyncProfile.synthesized(preset: preset, config: .default)
            let stored = LipSyncProfile.defaultProfile(preset: preset)

            XCTAssertEqual(stored.presetName, synthesized.presetName)
            XCTAssertTrue(stored.calibrated.isEmpty)
            XCTAssertEqual(Set(stored.references.keys), Set(synthesized.references.keys))

            for vowel in LipSyncVowel.allCases {
                let storedVector = stored.reference(for: vowel) ?? []
                let synthesizedVector = synthesized.reference(for: vowel) ?? []
                XCTAssertEqual(storedVector.count, synthesizedVector.count, "\(preset)/\(vowel) length mismatch")
                for (lhs, rhs) in zip(storedVector, synthesizedVector) {
                    XCTAssertEqual(lhs, rhs, accuracy: 1e-5, "\(preset)/\(vowel) mismatch")
                }
            }
        }
    }

    func testDefaultProfileClassifiesTheSameAsSynthesized() {
        let config = LipSyncConfig.default
        for preset in LipSyncVoicePreset.allCases {
            let synthesizedProfile = LipSyncProfile.synthesized(preset: preset, config: config)
            let defaultProfile = LipSyncProfile.defaultProfile(preset: preset, config: config)

            for vowel in LipSyncVowel.allCases {
                let formants = vowel.referenceFormantsHz.map { $0 * preset.formantScale }
                let samples = LipSyncSignal.synthesizeVowel(formantsHz: formants,
                                                            pitchHz: preset.pitchHz,
                                                            sampleRate: config.targetSampleRate,
                                                            count: config.fftSize * 2)

                var synthesizedAnalyzer = LipSyncAnalyzer(config: config, profile: synthesizedProfile)
                var defaultAnalyzer = LipSyncAnalyzer(config: config, profile: defaultProfile)

                var synthesizedResult: LipSyncResult = .silent
                var defaultResult: LipSyncResult = .silent
                for _ in 0..<config.historyLength {
                    synthesizedResult = synthesizedAnalyzer.analyze(samples, sampleRate: config.targetSampleRate)
                    defaultResult = defaultAnalyzer.analyze(samples, sampleRate: config.targetSampleRate)
                }

                XCTAssertEqual(defaultResult.rawVowel, synthesizedResult.rawVowel,
                               "\(preset)/\(vowel) raw classification mismatch")
                XCTAssertEqual(defaultResult.vowel, synthesizedResult.vowel,
                               "\(preset)/\(vowel) smoothed classification mismatch")
            }
        }
    }

    func testDifferentConfigFallsBackToSynthesized() {
        var config = LipSyncConfig.default
        config.fftSize = 2048
        let fallback = LipSyncProfile.defaultProfile(preset: .standard, config: config)
        let synthesized = LipSyncProfile.synthesized(preset: .standard, config: config)
        XCTAssertEqual(fallback, synthesized)
    }

    /// Every field the synthesizer reads must force the fallback; the fields it
    /// ignores (the volume gate and the debounce length) must keep the constants.
    func testOnlySynthesisParametersForceTheFallback() {
        let constant = LipSyncProfile.defaultProfile(preset: .female)

        var gateOnly = LipSyncConfig.default
        gateOnly.minVolumeDb = -20
        gateOnly.historyLength = 2
        XCTAssertEqual(LipSyncProfile.defaultProfile(preset: .female, config: gateOnly), constant)

        let variants: [(String, (inout LipSyncConfig) -> Void)] = [
            ("targetSampleRate", { $0.targetSampleRate = 22_050 }),
            ("fftSize", { $0.fftSize = 512 }),
            ("melChannels", { $0.melChannels = 20 }),
            ("mfccCount", { $0.mfccCount = 10 }),
            ("melLowHz", { $0.melLowHz = 80 }),
            ("melHighHz", { $0.melHighHz = 6_000 }),
            ("preEmphasis", { $0.preEmphasis = 0.9 }),
        ]
        for (name, mutate) in variants {
            var config = LipSyncConfig.default
            mutate(&config)
            let resolved = LipSyncProfile.defaultProfile(preset: .female, config: config)
            XCTAssertEqual(resolved, LipSyncProfile.synthesized(preset: .female, config: config), name)
            XCTAssertNotEqual(resolved, constant, "\(name) change still returned the precomputed constants")
        }
    }
}
