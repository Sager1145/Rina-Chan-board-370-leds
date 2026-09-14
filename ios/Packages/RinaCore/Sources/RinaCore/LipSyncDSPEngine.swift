import Foundation

/// Precomputed tables and scratch buffers for the lip-sync MFCC chain.
///
/// `LipSyncSignal.resample` + `mfcc(ofResampled:)` + `l2Normalized` rebuild
/// their Hamming window, Mel filter bank, DCT basis and low-pass kernel on
/// every call — cheap in isolation, expensive at the rate a live analysis
/// loop calls them. This type precomputes all of that once per `LipSyncConfig`
/// and reuses scratch buffers across calls, while producing bit-identical
/// (`Float ==`) results to that reference path, operation for operation.
public struct LipSyncDSPEngine: Sendable {
    /// The config this engine was built for.
    public let config: LipSyncConfig

    /// `hammingWindow(config.fftSize)`.
    private let hamming: [Float]
    /// Per-Mel-band bin indices of the nonzero filter weights, parallel to
    /// `melWeights`.
    private let melBins: [[Int]]
    /// Per-Mel-band nonzero filter weights, parallel to `melBins`.
    private let melWeights: [[Double]]
    /// `n x n` DCT-II basis, `n = config.melChannels`, row-major by `k`.
    private let dctTable: [Double]

    /// Low-pass kernel cache: the kernel only depends on the source sample
    /// rate (destination is fixed to `config.targetSampleRate`), so it is
    /// rebuilt only when the source rate changes across calls.
    private var kernelSourceRate: Double?
    private var kernel: [Float] = []

    // Scratch buffers, reused across calls.
    private var frame: [Float]
    private var emphasized: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var spectrum: [Float]
    private var logEnergies: [Float]

    public init(config: LipSyncConfig) {
        self.config = config
        self.hamming = LipSyncSignal.hammingWindow(config.fftSize)

        let bank = LipSyncSignal.melFilterBank(channels: config.melChannels,
                                               binCount: config.fftSize / 2 + 1,
                                               sampleRate: config.targetSampleRate,
                                               lowHz: config.melLowHz,
                                               highHz: config.melHighHz)
        var bins: [[Int]] = []
        var weights: [[Double]] = []
        bins.reserveCapacity(bank.count)
        weights.reserveCapacity(bank.count)
        for filter in bank {
            var filterBins: [Int] = []
            var filterWeights: [Double] = []
            for (bin, weight) in filter.enumerated() where weight != 0 {
                filterBins.append(bin)
                filterWeights.append(Double(weight))
            }
            bins.append(filterBins)
            weights.append(filterWeights)
        }
        self.melBins = bins
        self.melWeights = weights

        let n = config.melChannels
        var table = [Double](repeating: 0, count: max(0, n * n))
        if n > 0 {
            for k in 0..<n {
                for i in 0..<n {
                    table[k * n + i] = cos(Double.pi / Double(n) * (Double(i) + 0.5) * Double(k))
                }
            }
        }
        self.dctTable = table

        self.frame = [Float](repeating: 0, count: max(0, config.fftSize))
        self.emphasized = [Float](repeating: 0, count: max(0, config.fftSize))
        self.real = [Float](repeating: 0, count: max(0, config.fftSize))
        self.imaginary = [Float](repeating: 0, count: max(0, config.fftSize))
        self.spectrum = [Float](repeating: 0, count: max(0, config.fftSize / 2 + 1))
        self.logEnergies = [Float](repeating: 0, count: max(0, config.melChannels))
    }

    /// True iff the synthesis/analysis-relevant fields of `config` match the
    /// config this engine was built for (`minVolumeDb`/`historyLength`, which
    /// affect neither synthesis nor the MFCC chain, are ignored).
    public func isBuilt(for config: LipSyncConfig) -> Bool {
        self.config.matchesSynthesisFields(of: config)
    }

