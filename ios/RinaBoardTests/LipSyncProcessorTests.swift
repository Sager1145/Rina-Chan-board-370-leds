import XCTest
import RinaCore
@testable import RinaBoard

final class LipSyncProcessorTests: XCTestCase {
    /// Formant sets loosely modelled on five distinct vowels, used to build a
    /// varied sequence of voiced windows. `referenceFormantsHz` is internal
    /// to RinaCore, so these are hand-picked rather than looked up.
    private static let formantSets: [[Double]] = [
        [730, 1090, 2440],   // a
        [270, 2290, 3010],   // i
        [300, 870, 2240],    // u
        [530, 1840, 2480],   // e
        [570, 840, 2410],    // o
    ]

    /// 40 windows at 48 kHz, alternating voiced vowels (cycling through the
    /// formant sets) with silence and quiet noise, so the sequence exercises
    /// both the classification path and the volume-gate silence path.
    private func makeWindows() -> [[Float]] {
        let sampleRate = 48_000.0
        let count = 3584
        var windows: [[Float]] = []
        for index in 0..<40 {
            switch index % 4 {
            case 0:
                let formants = Self.formantSets[index % Self.formantSets.count]
                windows.append(LipSyncSignal.synthesizeVowel(formantsHz: formants, pitchHz: 150,
                                                              sampleRate: sampleRate, count: count))
            case 1:
                windows.append([Float](repeating: 0, count: count))
            case 2:
                var generator = SplitMix64(seed: UInt64(index))
                windows.append((0..<count).map { _ in Float(generator.nextUnit() - 0.5) * 0.0005 })
            default:
                let formants = Self.formantSets[(index + 1) % Self.formantSets.count]
                windows.append(LipSyncSignal.synthesizeVowel(formantsHz: formants, pitchHz: 180,
                                                              sampleRate: sampleRate, count: count))
            }
        }
        return windows
    }

    func testAnalyzeMatchesADirectlyHeldAnalyzer() async {
        let config = LipSyncConfig.default
        let profile = LipSyncProfile.synthesized(preset: .standard, config: config)
        let windows = makeWindows()

        let processor = LipSyncProcessor(config: config, profile: profile)
        var referenceAnalyzer = LipSyncAnalyzer(config: config, profile: profile)

        for window in windows {
            let processorResult = await processor.analyze(window, sampleRate: 48_000)
            let referenceResult = referenceAnalyzer.analyze(window, sampleRate: 48_000)
            XCTAssertEqual(processorResult, referenceResult)
        }
    }

    func testCalibrationStepMatchesDirectMeasureAndGatesOnVolume() async {
        let config = LipSyncConfig.default
        let processor = LipSyncProcessor(config: config, profile: .defaultProfile(preset: .standard, config: config))
        let analyzer = LipSyncAnalyzer(config: config, profile: .defaultProfile(preset: .standard, config: config))

        let voiced = LipSyncSignal.synthesizeVowel(formantsHz: [730, 1090, 2440],
                                                   pitchHz: 150, sampleRate: 48_000, count: 3584)
        let voicedMeasurement = await processor.calibrationStep(voiced, sampleRate: 48_000, config: config)
        let expectedVector = analyzer.measure(voiced, sampleRate: 48_000)
        XCTAssertEqual(voicedMeasurement.vector, expectedVector)

        let silence = [Float](repeating: 0, count: 3584)
        let silentMeasurement = await processor.calibrationStep(silence, sampleRate: 48_000, config: config)
        XCTAssertNil(silentMeasurement.vector)
    }
}

/// Cheap deterministic PRNG for quiet-noise windows — no need for real
/// entropy, just non-silent, near-zero samples.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// A microphone stub that produces voiced samples so the run loop reliably
/// classifies a vowel, used by the stop-while-running lifecycle test below.
private final class VoicedMicrophone: LipSyncCapturing {
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

@MainActor
final class LipSyncProcessorStopWhileRunningTests: XCTestCase {
    func testStopWhileRunningStopsSendingAndClosesTheMouth() async throws {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        let capture = VoicedMicrophone()
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        defer { model.stop(); connection.disconnect() }

        await model.start(connection: connection)
        XCTAssertTrue(model.isRunning)

        let deadline = ContinuousClock.now + .seconds(2)
        while model.vowel == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.vowel)

        let sentBeforeStop = transport.sentCount(type: .setFrame)
        model.stop(connection: connection)

        // Wait for the closing frame itself rather than a fixed delay: under
        // load the sender task can take well over 150 ms to reach the wire.
        let closedMouth = model.frame(for: nil)
        let closeDeadline = ContinuousClock.now + .seconds(5)
        while (transport.sentCount(type: .setFrame) <= sentBeforeStop
               || lastSetFramePacked(transport) != closedMouth)
                && ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sentCountAfterStop = transport.sentCount(type: .setFrame)
        XCTAssertGreaterThan(sentCountAfterStop, sentBeforeStop, "closing frame never reached the wire")
        XCTAssertEqual(lastSetFramePacked(transport), closedMouth)

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(transport.sentCount(type: .setFrame), sentCountAfterStop,
                       "a stale analysis result was sent after stop")
        XCTAssertEqual(lastSetFramePacked(transport), closedMouth)
        XCTAssertNil(model.vowel)
    }

    /// Payload layout: 1 byte playback, 1 byte reason length L, L bytes,
    /// then 47 bytes of packed frame.
    private func lastSetFramePacked(_ transport: FakeRinaTransport) -> PackedFrame? {
        guard let frame = transport.lastSent(type: .setFrame) else { return nil }
        let payload = frame.payload
        guard payload.count > 2 else { return nil }
        let reasonLength = Int(payload[payload.startIndex.advanced(by: 1)])
        let frameStart = payload.startIndex.advanced(by: 2 + reasonLength)
        guard payload.distance(from: frameStart, to: payload.endIndex) >= 47 else { return nil }
        return PackedFrame(data: Data(payload[frameStart...]))
    }
}
