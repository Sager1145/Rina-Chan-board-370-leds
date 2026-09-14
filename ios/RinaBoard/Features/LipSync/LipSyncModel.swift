import Foundation
import RinaCore
import SwiftUI

private struct LipSyncSubmission: Sendable {
    let frame: PackedFrame
    let vowel: LipSyncVowel?
    let reason: String
    let token: UUID
    /// True for the close-mouth frame sent from `stop()`. That frame is
    /// submitted after `outputSession` has already been cleared to nil, so it
    /// must not be dropped by the usual `outputSession == token` recheck in
    /// `send` — it still must match a live, current session token.
    let closing: Bool
}

/// 口型同步 tab state: the live microphone → vowel → mouth loop, its options,
/// and the per-vowel calibration.
///
/// Ports the feature of the same name from `738NGX/RinaChanBoard`. The DSP
/// itself lives in `RinaCore.LipSyncAnalyzer`; this model owns the parts the
/// DSP must not know about — audio capture, the refresh clock, the board, and
/// what the user has tuned.
///
/// Two rules are carried over from upstream deliberately:
///
/// 1. **Only send on change.** Upstream sends a face update only when the
///    detected phoneme differs from the last one. At 30 Hz a per-tick send
///    would mean 30 frames/s down a link whose pump is 20 ms deep — and the
///    board would be redrawing an identical mouth.
/// 2. **Options lock while running.** Upstream takes a mutex over its options
///    page during lip sync. Here `canEditOptions` is false while running, so
///    the analyzer's configuration can never change underneath a live loop.
@Observable
@MainActor
final class LipSyncModel {
    // MARK: Persistence keys

    private enum Key {
        static let sensitivity = "lipSyncSensitivityDb"
        static let refreshRate = "lipSyncRefreshRateHz"
        static let smoothing = "lipSyncSmoothing"
        static let preset = "lipSyncVoicePreset"
        static let profile = "lipSyncProfile"
        static let mapping = "lipSyncMouthMapping"
        static let streamID = "lipSyncStreamID"
        static let baseCall = "lipSyncBaseCall"
        static let syncEyes = "lipSyncEyes"
    }

    // MARK: Live state

    private(set) var isRunning = false
    private(set) var permission: LipSyncAudioCapture.Permission = LipSyncAudioCapture.permission
    /// The smoothed vowel currently on the board. Nil is a closed mouth.
    private(set) var vowel: LipSyncVowel?
    /// The pre-smoothing classification, shown next to the smoothed one so the
    /// debounce slider has something visible to act on.
    private(set) var rawVowel: LipSyncVowel?
    private(set) var volumeDb: Float = -80
    private(set) var distances: [LipSyncVowel: Float] = [:]
    /// The composed face the board is showing; the view draws this.
    private(set) var previewFrame = PackedFrame()

    var errorMessage: String?

    // MARK: Calibration

    private(set) var calibratingVowel: LipSyncVowel?
    /// 0…1 while a calibration capture runs.
    private(set) var calibrationProgress: Double = 0

    var isCalibrating: Bool { calibratingVowel != nil }
    /// Upstream's options mutex: nothing that reshapes the analyzer may move
    /// while audio is being classified against it.
    var canEditOptions: Bool { !isRunning && !isCalibrating && !isStarting }

    // MARK: Options

    /// Upstream's 麦克风灵敏度: the dB floor below which a window is silence.
    var sensitivityDb: Float {
        didSet {
            guard sensitivityDb != oldValue else { return }
            analyzer.config.minVolumeDb = sensitivityDb
            defaults.set(Double(sensitivityDb), forKey: Key.sensitivity)
        }
    }

    /// Upstream's 同步刷新速率: how often the analysis window is classified.
    var refreshRateHz: Double {
        didSet {
            guard refreshRateHz != oldValue else { return }
            defaults.set(refreshRateHz, forKey: Key.refreshRate)
        }
    }

    /// Length of the phoneme-history vote. 1 disables debouncing.
    var smoothing: Int {
        didSet {
            guard smoothing != oldValue else { return }
            analyzer.config.historyLength = smoothing
            analyzer.reset()
            defaults.set(smoothing, forKey: Key.smoothing)
        }
    }

