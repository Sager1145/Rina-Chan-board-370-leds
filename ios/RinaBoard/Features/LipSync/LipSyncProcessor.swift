import Foundation
import RinaCore

/// Runs the lip-sync DSP (resample → FFT → Mel → DCT → classification) off the
/// main actor. One instance per model; the model awaits at most one call at a
/// time, so results can never pile up behind a slow analysis.
actor LipSyncProcessor {
    private var analyzer: LipSyncAnalyzer
    private var engine: LipSyncDSPEngine

    init(config: LipSyncConfig = .default, profile: LipSyncProfile = .defaultProfile(preset: .standard)) {
        analyzer = LipSyncAnalyzer(config: config, profile: profile)
        engine = LipSyncDSPEngine(config: config)
    }

    /// Replaces the config and profile and clears the debounce history, e.g.
    /// when the engine is (re)started. Rebuilds the cached DSP engine only
    /// when the new config actually differs from the one it was built for.
    func reset(config: LipSyncConfig, profile: LipSyncProfile) {
        analyzer = LipSyncAnalyzer(config: config, profile: profile)
        if !engine.isBuilt(for: config) {
            engine = LipSyncDSPEngine(config: config)
        }
    }

    func analyze(_ samples: [Float], sampleRate: Double) -> LipSyncResult {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let state = RinaPerf.signposter.beginInterval("LipSyncDSP")
        defer { RinaPerf.signposter.endInterval("LipSyncDSP", state) }
        return analyzer.analyze(samples, sampleRate: sampleRate, engine: &engine)
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
        // The shared engine rebuilds in place if `config` differs.
        let vector = LipSyncAnalyzer(config: config, profile: analyzer.profile)
            .measure(samples, sampleRate: sampleRate, engine: &engine)
        return (volumeDb, vector)
    }
}
