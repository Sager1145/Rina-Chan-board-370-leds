import Foundation

/// Real-time lip sync: microphone audio → vowel → mouth part.
///
/// Ports the 口型同步 feature of `738NGX/RinaChanBoard` (AGPL-3.0), whose
/// design doc `Documents/附录1-口型同步.md` describes the pipeline it adapted
/// from `hecomi/uLipSync` (MIT): RMS gate → low-pass → decimate → pre-emphasis
/// → Hamming → FFT → Mel filter bank → dB → DCT → MFCC → nearest calibrated
/// vowel → mode-of-history debounce. This file is that pipeline rewritten in
/// plain Swift; nothing here depends on Accelerate, AVFoundation or SwiftUI,
/// so the whole chain is unit-testable off-device.
///
/// The one place this deliberately differs from upstream: uLipSync ships baked
/// reference MFCC vectors recorded from real speakers, which we cannot lift.
/// Instead `LipSyncProfile.synthesized(preset:config:)` *generates* the
/// references at runtime from a source-filter vowel synthesizer (impulse train
/// through formant resonators), so the feature works out of the box with no
/// recorded assets, and `calibrate(_:with:)` lets a user overwrite any vowel
/// with their own voice — which is what upstream's calibration mode does too.

// MARK: - Vowels

/// The five Japanese/Chinese vowels uLipSync classifies into. Silence is
/// modelled as `nil`, not a sixth case, because it is decided by the volume
/// gate *before* any classification runs.
public enum LipSyncVowel: String, CaseIterable, Codable, Sendable, Hashable {
    case a, i, u, e, o

    /// The first three formants (Hz) for a neutral adult male vocal tract,
    /// Peterson & Barney's classic measurements. `LipSyncVoicePreset` scales
    /// these; they are only ever used to synthesize the default profile.
    var referenceFormantsHz: [Double] {
        switch self {
        case .a: return [730, 1090, 2440]
        case .i: return [270, 2290, 3010]
        case .u: return [300, 870, 2240]
        case .e: return [530, 1840, 2480]
        case .o: return [570, 840, 2410]
        }
    }
}

/// The four recognition presets upstream exposes on its 口型同步 page
/// (标准 / 男声 / 女声 / 动画). Here they are exactly what they physically are:
/// a vocal-tract length scale applied to the reference formants, plus a pitch.
/// A shorter tract (female, and shorter still for the deliberately
/// high-pitched "anime" voice) pushes every formant up.
public enum LipSyncVoicePreset: String, CaseIterable, Codable, Sendable {
    case standard, male, female, anime

    /// Multiplier applied to every reference formant frequency.
    public var formantScale: Double {
        switch self {
        case .standard: return 1.08
        case .male: return 1.00
        case .female: return 1.17
        case .anime: return 1.30
        }
    }

    /// Fundamental frequency (Hz) of the synthesized glottal source.
    public var pitchHz: Double {
        switch self {
        case .standard: return 150
        case .male: return 110
        case .female: return 200
        case .anime: return 260
        }
    }
}

// MARK: - Configuration

/// Every tunable in the pipeline. The defaults are the ones upstream's design
/// doc names; where it only says "typically", the value here is the uLipSync
/// default.
public struct LipSyncConfig: Equatable, Sendable {
    /// Everything downstream of the resampler runs at this rate. 16 kHz keeps
    /// the whole first three formants (< 3.1 kHz) well inside Nyquist while
    /// making the FFT a third the size of one at 48 kHz.
    public var targetSampleRate: Double
    /// FFT length, a power of two. 1024 samples at 16 kHz is a 64 ms window —
    /// long enough to resolve F1 (down to ~270 Hz), short enough that a vowel
    /// transition is not smeared across it.
    public var fftSize: Int
    /// Triangular Mel filters spanning `melLowHz...melHighHz`.
    public var melChannels: Int
    /// How many MFCC coefficients form the comparison vector. Coefficient 0 is
    /// dropped (it is overall loudness, not timbre), so this takes DCT outputs
    /// `1...mfccCount`.
    public var mfccCount: Int
    public var melLowHz: Double
    public var melHighHz: Double
    /// `y[n] = x[n] - p·x[n-1]`, the standard speech pre-emphasis high-pass.
    public var preEmphasis: Float
    /// Frames quieter than this are silence: the mouth closes and no vowel is
    /// classified. This is upstream's user-facing "麦克风灵敏度".
    public var minVolumeDb: Float
    /// Length of the phoneme history whose mode becomes the reported vowel.
    /// Upstream calls this the anti-flicker vote; 1 disables smoothing.
    public var historyLength: Int

