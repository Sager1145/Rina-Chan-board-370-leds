import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// PR-0 performance baseline: how long `LipSyncModel` init takes when it must
/// synthesize a fresh profile versus when a profile is already stored. No
/// optimizations here, no timing asserts — the printed line is the artifact.
@MainActor
final class LipSyncModelInitBenchmarkTests: XCTestCase {
    func testInitTimingFreshVersusStoredProfile() throws {
        let freshSuite = "LipSyncInitBench-fresh-\(UUID().uuidString)"
        let storedSuite = "LipSyncInitBench-stored-\(UUID().uuidString)"
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: freshSuite))
        let storedDefaults = try XCTUnwrap(UserDefaults(suiteName: storedSuite))
        defer {
            freshDefaults.removePersistentDomain(forName: freshSuite)
            storedDefaults.removePersistentDomain(forName: storedSuite)
        }

        // Make sure the "stored" suite actually has a persisted profile,
        // whichever way it gets there.
        if storedDefaults.data(forKey: "lipSyncProfile") == nil {
            let encoded = try JSONEncoder().encode(LipSyncProfile.synthesized(preset: .standard))
            storedDefaults.set(encoded, forKey: "lipSyncProfile")
        }

        let clock = ContinuousClock()

        var freshTimings: [Duration] = []
        for _ in 0..<10 {
            let suite = "LipSyncInitBench-fresh-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let elapsed = clock.measure {
                _ = LipSyncModel(defaults: defaults, capture: BenchMicrophone(), permissionRequest: { .granted })
            }
            freshTimings.append(elapsed)
        }

        var storedTimings: [Duration] = []
        for _ in 0..<10 {
            let elapsed = clock.measure {
                _ = LipSyncModel(defaults: storedDefaults, capture: BenchMicrophone(), permissionRequest: { .granted })
            }
            storedTimings.append(elapsed)
        }

        let freshMs = freshTimings.map(millis)
        let storedMs = storedTimings.map(millis)

        print("[LipSyncInitBench] fresh p50=\(String(format: "%.3f", percentile50(freshMs))) " +
              "max=\(String(format: "%.3f", freshMs.max() ?? 0)) " +
              "stored p50=\(String(format: "%.3f", percentile50(storedMs))) " +
              "max=\(String(format: "%.3f", storedMs.max() ?? 0))")
    }

    private func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private func percentile50(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

private final class BenchMicrophone: LipSyncCapturing {
    var startCount = 0
    var running = false
    var isRunning: Bool { running }
    let currentSampleRate: Double = 16_000
    var samples = LipSyncSignal.synthesizeVowel(
        formantsHz: [800, 1200, 2500], pitchHz: 140, sampleRate: 16_000, count: 4096)

    @MainActor func start() async throws {
        startCount += 1
        running = true
    }

    func stop() { running = false }

    func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double) {
        (running ? Array(samples.suffix(count)) : [], currentSampleRate)
    }
}