    /// Upstream's four recognition models (标准/男声/女声/动画). Switching
    /// regenerates the reference profile, which necessarily discards any
    /// calibration — the view warns before letting this change.
    var preset: LipSyncVoicePreset {
        didSet {
            guard preset != oldValue else { return }
            analyzer.profile = .synthesized(preset: preset, config: analyzer.config)
            analyzer.reset()
            defaults.set(preset.rawValue, forKey: Key.preset)
            persistProfile()
        }
    }

    /// Which mouth part each vowel selects.
    private(set) var mapping: LipSyncMouthMapping

    /// The eyes and cheeks worn while lip syncing. The mouth is the only part
    /// the analyzer drives; everything else is a costume the user picks.
    var baseCall: PartsCall = .defaultCall {
        didSet {
            guard baseCall != oldValue else { return }
            if let data = try? JSONEncoder().encode(baseCall) {
                defaults.set(data, forKey: Key.baseCall)
            }
            refreshPreviewFrame()
        }
    }

    var profile: LipSyncProfile { analyzer.profile }

    // MARK: Collaborators

    private var analyzer: LipSyncAnalyzer
    private let capture: any LipSyncCapturing
    private let permissionRequest: @MainActor () async -> LipSyncAudioCapture.Permission
    let library: PartsLibrary?
    let loadError: String?

    private var loopTask: Task<Void, Never>?
    private var awaitingAudioSince: Date?
    /// In-flight frames are never cancelled; a newer one just supersedes it.
    @ObservationIgnored private var sender: LatestValueSender<LipSyncSubmission>?
    @ObservationIgnored private weak var lastConnection: BoardConnection?
    private var outputSession: UUID?
    private var streamID: String?
    private let defaults: UserDefaults
    private var isAcquiringOutput = false
    private var startGeneration = UUID()
    /// Set across `start`'s permission `await` so a double tap cannot install
    /// two analysis loops.
    private(set) var isStarting = false
    private var isRequestingPermission = false
    private var calibrationTask: Task<Void, Never>?
    private var calibrationGeneration = UUID()
    /// The vowel whose mouth was last pushed, so a tick that classifies the
    /// same vowel again sends nothing. `.some(nil)` means "silence was sent".
    private var lastSentVowel: LipSyncVowel??

    // MARK: Init

    init(bundle: Bundle = .main,
         defaults: UserDefaults = .standard,
         capture: any LipSyncCapturing = LipSyncAudioCapture(),
         permissionRequest: @escaping @MainActor () async -> LipSyncAudioCapture.Permission = {
             await LipSyncAudioCapture.requestPermission()
         }) {
        self.capture = capture
        self.permissionRequest = permissionRequest
        self.defaults = defaults
        self.streamID = defaults.string(forKey: Key.streamID)
        var library: PartsLibrary?
        var loadError: String?
        do {
            library = try RinaResources.partsLibrary(bundle: bundle)
        } catch {
            loadError = String(format: NSLocalizedString("表情部件加载失败：%@", comment: "parts library load failed"),
                               error.localizedDescription)
        }
        self.library = library
        self.loadError = loadError

        let storedSensitivity = defaults.object(forKey: Key.sensitivity) as? Double
        let storedRefresh = defaults.object(forKey: Key.refreshRate) as? Double
        let storedSmoothing = defaults.object(forKey: Key.smoothing) as? Int
        let storedPreset = (defaults.string(forKey: Key.preset)).flatMap(LipSyncVoicePreset.init(rawValue:))

        var config = LipSyncConfig.default
        config.minVolumeDb = Float(storedSensitivity ?? Double(config.minVolumeDb))
        config.historyLength = storedSmoothing ?? config.historyLength

        self.sensitivityDb = config.minVolumeDb
        self.refreshRateHz = storedRefresh ?? 30
        self.smoothing = config.historyLength
        self.preset = storedPreset ?? .standard

        // A stored profile is only usable if it matches the current config's
        // vector length; otherwise fall back to a freshly synthesized one.
        let storedProfile = (defaults.data(forKey: Key.profile))
            .flatMap { try? JSONDecoder().decode(LipSyncProfile.self, from: $0) }
            .flatMap { $0.isComplete(mfccCount: config.mfccCount) ? $0 : nil }
        self.analyzer = LipSyncAnalyzer(config: config,
                                        profile: storedProfile ?? .synthesized(preset: storedPreset ?? .standard,
                                                                               config: config))

        let storedMapping = (defaults.data(forKey: Key.mapping))
            .flatMap { try? JSONDecoder().decode(LipSyncMouthMapping.self, from: $0) }
        let resolved = storedMapping ?? .default
        self.mapping = library.map { resolved.sanitized(against: $0) } ?? resolved
        self.baseCall = defaults.data(forKey: Key.baseCall)
            .flatMap { try? JSONDecoder().decode(PartsCall.self, from: $0) } ?? .defaultCall
        self.syncEyes = defaults.bool(forKey: Key.syncEyes)

        refreshPreviewFrame()
        sender = LatestValueSender(minInterval: 0.01) { [weak self] submission in
            await self?.send(submission)
        }
    }