    public init(targetSampleRate: Double = 16_000,
                fftSize: Int = 1024,
                melChannels: Int = 24,
                mfccCount: Int = 12,
                melLowHz: Double = 50,
                melHighHz: Double = 7_600,
                preEmphasis: Float = 0.97,
                minVolumeDb: Float = -42,
                historyLength: Int = 6) {
        self.targetSampleRate = targetSampleRate
        self.fftSize = fftSize
        self.melChannels = melChannels
        self.mfccCount = mfccCount
        self.melLowHz = melLowHz
        self.melHighHz = min(melHighHz, targetSampleRate / 2)
        self.preEmphasis = preEmphasis
        self.minVolumeDb = minVolumeDb
        self.historyLength = historyLength
    }

    public static let `default` = LipSyncConfig()
}

// MARK: - Profile

/// The reference MFCC vector per vowel that classification measures against.
///
/// Vectors are stored L2-normalized, so a distance between two of them is a
/// pure timbre comparison and does not move with how loudly the speaker said
/// the vowel.
public struct LipSyncProfile: Codable, Equatable, Sendable {
    /// Which preset (or calibration) produced this profile, for display.
    public var presetName: String
    /// Vowel raw value → normalized MFCC vector.
    public var references: [String: [Float]]
    /// Vowels whose vector came from the user's own voice rather than the
    /// synthesizer. Purely informational — the UI shows which are calibrated.
    public var calibrated: Set<String>

    public init(presetName: String, references: [String: [Float]], calibrated: Set<String> = []) {
        self.presetName = presetName
        self.references = references
        self.calibrated = calibrated
    }

    public func reference(for vowel: LipSyncVowel) -> [Float]? {
        references[vowel.rawValue]
    }

    public func isCalibrated(_ vowel: LipSyncVowel) -> Bool {
        calibrated.contains(vowel.rawValue)
    }

    /// Whether every vowel has a reference vector of the expected length.
    public func isComplete(mfccCount: Int) -> Bool {
        LipSyncVowel.allCases.allSatisfy { references[$0.rawValue]?.count == mfccCount }
    }

    /// Replaces one vowel's reference with a vector measured from real audio
    /// and marks it calibrated. The vector is normalized on the way in.
    public mutating func calibrate(_ vowel: LipSyncVowel, with mfcc: [Float]) {
        references[vowel.rawValue] = LipSyncSignal.l2Normalized(mfcc)
        calibrated.insert(vowel.rawValue)
    }

    /// Drops every user calibration and returns to the synthesized preset.
    public mutating func resetCalibration(to preset: LipSyncVoicePreset, config: LipSyncConfig) {
        self = Self.synthesized(preset: preset, config: config)
    }

    /// Builds a profile by synthesizing one second of each vowel with a
    /// source-filter model — an impulse train at the preset's pitch driving a
    /// cascade of two-pole formant resonators — and running it through the
    /// very same analysis chain live audio goes through. Deterministic, so a
    /// test can assert the five vectors are mutually distinguishable.
    public static func synthesized(preset: LipSyncVoicePreset, config: LipSyncConfig = .default) -> LipSyncProfile {
        var references: [String: [Float]] = [:]
        for vowel in LipSyncVowel.allCases {
            let formants = vowel.referenceFormantsHz.map { $0 * preset.formantScale }
            let samples = LipSyncSignal.synthesizeVowel(formantsHz: formants,
                                                        pitchHz: preset.pitchHz,
                                                        sampleRate: config.targetSampleRate,
                                                        count: config.fftSize * 2)
            // Already at the target rate, so hand it straight to the spectral
            // stage — resampling synthetic audio would only add filter ringing.
            let mfcc = LipSyncSignal.mfcc(ofResampled: samples, config: config)
            references[vowel.rawValue] = LipSyncSignal.l2Normalized(mfcc)
        }
        return LipSyncProfile(presetName: preset.rawValue, references: references)
    }
}

