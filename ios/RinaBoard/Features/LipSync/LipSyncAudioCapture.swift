import AVFoundation
import Foundation
import RinaCore

protocol LipSyncCapturing: AnyObject {
    @MainActor func start() async throws
    func stop()
    var isRunning: Bool { get }
    var currentSampleRate: Double { get }
    func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double)
}

/// Microphone capture for the 口型同步 tab: an `AVAudioEngine` input tap
/// feeding a small ring buffer that the analysis loop samples on its own
/// clock.
///
/// The tap fires on a real-time audio thread whose only job is to copy floats
/// into a fixed-capacity ring allocated once when this capture object is
/// created — no allocation, no reallocation, no memmove on the hot path, no
/// actor hops. The MFCC work
/// happens on the main actor at the model's refresh rate, reading whatever the
/// most recent window happens to be. Dropping audio between two analysis
/// windows is correct here: lip sync wants *the current mouth shape*, not a
/// gapless recording, so a late window is worth more than a queued old one.
///
/// `@unchecked Sendable` because the ring is guarded by an explicit lock; the
/// audio tap and readers share the ring lock; engine lifecycle mutations run
/// exclusively on AudioSessionWork.queue.
final class LipSyncAudioCapture: LipSyncCapturing, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noInputAvailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return NSLocalizedString("需要麦克风权限才能进行口型同步", comment: "microphone permission denied")
            case .noInputAvailable:
                return NSLocalizedString("找不到可用的麦克风输入", comment: "no audio input available")
            }
        }
    }

    /// Roughly a quarter second at 48 kHz. Anything older than that can never
    /// be part of a current mouth shape.
    private static let ringCapacity = 12_288

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring = LipSyncSampleRing(capacity: LipSyncAudioCapture.ringCapacity)
    private var captureSampleRate: Double = 48_000
    private var hasInstalledTap = false
    private var receivedFrames = 0
    private var lastDiagnosticTime = Date.distantPast
    var isRunning: Bool {
        lock.lock()
        let active = running
        lock.unlock()
        // The render callback also needs this lock. Never hold it while
        // entering the engine, which has its own render synchronization.
        return active && engine.isRunning
    }
    private var running = false


    // MARK: Permission

    /// The three states iOS reports for microphone access.
    enum Permission {
        case undetermined, granted, denied
    }

    static var permission: Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    static func requestPermission() async -> Permission {
        if case .granted = permission { return .granted }
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .granted : .denied
    }

    // MARK: Lifecycle

    @MainActor func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AudioSessionWork.queue.async { [self] in
                do {
                    try startOnAudioQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnAudioQueue() throws {
        guard !hasInstalledTap else { return }
        guard case .granted = Self.permission else { throw CaptureError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        // `.measurement` asks iOS to skip its input processing (AGC, EQ,
        // noise suppression). Those are tuned for intelligibility and would
        // quietly reshape exactly the spectral envelope the MFCC stage is
        // trying to measure.
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        #if DEBUG
        print("[LipSyncAudio] inputAvailable=\(session.isInputAvailable) muted=\(AVAudioApplication.shared.isInputMuted) gain=\(session.inputGain) route=\(session.currentRoute.inputs.map { $0.portType.rawValue }) hardware=\(hardwareFormat) tap=\(format)")
        #endif
        guard session.isInputAvailable,
              hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw CaptureError.noInputAvailable
        }

        lock.lock()
        ring.removeAll()
        receivedFrames = 0
        lastDiagnosticTime = .distantPast
        captureSampleRate = format.sampleRate
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }
        hasInstalledTap = true
        lock.lock()
        running = true
        lock.unlock()
    }

    func stop() {
        AudioSessionWork.queue.async { [self] in stopOnAudioQueue() }
    }

    private func stopOnAudioQueue() {
        guard hasInstalledTap else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        hasInstalledTap = false
        lock.lock()
        ring.removeAll()
        running = false
        lock.unlock()
        let session = AVAudioSession.sharedInstance()
        if session.category == .record {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    deinit {
        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: Ring buffer

    /// Called on the audio thread. Mixes to mono and writes straight into the
    /// fixed-capacity ring, which evicts the oldest samples once full. No
    /// allocation happens here.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        lock.lock()
        receivedFrames += frames
        ring.writeMixed(channels, channelCount: channelCount, frames: frames)
        lock.unlock()
    }

    /// The rate the tap is delivering at, so a caller can size its window
    /// before asking for one.
    var currentSampleRate: Double {
        lock.lock()
        defer { lock.unlock() }
        return captureSampleRate
    }

    /// The most recent `count` samples plus the rate they were captured at.
    /// Returns fewer than `count` samples while the ring is still filling —
    /// the analyzer front-pads, so an early window is harmless.
    func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        let samples = ring.latest(count)
        let rate = captureSampleRate
        let totalFrames = receivedFrames
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastDiagnosticTime) >= 1
        if shouldLog { lastDiagnosticTime = now }
        lock.unlock()
        #if DEBUG
        if shouldLog {
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            print("[LipSyncAudio] frames=\(totalFrames) window=\(samples.count) rate=\(rate) peak=\(peak)")
        }
        #endif
        return (samples, rate)
    }
}