    // MARK: Mouth mapping

    func setMouthId(_ id: String, for vowel: LipSyncVowel?) {
        mapping.setMouthId(id, for: vowel)
        if let library { mapping = mapping.sanitized(against: library) }
        persistMapping()
        refreshPreviewFrame()
    }

    /// Restores every choice on the 口型与造型 page: the per-vowel mouths and
    /// the eyes/cheeks costume.
    func resetMappingAndCostume() {
        mapping = library.map { LipSyncMouthMapping.default.sanitized(against: $0) } ?? .default
        persistMapping()
        baseCall = .defaultCall
        refreshPreviewFrame()
    }

    /// Mirrors eye choices onto the other eye, like the Control tab's 同步.
    /// Enabling it projects the left eye onto the right immediately.
    private(set) var syncEyes = false

    func setSyncEyes(_ enabled: Bool) {
        syncEyes = enabled
        defaults.set(enabled, forKey: Key.syncEyes)
        guard enabled, let mirrored = library?.mirroredEyeId(baseCall[.leye]) else { return }
        baseCall[.reye] = mirrored
    }

    func setCostumePart(_ id: String, for group: PartGroup) {
        var call = baseCall
        call[group] = id
        if syncEyes, group == .leye || group == .reye,
           let mirrored = library?.mirroredEyeId(id) {
            call[group == .leye ? .reye : .leye] = mirrored
        }
        baseCall = call
    }

    /// Random costume plus a random non-empty mouth for silence and each
    /// vowel; symmetric eyes while `syncEyes` is on.
    func randomize() {
        guard let library else { return }
        var generator = SystemRandomNumberGenerator()
        baseCall = syncEyes
            ? library.randomSymmetricCall(using: &generator)
            : library.randomCall(using: &generator)
        let mouths = library.ids(for: .mouth).filter { $0 != "0" }
        if !mouths.isEmpty {
            mapping.setMouthId(mouths.randomElement(using: &generator)!, for: nil)
            for vowel in LipSyncVowel.allCases {
                mapping.setMouthId(mouths.randomElement(using: &generator)!, for: vowel)
            }
            persistMapping()
        }
        refreshPreviewFrame()
    }

    /// The face for a vowel: the user's costume with that vowel's mouth
    /// substituted in. Also what the mouth-picker rows preview.
    func frame(for vowel: LipSyncVowel?) -> PackedFrame {
        guard let library else { return PackedFrame() }
        var call = baseCall
        call.mouth = mapping.mouthId(for: vowel)
        return library.compose(call: call)
    }

    func mouthIds() -> [String] {
        library?.ids(for: .mouth) ?? []
    }

    private func refreshPreviewFrame() {
        previewFrame = frame(for: vowel)
    }

    // MARK: Run loop