// MARK: - Result

public struct LipSyncResult: Equatable, Sendable {
    /// RMS of the input window in dBFS, floored at −80.
    public let volumeDb: Float
    /// The normalized MFCC vector this window produced. Empty when the window
    /// was silent (no classification was attempted).
    public let mfcc: [Float]
    /// Nearest vowel before history smoothing; nil when the window was silent.
    public let rawVowel: LipSyncVowel?
    /// The vowel to actually show: the mode of the last `historyLength` raw
    /// results. Nil means "mouth closed".
    public let vowel: LipSyncVowel?
    /// Distance from the window's MFCC to each vowel's reference (smaller is
    /// closer). Empty when silent.
    public let distances: [LipSyncVowel: Float]

    public var isSilent: Bool { rawVowel == nil }

    public static let silent = LipSyncResult(volumeDb: -80, mfcc: [], rawVowel: nil, vowel: nil, distances: [:])
}

// MARK: - Analyzer

/// Stateful across calls only in its debounce history; the DSP itself is pure.
public struct LipSyncAnalyzer: Sendable {
    public var config: LipSyncConfig
    public var profile: LipSyncProfile
    private var history: [LipSyncVowel?] = []

    public init(config: LipSyncConfig = .default, profile: LipSyncProfile? = nil) {
        self.config = config
        self.profile = profile ?? .defaultProfile(preset: .standard, config: config)
    }

