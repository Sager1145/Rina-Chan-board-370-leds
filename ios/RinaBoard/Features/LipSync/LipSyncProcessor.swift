import Foundation
import RinaCore

/// Runs the lip-sync DSP (resample → FFT → Mel → DCT → classification) off the
/// main actor. One instance per model; the model awaits at most one call at a
/// time, so results can never pile up behind a slow analysis.
actor LipSyncProcessor {
    private var analyzer: LipSyncAnalyzer

    init(config: LipSyncConfig = .default, profile: LipSyncProfile = .defaultProfile(preset: .standard)) {
        analyzer = LipSyncAnalyzer(config: config, profile: profile)
    }

    /// Replaces the config and profile and clears the debounce history, e.g.
    /// when the engine is (re)started.
    func reset(config: LipSyncConfig, profile: LipSyncProfile) {
        analyzer = LipSyncAnalyzer(config: config, profile: profile)
    }

    func analyze(_ samples: [Float], sampleRate: Double) -> LipSyncResult {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let state = RinaPerf.signposter.beginInterval("LipSyncDSP")
        defer { RinaPerf.signposter.endInterval("LipSyncDSP", state) }
        return analyzer.analyze(samples, sampleRate: sampleRate)
    }

    /// One calibration measurement: window level, plus the MFCC vector when
    /// loud enough.
    func calibrationStep(_ samples: [Float], sampleRate: Double, config: LipSyncConfig) -> (volumeDb: Float, vector: [Float]?) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let state = RinaPerf.signposter.beginInterval("LipSyncCalibrationDSP")
        defer { RinaPerf.signposter.endInterval("LipSyncCalibrationDSP", state) }

        let volumeDb = LipSyncSignal.rmsDb(samples)
        guard volumeDb >= config.minVolumeDb else { return (volumeDb, nil) }
        // A throwaway analyzer, so calibration never reconfigures the one a
        // live run's debounce history belongs to. `measure` ignores the profile.
        let vector = LipSyncAnalyzer(config: config, profile: analyzer.profile)
            .measure(samples, sampleRate: sampleRate)
        return (volumeDb, vector)
    }
}