    func requestPermission() async {
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        permission = await permissionRequest()
        if case .denied = permission {
            errorMessage = LipSyncAudioCapture.CaptureError.permissionDenied.errorDescription
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase, connection: BoardConnection? = nil) {
        // A system permission alert temporarily makes the app inactive. Keep
        // the pending start alive; actually leaving the app still cancels it.
        if phase == .background || (phase == .inactive && !isRequestingPermission) {
            stop(connection: connection)
        }
    }

    func start(connection: BoardConnection, resumingStreamID: String? = nil,
               shouldStart: @MainActor () async -> Bool = { true }) async {
        guard !isRunning, !isCalibrating, !isStarting else { return }
        if let resumingStreamID, resumingStreamID != streamID {
            errorMessage = "无法恢复原来的嘴形同步：本机没有对应的同步记录。"
            return
        }
        // `requestPermission` suspends, and the button is still live across
        // that suspension, so a second tap would otherwise pass the
        // `!isRunning` guard too and install a second loop over the first —
        // two analysis loops at twice the configured rate, the first one
        // leaked because only the newest `loopTask` is ever cancelled.
        guard connection.connectionState == .connected else { errorMessage = "请先连接璃奈板"; return }
        let attempt = UUID()
        startGeneration = attempt
        isStarting = true
        defer { isStarting = false }

        await requestPermission()
        guard case .granted = permission, startGeneration == attempt, !Task.isCancelled,
              connection.connectionState == .connected else { return }
        guard await shouldStart(), startGeneration == attempt, !Task.isCancelled,
              connection.connectionState == .connected else { return }
        if resumingStreamID == nil { streamID = UUID().uuidString }
        defaults.set(streamID, forKey: Key.streamID)
        isAcquiringOutput = true
        outputSession = connection.output.begin(.lipSync)
        isAcquiringOutput = false
        do {
            try await capture.start()
        } catch {
            guard startGeneration == attempt else { return }
            if let token = outputSession, connection.output.isCurrent(token) {
                connection.output.invalidate()
            }
            outputSession = nil
            errorMessage = error.localizedDescription
            return
        }

        guard startGeneration == attempt else { return }
        guard !Task.isCancelled, connection.connectionState == .connected else {
            stop(connection: connection)
            return
        }
        analyzer.reset()
        lastSentVowel = nil
        isRunning = true
        awaitingAudioSince = Date()
        errorMessage = nil

        // Started from the main actor, so the loop body is already main-actor
        // isolated: `tick` reads the ring under its own lock and everything
        // else it touches is this model's own state.
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.tick(connection: connection)
                try? await Task.sleep(for: .seconds(self.tickInterval()))
            }
        }
    }

    /// Stops the microphone and closes the mouth on the board.
    ///
    /// `connection` is optional because stopping must never depend on the
    /// board still being there: a disconnect is one of the reasons to stop,
    /// and the microphone has to be released either way.
    func stop(connection: BoardConnection? = nil) {
        // Reclaiming our previous lease invokes its stop handler synchronously.
        // The old capture is already stopped; keep this new start alive.
        guard !isAcquiringOutput else { return }
        startGeneration = UUID()
        cancelCalibration()
        sender?.cancel()
        guard isRunning else {
            let token = outputSession
            outputSession = nil
            if let connection, let token, connection.output.isCurrent(token) {
                connection.output.invalidate()
            }
            return
        }
        loopTask?.cancel()
        loopTask = nil
        capture.stop()
        isRunning = false
        analyzer.reset()

        vowel = nil
        rawVowel = nil
        volumeDb = -80
        distances = [:]
        refreshPreviewFrame()

        // Stopping mid-syllable would leave an open mouth frozen on the
        // physical panel, so close it on the board too — not just in this
        // app's preview. `lastSentVowel` is cleared first so the send gate
        // treats this as a change even if silence was the last thing sent.
        lastSentVowel = nil
        if let connection {
            push(previewFrame, vowel: nil, connection: connection, closing: true)
        }
        outputSession = nil
    }

    private func tickInterval() -> TimeInterval {
        1.0 / max(1, min(60, refreshRateHz))
    }

    private func tick(connection: BoardConnection) {
        let state = RinaPerf.signposter.beginInterval("LipSyncTick")
        defer { RinaPerf.signposter.endInterval("LipSyncTick", state) }
        // Interruptions and route reconfiguration can stop AVAudioEngine
        // without an explicit stop. Do not keep classifying its last buffer.
        guard capture.isRunning else {
            stop(connection: connection)
            errorMessage = NSLocalizedString("麦克风采集已中断，请重新开始同步", comment: "microphone capture interrupted")
            return
        }
        let window = currentWindow()
        guard !window.samples.isEmpty else {
            if let since = awaitingAudioSince, Date().timeIntervalSince(since) >= 2 {
                stop(connection: connection)
                errorMessage = "麦克风未传入音频数据，请检查输入设备后重新开始同步"
            }
            return
        }
        awaitingAudioSince = nil

        let result = analyzer.analyze(window.samples, sampleRate: window.sampleRate)
        volumeDb = result.volumeDb
        rawVowel = result.rawVowel
        distances = result.distances

        // Gate on what the *board* was last told, not on what this app is
        // displaying. Comparing against `vowel` conflated the two: after a
        // disconnect and reconnect, both operands were equal and the board
        // was never resynced until the vowel happened to change again.
        guard lastSentVowel != .some(result.vowel) else { return }
        vowel = result.vowel
        refreshPreviewFrame()
        push(previewFrame, vowel: result.vowel, connection: connection)
    }

    /// The most recent analysis window: enough input samples that, once
    /// resampled to the analyzer's rate, a full FFT window survives — plus a
    /// margin the resampler's zero-padded edges can eat.
    private func currentWindow() -> (samples: [Float], sampleRate: Double) {
        let rate = capture.currentSampleRate
        let ratio = max(1, rate / analyzer.config.targetSampleRate)
        let count = Int(Double(analyzer.config.fftSize) * ratio) + 512
        return capture.latestWindow(count: count)
    }

    private func push(_ frame: PackedFrame, vowel: LipSyncVowel?, connection: BoardConnection,
                       closing: Bool = false) {
        guard connection.connectionState == .connected, let token = outputSession,
              connection.output.isCurrent(token), let streamID else { return }
        let reason = "lipsync:\(streamID):0"
        lastSentVowel = .some(vowel)
        lastConnection = connection
        sender?.submit(LipSyncSubmission(frame: frame, vowel: vowel, reason: reason, token: token,
                                          closing: closing))
    }

    private func send(_ submission: LipSyncSubmission) async {
        guard let connection = lastConnection, connection.connectionState == .connected,
              connection.output.isCurrent(submission.token),
              submission.closing || outputSession == submission.token else { return }
        do {
            _ = try await connection.setFrame(submission.frame, playback: .idle,
                                              reason: submission.reason, outputSession: submission.token)
        } catch is CancellationError {
        } catch RatePumpError.dropped {
            // Superseded by a newer mouth; the latest syllable always
            // wins. Forget what was sent so the next tick re-sends this
            // mouth if the vowel has not moved on — otherwise a dropped
            // frame strands the board on the previous mouth until the
            // speaker happens to change vowel again.
            forgetLastSentVowel(ifStill: submission.vowel)
        } catch {
            forgetLastSentVowel(ifStill: submission.vowel)
            errorMessage = String(format: NSLocalizedString("发送失败：%@", comment: "frame send failed"),
                                  error.localizedDescription)
        }
    }

    /// Clears the send gate, but only if nothing newer has been sent since —
    /// a late failure for an old mouth must not force a resend of one the
    /// board has already moved past.
    private func forgetLastSentVowel(ifStill vowel: LipSyncVowel?) {
        guard lastSentVowel == .some(vowel) else { return }
        lastSentVowel = nil
    }

    // MARK: Calibration

    /// Records `duration` seconds of the user holding one vowel, averages the
    /// MFCC vectors it measures, and replaces that vowel's reference.
    ///
    /// Averaging rather than taking one window is what makes this usable by
    /// hand: a single 64 ms window lands wherever the user's voice happened to
    /// be, while a second of it converges on the vowel's actual timbre.
    func calibrate(_ vowel: LipSyncVowel, duration: TimeInterval = 1.5) {
        guard canEditOptions else { return }

        calibratingVowel = vowel
        let attempt = UUID()
        calibrationGeneration = attempt
        calibrationProgress = 0
        volumeDb = -80
        errorMessage = nil

        calibrationTask = Task { [weak self] in
            guard let self else { return }
            // Cancellation can happen before this task first gets to run.
            guard !Task.isCancelled, self.calibrationGeneration == attempt else { return }
            await self.requestPermission()
            guard !Task.isCancelled, self.calibrationGeneration == attempt else { return }
            guard case .granted = self.permission else {
                self.calibratingVowel = nil
                return
            }
            do {
                try await self.capture.start()
            } catch {
                guard self.calibrationGeneration == attempt else { return }
                self.errorMessage = error.localizedDescription
                self.calibratingVowel = nil
                return
            }
            guard self.calibrationGeneration == attempt else { return }
            defer {
                // An old cancelled calibration must not stop a new capture.
                if self.calibrationGeneration == attempt {
                    self.capture.stop()
                    self.calibratingVowel = nil
                    self.calibrationProgress = 0
                }
            }

            // Let the ring fill before the first measurement, or the opening
            // windows are mostly the zero padding of an empty buffer.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            var vectors: [[Float]] = []
            var receivedSamples = false
            var receivedSignal = false
            var loudestDb: Float = -80
            let steps = max(1, Int(duration * 20))
            for step in 0..<steps {
                guard !Task.isCancelled else { return }
                let window = self.currentWindow()
                receivedSamples = receivedSamples || !window.samples.isEmpty
                receivedSignal = receivedSignal || window.samples.contains { $0 != 0 }
                self.volumeDb = LipSyncSignal.rmsDb(window.samples)
                loudestDb = max(loudestDb, self.volumeDb)
                if self.volumeDb >= self.sensitivityDb {
                    let vector = self.analyzer.measure(window.samples, sampleRate: window.sampleRate)
                    if !vector.isEmpty { vectors.append(vector) }
                }
                self.calibrationProgress = Double(step + 1) / Double(steps)
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard vectors.count >= max(3, steps / 4) else {
                if !receivedSamples {
                    self.errorMessage = "麦克风未传入音频数据，请检查输入设备后重新校准"
                } else if !receivedSignal {
                    self.errorMessage = "麦克风传入的音频全部为静音，请检查输入设备是否被静音"
                } else {
                    self.errorMessage = String(format: "声音不足：最高 %.0f dB，识别阈值 %.0f dB。请降低阈值或靠近麦克风再试一次",
                                               Double(loudestDb), Double(self.sensitivityDb))
                }
                #if DEBUG
                print("[LipSyncAudio] calibration samples=\(receivedSamples) signal=\(receivedSignal) loudestDb=\(loudestDb) threshold=\(self.sensitivityDb) vectors=\(vectors.count)/\(steps)")
                #endif
                return
            }

            let length = vectors[0].count
            var mean = [Float](repeating: 0, count: length)
            for vector in vectors where vector.count == length {
                for index in 0..<length { mean[index] += vector[index] }
            }
            mean = mean.map { $0 / Float(vectors.count) }

            self.analyzer.profile.calibrate(vowel, with: mean)
            self.analyzer.reset()
            self.persistProfile()
        }
    }

    func cancelCalibration() {
        calibrationGeneration = UUID()
        calibrationTask?.cancel()
        calibrationTask = nil
        capture.stop()
        calibratingVowel = nil
        calibrationProgress = 0
    }

    func resetCalibration() {
        guard canEditOptions else { return }
        analyzer.profile = .synthesized(preset: preset, config: analyzer.config)
        analyzer.reset()
        persistProfile()
    }

    // MARK: Persistence

    private func persistProfile() {
        guard let data = try? JSONEncoder().encode(analyzer.profile) else { return }
        defaults.set(data, forKey: Key.profile)
    }

    private func persistMapping() {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: Key.mapping)
    }
}