    /// Normalized MFCC vector for a window of `samples` at `sampleRate`,
    /// identical to
    /// `LipSyncSignal.l2Normalized(LipSyncSignal.mfcc(ofResampled: LipSyncSignal.resample(samples, from: sampleRate, to: config.targetSampleRate), config: config))`.
    public mutating func normalizedMFCC(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard config.fftSize > 1, config.mfccCount > 0 else { return [] }
        let fftSize = config.fftSize
        let destination = config.targetSampleRate

        buildFrame(samples, sampleRate: sampleRate, destination: destination, fftSize: fftSize)

        guard frame.contains(where: { $0 != 0 }) else { return [] }

        // Pre-emphasis, computed from the original frame (matches
        // `preEmphasized`, which reads `samples` before overwriting `output`).
        if fftSize > 1 {
            for i in stride(from: fftSize - 1, to: 0, by: -1) {
                emphasized[i] = frame[i] - config.preEmphasis * frame[i - 1]
            }
            emphasized[0] = frame[0] * (1 - config.preEmphasis)
        } else {
            emphasized[0] = frame[0]
        }

        for i in 0..<fftSize {
            real[i] = emphasized[i] * hamming[i]
            imaginary[i] = 0
        }

        LipSyncSignal.fft(real: &real, imaginary: &imaginary)

        let bins = fftSize / 2 + 1
        for b in 0..<bins {
            spectrum[b] = (real[b] * real[b] + imaginary[b] * imaginary[b]).squareRoot()
        }

        guard !melBins.isEmpty else { return [] }

        let n = config.melChannels
        for c in 0..<n {
            var energy: Double = 0
            let bandBins = melBins[c]
            let bandWeights = melWeights[c]
            for i in 0..<bandBins.count {
                let magnitude = Double(spectrum[bandBins[i]])
                energy += magnitude * magnitude * bandWeights[i]
            }
            logEnergies[c] = Float(10 * log10(max(energy, 1e-10)))
        }

        var coefficients = [Float](repeating: 0, count: n)
        for k in 0..<n {
            var sum: Double = 0
            let base = k * n
            for i in 0..<n {
                sum += Double(logEnergies[i]) * dctTable[base + i]
            }
            coefficients[k] = Float(sum)
        }

        let upper = min(config.mfccCount, max(0, n - 1))
        guard upper > 0 else { return [] }
        return LipSyncSignal.l2Normalized(Array(coefficients[1...upper]))
    }

    /// Fills `frame` with the resampled window, matching `resample` +
    /// `windowed` exactly (see `LipSyncSignal.resample`/`windowed`).
    private mutating func buildFrame(_ samples: [Float], sampleRate: Double, destination: Double, fftSize: Int) {
        let source = sampleRate
        guard source > 0, destination > 0, !samples.isEmpty, abs(source - destination) > 1 else {
            windowInto(samples, fftSize: fftSize)
            return
        }

        let filtered = destination < source
        if filtered {
            ensureKernel(sourceRate: source, destination: destination)
        }

        let ratio = source / destination
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        let m = min(fftSize, outputCount)
        let zeros = fftSize - m

        if zeros > 0 {
            for i in 0..<zeros { frame[i] = 0 }
        }

        let half = kernel.count / 2
        let startIdx = outputCount - m
        for offset in 0..<m {
            let idx = startIdx + offset
            let position = Double(idx) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))

            let xLower: Float
            let xUpper: Float
            if filtered {
                xLower = convolvedSample(samples, at: lower, half: half)
                xUpper = convolvedSample(samples, at: upper, half: half)
            } else {
                xLower = samples[lower]
                xUpper = samples[upper]
            }
            frame[zeros + offset] = xLower * (1 - fraction) + xUpper * fraction
        }
    }

    /// `windowed(samples, count: fftSize)` written into `frame` in place.
    private mutating func windowInto(_ samples: [Float], fftSize: Int) {
        if samples.count == fftSize {
            for i in 0..<fftSize { frame[i] = samples[i] }
        } else if samples.count > fftSize {
            let start = samples.count - fftSize
            for i in 0..<fftSize { frame[i] = samples[start + i] }
        } else {
            let pad = fftSize - samples.count
            for i in 0..<pad { frame[i] = 0 }
            for i in 0..<samples.count { frame[pad + i] = samples[i] }
        }
    }

    /// The reference convolution at index `j`, exactly as `convolve`'s inner
    /// loop computes `output[j]`.
    private func convolvedSample(_ samples: [Float], at j: Int, half: Int) -> Float {
        var acc: Float = 0
        for k in 0..<kernel.count {
            let jj = j + k - half
            guard jj >= 0, jj < samples.count else { continue }
            acc += samples[jj] * kernel[k]
        }
        return acc
    }

    private mutating func ensureKernel(sourceRate: Double, destination: Double) {
        if kernelSourceRate == sourceRate { return }
        let cutoff = (destination / 2 * 0.9) / sourceRate
        kernel = LipSyncSignal.lowPassKernel(cutoffCyclesPerSample: cutoff, taps: 31)
        kernelSourceRate = sourceRate
    }
}