    /// Forgets the debounce history, e.g. when the engine is restarted.
    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
    }

    /// Runs one analysis window. `samples` is mono float PCM at `sampleRate`;
    /// anything longer than the configured window is trimmed to its most
    /// recent `fftSize` samples (after resampling), anything shorter is
    /// zero-padded at the front.
    public mutating func analyze(_ samples: [Float], sampleRate: Double) -> LipSyncResult {
        let volumeDb = LipSyncSignal.rmsDb(samples)
        guard volumeDb >= config.minVolumeDb else {
            push(nil)
            return LipSyncResult(volumeDb: volumeDb, mfcc: [], rawVowel: nil, vowel: smoothed(), distances: [:])
        }

        let resampled = LipSyncSignal.resample(samples, from: sampleRate, to: config.targetSampleRate)
        let vector = LipSyncSignal.l2Normalized(LipSyncSignal.mfcc(ofResampled: resampled, config: config))
        guard !vector.isEmpty else {
            push(nil)
            return LipSyncResult(volumeDb: volumeDb, mfcc: [], rawVowel: nil, vowel: smoothed(), distances: [:])
        }

        let (best, distances) = classify(vector)
        push(best)
        return LipSyncResult(volumeDb: volumeDb,
                             mfcc: vector,
                             rawVowel: best,
                             vowel: smoothed(),
                             distances: distances)
    }

    /// Same as `analyze(_:sampleRate:)`, but the MFCC vector comes from a
    /// cached `LipSyncDSPEngine` instead of rebuilding every table on every
    /// call. Bit-identical to the reference path. `engine` is rebuilt in
    /// place if it was not built for `config`.
    public mutating func analyze(_ samples: [Float], sampleRate: Double, engine: inout LipSyncDSPEngine) -> LipSyncResult {
        if !engine.isBuilt(for: config) {
            engine = LipSyncDSPEngine(config: config)
        }

        let volumeDb = LipSyncSignal.rmsDb(samples)
        guard volumeDb >= config.minVolumeDb else {
            push(nil)
            return LipSyncResult(volumeDb: volumeDb, mfcc: [], rawVowel: nil, vowel: smoothed(), distances: [:])
        }

        let vector = engine.normalizedMFCC(samples, sampleRate: sampleRate)
        guard !vector.isEmpty else {
            push(nil)
            return LipSyncResult(volumeDb: volumeDb, mfcc: [], rawVowel: nil, vowel: smoothed(), distances: [:])
        }

        let (best, distances) = classify(vector)
        push(best)
        return LipSyncResult(volumeDb: volumeDb,
                             mfcc: vector,
                             rawVowel: best,
                             vowel: smoothed(),
                             distances: distances)
    }

    /// The MFCC vector for a window, without touching the debounce history.
    /// Calibration uses this: it needs the measurement, not a classification.
    public func measure(_ samples: [Float], sampleRate: Double) -> [Float] {
        let resampled = LipSyncSignal.resample(samples, from: sampleRate, to: config.targetSampleRate)
        return LipSyncSignal.l2Normalized(LipSyncSignal.mfcc(ofResampled: resampled, config: config))
    }

    /// Same as `measure(_:sampleRate:)`, but via a cached `LipSyncDSPEngine`.
    /// `engine` is rebuilt in place if it was not built for `config`.
    public func measure(_ samples: [Float], sampleRate: Double, engine: inout LipSyncDSPEngine) -> [Float] {
        if !engine.isBuilt(for: config) {
            engine = LipSyncDSPEngine(config: config)
        }
        return engine.normalizedMFCC(samples, sampleRate: sampleRate)
    }

    /// Nearest vowel to `vector` in `profile`, plus every vowel's distance —
    /// the shared classification step of both `analyze` overloads.
    private func classify(_ vector: [Float]) -> (best: LipSyncVowel?, distances: [LipSyncVowel: Float]) {
        var distances: [LipSyncVowel: Float] = [:]
        var best: LipSyncVowel?
        var bestDistance = Float.greatestFiniteMagnitude
        for vowel in LipSyncVowel.allCases {
            guard let reference = profile.reference(for: vowel), reference.count == vector.count else { continue }
            let distance = LipSyncSignal.euclideanDistance(vector, reference)
            distances[vowel] = distance
            if distance < bestDistance {
                bestDistance = distance
                best = vowel
            }
        }
        return (best, distances)
    }

    private mutating func push(_ vowel: LipSyncVowel?) {
        history.append(vowel)
        let limit = max(1, config.historyLength)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }

    /// Mode of the history. Ties go to the most recent of the tied values, so
    /// a genuinely changing vowel still moves as soon as it has the votes.
    private func smoothed() -> LipSyncVowel? {
        guard !history.isEmpty else { return nil }
        var counts: [LipSyncVowel?: Int] = [:]
        for entry in history { counts[entry, default: 0] += 1 }
        let topCount = counts.values.max() ?? 0
        for entry in history.reversed() where counts[entry] == topCount {
            return entry
        }
        return history.last ?? nil
    }
}

// MARK: - Mouth mapping

/// Which mouth part each vowel (and silence) selects.
///
/// Upstream keeps the same shape — a `faceDict` from phoneme to mouth module
/// ID, plus a dedicated "closed" entry used whenever the volume gate fires.
/// The defaults below were chosen by reading the 8×8 `preview` art in
/// `expression_parts.json`: a flat line for silence, the widest open shape for
/// あ, a wide shallow one for い, a small round one for う, a medium open one
/// for え and a tall oval for お.
public struct LipSyncMouthMapping: Codable, Equatable, Sendable {
    /// Mouth part call ID shown when the volume gate reports silence.
    public var silence: String
    /// Vowel raw value → mouth part call ID.
    public var vowels: [String: String]

    public init(silence: String, vowels: [String: String]) {
        self.silence = silence
        self.vowels = vowels
    }

    public static let `default` = LipSyncMouthMapping(
        silence: "301",
        vowels: ["a": "311", "i": "302", "u": "319", "e": "313", "o": "316"]
    )

    public func mouthId(for vowel: LipSyncVowel?) -> String {
        guard let vowel else { return silence }
        return vowels[vowel.rawValue] ?? silence
    }

    public mutating func setMouthId(_ id: String, for vowel: LipSyncVowel?) {
        if let vowel {
            vowels[vowel.rawValue] = id
        } else {
            silence = id
        }
    }

    /// Replaces any ID this parts library does not actually offer with the
    /// library's own first mouth ID, so a stale saved mapping can never
    /// compose a blank face.
    public func sanitized(against library: PartsLibrary) -> LipSyncMouthMapping {
        let available = Set(library.ids(for: .mouth))
        let fallback = library.ids(for: .mouth).first(where: { $0 != "0" }) ?? "0"
        var result = self
        if !available.contains(result.silence) { result.silence = fallback }
        for vowel in LipSyncVowel.allCases {
            let id = result.vowels[vowel.rawValue]
            if id == nil || !available.contains(id!) {
                result.vowels[vowel.rawValue] = fallback
            }
        }
        return result
    }
}

// MARK: - Signal processing

/// The DSP primitives, split out so each stage can be tested on its own.
public enum LipSyncSignal {
    // MARK: Level

    /// RMS in dBFS, floored at −80 so a digitally silent buffer stays finite.
    public static func rmsDb(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -80 }
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 1e-9 else { return -80 }
        return max(-80, Float(20 * log10(rms)))
    }

    // MARK: Rate conversion

    /// Anti-aliased rate conversion. Downsampling low-passes first (a
    /// 31-tap windowed sinc at 90 % of the destination Nyquist) and then
    /// linearly interpolates; upsampling and same-rate input skip the filter.
    public static func resample(_ samples: [Float], from source: Double, to destination: Double) -> [Float] {
        guard source > 0, destination > 0, !samples.isEmpty else { return samples }
        guard abs(source - destination) > 1 else { return samples }

        var input = samples
        if destination < source {
            let cutoff = (destination / 2 * 0.9) / source  // cycles per input sample
            input = convolve(input, lowPassKernel(cutoffCyclesPerSample: cutoff, taps: 31))
        }

        let ratio = source / destination
        let outputCount = max(1, Int(Double(input.count) / ratio))
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = input[lower] * (1 - fraction) + input[upper] * fraction
        }
        return output
    }

    /// `h[i] = 2·fc·sinc(2π·fc·(i − (N−1)/2))`, Hamming-windowed and
    /// normalized to unity gain at DC — the kernel upstream's doc specifies.
    static func lowPassKernel(cutoffCyclesPerSample cutoff: Double, taps: Int) -> [Float] {
        let n = max(3, taps | 1)  // odd, so the kernel has a true centre tap
        let centre = Double(n - 1) / 2
        var kernel = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i) - centre
            let value: Double
            if abs(x) < 1e-12 {
                value = 2 * cutoff
            } else {
                let arg = 2 * Double.pi * cutoff * x
                value = 2 * cutoff * sin(arg) / arg
            }
            let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            kernel[i] = value * window
        }
        let sum = kernel.reduce(0, +)
        guard abs(sum) > 1e-12 else { return kernel.map(Float.init) }
        return kernel.map { Float($0 / sum) }
    }

    /// Same-length ("same" mode) convolution, edges zero-padded.
    static func convolve(_ signal: [Float], _ kernel: [Float]) -> [Float] {
        guard !kernel.isEmpty else { return signal }
        let half = kernel.count / 2
        var output = [Float](repeating: 0, count: signal.count)
        for i in 0..<signal.count {
            var accumulator: Float = 0
            for k in 0..<kernel.count {
                let j = i + k - half
                guard j >= 0, j < signal.count else { continue }
                accumulator += signal[j] * kernel[k]
            }
            output[i] = accumulator
        }
        return output
    }

    // MARK: Windowing

    /// `y[n] = x[n] − p·x[n−1]`.
    public static func preEmphasized(_ samples: [Float], coefficient: Float) -> [Float] {
        guard samples.count > 1 else { return samples }
        var output = samples
        for i in stride(from: samples.count - 1, to: 0, by: -1) {
            output[i] = samples[i] - coefficient * samples[i - 1]
        }
        output[0] = samples[0] * (1 - coefficient)
        return output
    }

    /// `w(n) = 0.53836 − 0.46164·cos(2πn/(N−1))`, the exact Hamming variant
    /// upstream's doc writes out.
    public static func hammingWindow(_ count: Int) -> [Float] {
        guard count > 1 else { return [Float](repeating: 1, count: max(0, count)) }
        return (0..<count).map { n in
            Float(0.53836 - 0.46164 * cos(2 * Double.pi * Double(n) / Double(count - 1)))
        }
    }

    /// Trims to the most recent `count` samples, or front-pads with zeros.
    static func windowed(_ samples: [Float], count: Int) -> [Float] {
        if samples.count == count { return samples }
        if samples.count > count { return Array(samples.suffix(count)) }
        return [Float](repeating: 0, count: count - samples.count) + samples
    }

    // MARK: Spectrum

    /// In-place iterative radix-2 Cooley–Tukey FFT. `real`/`imaginary` must be
    /// the same power-of-two length.
    public static func fft(real: inout [Float], imaginary: inout [Float]) {
        let n = real.count
        guard n > 1, n & (n - 1) == 0, imaginary.count == n else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
            var k = n >> 1
            while k <= j {
                j -= k
                k >>= 1
            }
            j += k
        }

        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let wReal = Float(cos(angle))
            let wImaginary = Float(sin(angle))
            var start = 0
            while start < n {
                var currentReal: Float = 1
                var currentImaginary: Float = 0
                for offset in 0..<(length / 2) {
                    let a = start + offset
                    let b = a + length / 2
                    let tempReal = currentReal * real[b] - currentImaginary * imaginary[b]
                    let tempImaginary = currentReal * imaginary[b] + currentImaginary * real[b]
                    real[b] = real[a] - tempReal
                    imaginary[b] = imaginary[a] - tempImaginary
                    real[a] += tempReal
                    imaginary[a] += tempImaginary
                    let nextReal = currentReal * wReal - currentImaginary * wImaginary
                    currentImaginary = currentReal * wImaginary + currentImaginary * wReal
                    currentReal = nextReal
                }
                start += length
            }
            length <<= 1
        }
    }

    /// Magnitude spectrum, `count/2 + 1` bins.
    public static func magnitudeSpectrum(_ windowedSamples: [Float]) -> [Float] {
        var real = windowedSamples
        var imaginary = [Float](repeating: 0, count: windowedSamples.count)
        fft(real: &real, imaginary: &imaginary)
        let bins = windowedSamples.count / 2 + 1
        return (0..<bins).map { (real[$0] * real[$0] + imaginary[$0] * imaginary[$0]).squareRoot() }
    }

    // MARK: Mel

    public static func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
    public static func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

    /// `channels` triangular filters over `binCount` magnitude bins, their
    /// centres evenly spaced on the Mel scale between `lowHz` and `highHz`.
    public static func melFilterBank(channels: Int,
                                     binCount: Int,
                                     sampleRate: Double,
                                     lowHz: Double,
                                     highHz: Double) -> [[Float]] {
        guard channels > 0, binCount > 1 else { return [] }
        let lowMel = hzToMel(lowHz)
        let highMel = hzToMel(min(highHz, sampleRate / 2))
        let points = (0...(channels + 1)).map { index -> Double in
            melToHz(lowMel + (highMel - lowMel) * Double(index) / Double(channels + 1))
        }
        let binHz = sampleRate / Double((binCount - 1) * 2)
        let binOf = { (hz: Double) -> Double in hz / binHz }

        return (0..<channels).map { channel in
            let left = binOf(points[channel])
            let centre = binOf(points[channel + 1])
            let right = binOf(points[channel + 2])
            var filter = [Float](repeating: 0, count: binCount)
            for bin in 0..<binCount {
                let position = Double(bin)
                if position > left && position < centre, centre > left {
                    filter[bin] = Float((position - left) / (centre - left))
                } else if position >= centre && position < right, right > centre {
                    filter[bin] = Float((right - position) / (right - centre))
                }
            }
            return filter
        }
    }

    // MARK: DCT

    /// DCT-II: `out[k] = Σ x[n]·cos(π/N·(n+½)·k)`.
    public static func dct(_ input: [Float]) -> [Float] {
        let n = input.count
        guard n > 0 else { return [] }
        return (0..<n).map { k in
            var sum: Double = 0
            for i in 0..<n {
                sum += Double(input[i]) * cos(Double.pi / Double(n) * (Double(i) + 0.5) * Double(k))
            }
            return Float(sum)
        }
    }

    // MARK: Full MFCC chain

    /// Steps 4–10 of the pipeline, on audio that is already at
    /// `config.targetSampleRate`: window → pre-emphasis → Hamming → FFT →
    /// Mel → dB → DCT → coefficients `1...mfccCount`.
    public static func mfcc(ofResampled samples: [Float], config: LipSyncConfig) -> [Float] {
        guard config.fftSize > 1, config.mfccCount > 0 else { return [] }
        let frame = windowed(samples, count: config.fftSize)
        guard frame.contains(where: { $0 != 0 }) else { return [] }

        let emphasized = preEmphasized(frame, coefficient: config.preEmphasis)
        let window = hammingWindow(config.fftSize)
        let shaped = zip(emphasized, window).map(*)
        let spectrum = magnitudeSpectrum(shaped)

        let filters = melFilterBank(channels: config.melChannels,
                                    binCount: spectrum.count,
                                    sampleRate: config.targetSampleRate,
                                    lowHz: config.melLowHz,
                                    highHz: config.melHighHz)
        guard !filters.isEmpty else { return [] }

        let logEnergies = filters.map { filter -> Float in
            var energy: Double = 0
            for (bin, weight) in filter.enumerated() where weight != 0 {
                let magnitude = Double(spectrum[bin])
                energy += magnitude * magnitude * Double(weight)
            }
            return Float(10 * log10(max(energy, 1e-10)))
        }

        let coefficients = dct(logEnergies)
        // Coefficient 0 is the frame's overall log energy — dropping it is
        // what makes the comparison loudness-independent.
        let upper = min(config.mfccCount, max(0, coefficients.count - 1))
        guard upper > 0 else { return [] }
        return Array(coefficients[1...upper])
    }

    // MARK: Vectors

    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sum: Double = 0
        for value in vector { sum += Double(value) * Double(value) }
        let norm = sum.squareRoot()
        guard norm > 1e-9 else { return vector }
        return vector.map { Float(Double($0) / norm) }
    }

    public static func euclideanDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return .greatestFiniteMagnitude }
        var sum: Double = 0
        for index in 0..<lhs.count {
            let delta = Double(lhs[index]) - Double(rhs[index])
            sum += delta * delta
        }
        return Float(sum.squareRoot())
    }

    // MARK: Vowel synthesis (default profile)

    /// A glottal impulse train at `pitchHz` driven through one two-pole
    /// resonator per formant — the textbook source-filter model. Enough to
    /// give each vowel its own MFCC signature without shipping recordings.
    public static func synthesizeVowel(formantsHz: [Double],
                                       pitchHz: Double,
                                       sampleRate: Double,
                                       count: Int,
                                       bandwidthsHz: [Double] = [80, 90, 120]) -> [Float] {
        guard count > 0, sampleRate > 0, pitchHz > 0 else { return [] }
        let period = max(1, Int((sampleRate / pitchHz).rounded()))
        var signal = [Float](repeating: 0, count: count)
        for index in stride(from: 0, to: count, by: period) {
            signal[index] = 1
        }

        for (formantIndex, formant) in formantsHz.enumerated() {
            let bandwidth = formantIndex < bandwidthsHz.count ? bandwidthsHz[formantIndex] : bandwidthsHz.last ?? 100
            let r = exp(-Double.pi * bandwidth / sampleRate)
            let theta = 2 * Double.pi * formant / sampleRate
            let a1 = 2 * r * cos(theta)
            let a2 = -(r * r)
            var y1: Double = 0
            var y2: Double = 0
            for index in 0..<count {
                let y = Double(signal[index]) + a1 * y1 + a2 * y2
                y2 = y1
                y1 = y
                signal[index] = Float(y)
            }
        }

        let peak = signal.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1e-9 else { return signal }
        return signal.map { $0 / peak }
    }
}
