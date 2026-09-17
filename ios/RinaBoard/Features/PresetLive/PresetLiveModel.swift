import AVFoundation
import Foundation
import RinaCore

struct BuiltInPerformance: Identifiable, Sendable, Decodable, Hashable {
    var id: String { file }
    let file: String
    let audio: String
    let audioExtension: String
    let title: String
    let artist: String
    let keyframes: Int
    let durationMs: Int
    let source: String

    var hasAudio: Bool { audioURL(in: .main) != nil }

    func audioURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: audio, withExtension: audioExtension)
    }
}

/// Copies imported material into Application Support before it becomes active.
/// The directory is injectable so import transaction tests can use a temporary
/// location.
struct PresetLiveFileStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("PresetLive", isDirectory: true)
        }
    }

    func storedURL(named name: String) -> URL {
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        return directory.appendingPathComponent(safeName, isDirectory: false)
    }

    /// A partially copied file is never returned or persisted. The source is
    /// read while its document-picker security scope is active at the caller.
    func copyIntoStorage(_ source: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = source.lastPathComponent.isEmpty ? "imported" : source.lastPathComponent
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).importing")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct PresetLiveSubmission: Sendable {
    let frame: PackedFrame
    let positionMs: Int
    let streamID: String
    let token: UUID
}

/// Plays an audio track locally and drives a board face from the audio
/// player's measured position. Script/audio changes are staged and validated
/// before replacing the active pair.
@Observable
@MainActor
final class PresetLiveModel {
    private(set) var script: LivePerformanceScript?
    private(set) var scriptName: String?
    private(set) var composedFrames: [PackedFrame] = []
    private(set) var audioTitle: String?

    private(set) var builtInPerformances: [BuiltInPerformance] = []
    private(set) var selectedBuiltIn: BuiltInPerformance.ID?
    private(set) var isCustomMode = false

    private(set) var isPlaying = false
    private(set) var hasPlaybackProgress = false
    private(set) var positionMs = 0 {
        didSet {
            let progress = positionMs > 0
            if progress != hasPlaybackProgress { hasPlaybackProgress = progress }
        }
    }
    private(set) var durationMs = 0
    private(set) var previewFrame = PackedFrame()
    private(set) var currentKeyframeIndex: Int?
    var errorMessage: String?

    var loops: Bool {
        didSet {
            guard loops != oldValue else { return }
            defaults.set(loops, forKey: Self.loopsKey)
        }
    }

    /// Silences the phone speaker only. The player keeps running at zero
    /// volume because its position is the clock the board frames follow.
    var isMuted: Bool {
        didSet {
            guard isMuted != oldValue else { return }
            defaults.set(isMuted, forKey: Self.mutedKey)
            player?.volume = isMuted ? 0 : 1
        }
    }

    var canPlay: Bool { script != nil && player != nil }
    var hasAudio: Bool { player != nil }
    var needsBoardResume: Bool { isPlaying && outputSession == nil }
    var selectedPerformance: BuiltInPerformance? {
        builtInPerformances.first { $0.id == selectedBuiltIn }
    }

    private static let loopsKey = "presetLiveLoops"
    private static let mutedKey = "presetLiveMuted"
    private static let scriptFileKey = "presetLiveScriptFile"
    private static let audioFileKey = "presetLiveAudioFile"
    private static let builtInKey = "presetLiveBuiltIn"
    private static let customModeKey = "performanceCustomMode"
    private static let scriptTitleKey = "presetLiveScriptTitle"
    private static let audioTitleKey = "presetLiveAudioTitle"
    private static let playbackMaterialKey = "presetLivePlaybackMaterial"
    private static let playbackPositionKey = "presetLivePlaybackPositionMs"
    private static let playbackStreamKey = "presetLivePlaybackStreamID"
    private static let customPlaybackPrefix = "custom|"
    private static let builtInPlaybackPrefix = "builtIn|"
    /// Coarser than the ~33 Hz clock tick: `positionMs` only republishes when
    /// the audio position has moved at least this far, so the observed
    /// property (and everything that reads it in the view body) settles at
    /// roughly 10 Hz instead of every tick.
    static let positionPublishStepMs = 100

    private let bundle: Bundle
    private let defaults: UserDefaults
    private let fileStore: PresetLiveFileStore
    private var library: PartsLibrary?
    private var player: AVAudioPlayer?
    private var outputSession: UUID?
    /// In-flight frames are never cancelled; a newer one just supersedes it.
    @ObservationIgnored private var sender: LatestValueSender<PresetLiveSubmission>?
    /// Bumped by every audio import call (built-in or custom); a staged
    /// result whose generation has been superseded by a newer audio import
    /// is discarded instead of committed. Kept separate from
    /// `scriptImportGeneration` so an audio import and a script import never
    /// cancel each other.
    @ObservationIgnored private var audioImportGeneration = 0
    /// Bumped by every script import call; see `audioImportGeneration`.
    @ObservationIgnored private var scriptImportGeneration = 0
    /// Test-only hook invoked with the picked source URL once staging
    /// finishes (success or failure) but before any generation/selection
    /// check or commit runs. Lets tests hold an import at a deterministic
    /// point and control exactly when it is allowed to proceed.
    @ObservationIgnored var importCommitHookForTesting: ((URL) async -> Void)?
    private var clockTask: Task<Void, Never>?
    private var didRestore = false
    private var didLoadDemo = false
    private var sessionActive = false
    @ObservationIgnored private var playbackStartTask: Task<Void, Never>?
    private var pausedByUser = true
    private var isAcquiringOutput = false
    private var interruptionObserver: NSObjectProtocol?
    private weak var lastConnection: BoardConnection?
    private var lastPersistedPositionMs: Int?
    private var lastSubmittedPositionMs: Int?
    private var playbackStreamID: String?

    init(bundle: Bundle = .main,
         defaults: UserDefaults = .standard,
         fileStore: PresetLiveFileStore = PresetLiveFileStore()) {
        self.bundle = bundle
        self.defaults = defaults
        self.fileStore = fileStore
        self.library = try? RinaResources.partsLibrary(bundle: bundle)
        self.loops = defaults.bool(forKey: Self.loopsKey)
        self.isMuted = defaults.bool(forKey: Self.mutedKey)
        if let data = try? RinaResources.data(named: "preset_live_catalog", ext: "json", in: bundle),
           let decoded = try? JSONDecoder().decode([BuiltInPerformance].self, from: data) {
            self.builtInPerformances = decoded
        }
        sender = LatestValueSender(minInterval: 0.01) { [weak self] submission in
            await self?.send(submission)
        }
    }

    // MARK: Restore and selection

    func restoreLastImportIfNeeded() {
        guard !didRestore else { return }
        didRestore = true

        if defaults.bool(forKey: Self.customModeKey) {
            enterCustom(persistSelection: false)
            return
        }
        if let id = defaults.string(forKey: Self.builtInKey),
           let performance = builtInPerformances.first(where: { $0.id == id }),
           selectBuiltIn(performance, persistSelection: false) {
            return
        }
        if let first = builtInPerformances.first,
           selectBuiltIn(first, persistSelection: true) {
            return
        }
    }

    /// Reclaims board output for an in-memory performance, or reconstructs
    /// the last performance that actually reached Play and resumes it from
    /// its most recent local-audio checkpoint. Ordinary view restoration
    /// remains passive and never calls this method.
    func restorePlaybackFromBoard(
        connection: BoardConnection,
        streamID boardStreamID: String? = nil,
        positionMs boardPositionMs: Int? = nil,
        shouldResume: @escaping @MainActor () async -> Bool = { true }
    ) async {
        didRestore = true
        let generation = connection.connectionGeneration
        let previousOutputSession = connection.output.session
        guard connection.connectionState == .connected, await shouldResume() else { return }

        guard let savedStreamID = defaults.string(forKey: Self.playbackStreamKey),
              savedStreamID.count == 36,
              UUID(uuidString: savedStreamID) != nil,
              boardStreamID == nil || boardStreamID == savedStreamID else {
            if isPlaying { pause() }
            reportMissingOriginalStream()
            return
        }

        if isPlaying {
            guard activePlaybackMaterial == defaults.string(forKey: Self.playbackMaterialKey),
                  playbackStreamID == savedStreamID else {
                pause()
                reportMissingOriginalStream()
                return
            }
            guard !Task.isCancelled,
                  generation == connection.connectionGeneration,
                  previousOutputSession == connection.output.session,
                  await shouldResume() else { return }
            resumeBoardOutput(connection: connection)
            return
        }

        let checkpoint = defaults.integer(forKey: Self.playbackPositionKey)
        guard restoreCheckpointMaterial(), canPlay else {
            reportMissingOriginalStream()
            return
        }
        guard !Task.isCancelled,
              generation == connection.connectionGeneration,
              previousOutputSession == connection.output.session,
              await shouldResume() else { return }

        playbackStreamID = savedStreamID
        seek(toMs: boardPositionMs ?? checkpoint)
        await startPlayback(connection: connection,
                            expectedGeneration: generation,
                            expectedOutputSession: previousOutputSession,
                            validateRestore: true,
                            shouldResume: shouldResume)
    }

    func loadDemoScriptIfNeeded() {
        guard !didLoadDemo, script == nil, !isCustomMode, selectedBuiltIn == nil else { return }
        didLoadDemo = true
        guard let library else {
            errorMessage = NSLocalizedString("无法加载部件库", comment: "parts library unavailable")
            return
        }
        do {
            let data = try RinaResources.data(named: "preset_live_demo", ext: "rinalive", in: bundle)
            let parsed = try parseScript(data, library: library,
                                         encodingError: NSLocalizedString("演示脚本编码无效", comment: "demo script encoding invalid"))
            commit(script: parsed,
                   frames: parsed.composedFrames(using: library),
                   scriptName: NSLocalizedString("演示脚本", comment: "demo script name"),
                   player: nil,
                   audioTitle: nil,
                   selectedBuiltIn: nil,
                   customMode: false)
            errorMessage = nil
        } catch {
            errorMessage = String(format: NSLocalizedString("演示脚本加载失败：%@", comment: "demo script load failed"),
                                  String(describing: error))
        }
    }

    @discardableResult
    func selectBuiltIn(_ performance: BuiltInPerformance) -> Bool {
        selectBuiltIn(performance, persistSelection: true)
    }

    @discardableResult
    private func selectBuiltIn(_ performance: BuiltInPerformance, persistSelection: Bool) -> Bool {
        guard let library else {
            errorMessage = NSLocalizedString("无法加载部件库", comment: "parts library unavailable")
            return false
        }
        do {
            let data = try RinaResources.data(named: performance.file, ext: "rinalive", in: bundle)
            let parsed: LivePerformanceScript
            do {
                let scriptParseState = RinaPerf.signposter.beginInterval("PresetLiveScriptParse")
                defer { RinaPerf.signposter.endInterval("PresetLiveScriptParse", scriptParseState) }
                parsed = try parseScript(data, library: library,
                                         encodingError: NSLocalizedString("演出脚本编码无效", comment: "built-in script encoding invalid"))
            }
            let frames = parsed.composedFrames(using: library)
            let storedName = defaults.string(forKey: audioKey(for: performance.id))
            let storedURL = storedName.map(fileStore.storedURL(named:))
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let audioURL = storedURL ?? performance.audioURL(in: bundle)
            let preparedPlayer = try audioURL.map(prepareAudio)

            commit(script: parsed, frames: frames, scriptName: performance.title,
                   player: preparedPlayer, audioTitle: preparedPlayer == nil ? nil : performance.title,
                   selectedBuiltIn: performance.id, customMode: false)
            if persistSelection {
                defaults.set(false, forKey: Self.customModeKey)
                defaults.set(performance.id, forKey: Self.builtInKey)
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(format: NSLocalizedString("无法载入演出：%@", comment: "built-in performance load failed"),
                                  String(describing: error))
            return false
        }
    }

    func enterCustom() {
        enterCustom(persistSelection: true)
    }

    private func enterCustom(persistSelection: Bool, loadAudio: Bool = true) {
        let prepared = restoreCustomMaterial(loadAudio: loadAudio)
        commit(script: prepared.script,
               frames: prepared.frames,
               scriptName: prepared.scriptName,
               player: prepared.player,
               audioTitle: prepared.audioTitle,
               selectedBuiltIn: nil,
               customMode: true)
        if persistSelection { defaults.set(true, forKey: Self.customModeKey) }
        errorMessage = nil
    }

    // MARK: Import

    /// Source-compatible entry point. Built-in selection means "audio for
    /// this song"; custom selection means the custom audio half.
    func importAudio(from url: URL) async {
        if let selectedBuiltIn {
            await importAudio(from: url, forBuiltIn: selectedBuiltIn)
        } else {
            await importCustomAudio(from: url)
        }
    }

    func importAudio(from url: URL, forBuiltIn id: BuiltInPerformance.ID) async {
        let failureFormat = NSLocalizedString("导入音频失败：%@", comment: "audio import failed")
        guard selectedBuiltIn == id else {
            errorMessage = String(format: failureFormat, importErrorDescription(PresetLiveImportError.selectionChanged))
            return
        }
        audioImportGeneration += 1
        let generation = audioImportGeneration
        let store = fileStore
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PresetLiveModel.stageAudio(from: url, store: store) }
        }.value
        if let hook = importCommitHookForTesting { await hook(url) }
        guard generation == audioImportGeneration else {
            if case .success(let staged) = result { fileStore.remove(staged.copy) }
            return
        }
        switch result {
        case .success(let staged):
            guard selectedBuiltIn == id else {
                fileStore.remove(staged.copy)
                errorMessage = String(format: failureFormat, importErrorDescription(PresetLiveImportError.selectionChanged))
                return
            }
            let storageKey = audioKey(for: id)
            let previousName = defaults.string(forKey: storageKey)
            stop()
            staged.player.volume = isMuted ? 0 : 1
            player = staged.player
            audioTitle = builtInPerformances.first(where: { $0.id == id })?.title ?? url.lastPathComponent
            durationMs = Int(staged.player.duration * 1000)
            positionMs = 0
            currentKeyframeIndex = nil
            previewFrame = composedFrames.first ?? PackedFrame()
            defaults.set(staged.copy.lastPathComponent, forKey: storageKey)
            removeReplacedStoredFile(named: previousName, keeping: staged.copy)
            errorMessage = nil
        case .failure(let error):
            errorMessage = String(format: failureFormat, importErrorDescription(error))
        }
    }

    func importScript(from url: URL) async {
        let failureFormat = NSLocalizedString("导入脚本失败：%@", comment: "script import failed")
        guard let library else {
            errorMessage = String(format: failureFormat, importErrorDescription(PresetLiveImportError.partsUnavailable))
            return
        }
        scriptImportGeneration += 1
        let generation = scriptImportGeneration
        let capturedSelectedBuiltIn = selectedBuiltIn
        let store = fileStore
        let encodingError = NSLocalizedString("脚本编码无效，需为 UTF-8 文本", comment: "script encoding invalid")
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PresetLiveModel.stageScript(from: url, library: library, store: store, encodingError: encodingError) }
        }.value
        if let hook = importCommitHookForTesting { await hook(url) }
        guard generation == scriptImportGeneration else {
            if case .success(let staged) = result { fileStore.remove(staged.copy) }
            return
        }
        switch result {
        case .success(let staged):
            // Only a move to a built-in song invalidates this import. Custom
            // mode turning on is what a custom import is asking for anyway,
            // and a script import switching it on must not discard an audio
            // import staging alongside it (or the reverse).
            guard selectedBuiltIn == capturedSelectedBuiltIn else {
                fileStore.remove(staged.copy)
                errorMessage = String(format: failureFormat, importErrorDescription(PresetLiveImportError.selectionChanged))
                return
            }
            let previousName = defaults.string(forKey: Self.scriptFileKey)
            if !isCustomMode { enterCustom(persistSelection: false) }
            commit(script: staged.script, frames: staged.frames, scriptName: url.lastPathComponent,
                   player: player, audioTitle: audioTitle,
                   selectedBuiltIn: nil, customMode: true)
            defaults.set(staged.copy.lastPathComponent, forKey: Self.scriptFileKey)
            removeReplacedStoredFile(named: previousName, keeping: staged.copy)
            defaults.set(url.lastPathComponent, forKey: Self.scriptTitleKey)
            defaults.set(true, forKey: Self.customModeKey)
            errorMessage = nil
        case .failure(let error):
            errorMessage = String(format: failureFormat, importErrorDescription(error))
        }
    }

    func importCustomAudio(from url: URL) async {
        let failureFormat = NSLocalizedString("导入音频失败：%@", comment: "audio import failed")
        audioImportGeneration += 1
        let generation = audioImportGeneration
        let capturedSelectedBuiltIn = selectedBuiltIn
        let store = fileStore
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PresetLiveModel.stageAudio(from: url, store: store) }
        }.value
        if let hook = importCommitHookForTesting { await hook(url) }
        guard generation == audioImportGeneration else {
            if case .success(let staged) = result { fileStore.remove(staged.copy) }
            return
        }
        switch result {
        case .success(let staged):
            // Only a move to a built-in song invalidates this import. Custom
            // mode turning on is what a custom import is asking for anyway,
            // and a script import switching it on must not discard an audio
            // import staging alongside it (or the reverse).
            guard selectedBuiltIn == capturedSelectedBuiltIn else {
                fileStore.remove(staged.copy)
                errorMessage = String(format: failureFormat, importErrorDescription(PresetLiveImportError.selectionChanged))
                return
            }
            let previousName = defaults.string(forKey: Self.audioFileKey)
            // The staged player below replaces whatever `enterCustom` would
            // load for the previous custom audio file; loading it here would
            // just be thrown away by the commit two lines down.
            if !isCustomMode { enterCustom(persistSelection: false, loadAudio: false) }
            staged.player.volume = isMuted ? 0 : 1
            commit(script: script, frames: composedFrames, scriptName: scriptName,
                   player: staged.player, audioTitle: url.lastPathComponent,
                   selectedBuiltIn: nil, customMode: true)
            defaults.set(staged.copy.lastPathComponent, forKey: Self.audioFileKey)
            removeReplacedStoredFile(named: previousName, keeping: staged.copy)
            defaults.set(url.lastPathComponent, forKey: Self.audioTitleKey)
            defaults.set(true, forKey: Self.customModeKey)
            errorMessage = nil
        case .failure(let error):
            errorMessage = String(format: failureFormat, importErrorDescription(error))
        }
    }

    /// Result of validating and copying an imported audio file off the main
    /// actor. The player is created in the worker and not touched there again
    /// before being handed to the main actor.
    private struct StagedAudio: @unchecked Sendable {
        let copy: URL
        let player: AVAudioPlayer
    }

    private struct StagedScript: Sendable {
        let copy: URL
        let script: LivePerformanceScript
        let frames: [PackedFrame]
    }

    /// Security scope, validation, copy and second validation all happen off
    /// the main actor; only the resulting player and copy URL cross back.
    nonisolated private static func stageAudio(from url: URL, store: PresetLiveFileStore) throws -> StagedAudio {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        _ = try AVAudioPlayer(contentsOf: url)
        let copy = try store.copyIntoStorage(url)
        // Validate the stored copy too; a provider can expose a readable
        // coordinated URL whose copied bytes are incomplete or changed.
        do {
            let player = try AVAudioPlayer(contentsOf: copy)
            return StagedAudio(copy: copy, player: player)
        } catch {
            store.remove(copy)
            throw error
        }
    }

    nonisolated private static func stageScript(from url: URL, library: PartsLibrary,
                                                store: PresetLiveFileStore,
                                                encodingError: String) throws -> StagedScript {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let parsed = try parseScript(data, library: library, encodingError: encodingError)
        let frames = parsed.composedFrames(using: library)
        let copy = try store.copyIntoStorage(url)
        return StagedScript(copy: copy, script: parsed, frames: frames)
    }

    // MARK: Board output and local playback

    func suspendBoardOutput() {
        if isPlaying, let player { positionMs = Int(player.currentTime * 1000) }
        savePlaybackPosition(force: true)
        outputSession = nil
        lastSubmittedPositionMs = nil
        sender?.cancel()
    }

    /// Explicitly starts a fresh board-output lease while local audio keeps
    /// running. It never treats cancellation of an old lease as permission to
    /// restore that lease.
    func resumeBoardOutput(connection: BoardConnection) {
        guard isPlaying, connection.connectionState == .connected,
              outputSession == nil else { return }
        let token = connection.output.begin(.performance)
        outputSession = token
        lastConnection = connection
        let currentPosition = player.map { Int($0.currentTime * 1000) } ?? positionMs
        positionMs = currentPosition
        synchronizeFrame(atMs: currentPosition, connection: connection, force: true)
    }

    @discardableResult
    func play(connection: BoardConnection) -> Task<Void, Never> {
        playbackStartTask?.cancel()
        player?.pause()
        deactivateSessionIfNeeded()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.startPlayback(connection: connection)
        }
        playbackStartTask = task
        return task
    }

    private func startPlayback(
        connection: BoardConnection,
        expectedGeneration: UUID? = nil,
        expectedOutputSession: UUID? = nil,
        validateRestore: Bool = false,
        shouldResume: @MainActor () async -> Bool = { true }
    ) async {
        guard !Task.isCancelled else { return }
        guard canPlay, let player else {
            errorMessage = NSLocalizedString("请先选择有效的脚本和音频", comment: "performance needs script and audio")
            return
        }
        lastConnection = connection
        guard await activateSessionIfNeeded() else {
            if !Task.isCancelled { suspendBoardOutput() }
            return
        }
        guard !Task.isCancelled else {
            deactivateSessionIfNeeded()
            return
        }
        if validateRestore {
            guard expectedGeneration == connection.connectionGeneration,
                  expectedOutputSession == connection.output.session,
                  connection.connectionState == .connected,
                  await shouldResume() else {
                deactivateSessionIfNeeded()
                return
            }
        }
        if connection.connectionState == .connected {
            isAcquiringOutput = true
            outputSession = connection.output.begin(.performance)
            isAcquiringOutput = false
        } else {
            outputSession = nil
        }
        pausedByUser = false
        guard player.play() else {
            deactivateSessionIfNeeded()
            suspendBoardOutput()
            errorMessage = NSLocalizedString("无法开始播放音频", comment: "audio playback start failed")
            isPlaying = false
            return
        }
        registerInterruptionObserverIfNeeded()
        isPlaying = true
        preparePlaybackStreamForCurrentMaterial(restoring: validateRestore)
        currentKeyframeIndex = nil
        positionMs = Int(player.currentTime * 1000)
        savePlaybackPosition(force: true)
        // The first visible/sent face is selected from the same audio position
        // as playback starts instead of waiting for the first clock interval.
        synchronizeFrame(atMs: positionMs, connection: connection, force: true)
        startClock(connection: connection)
        errorMessage = nil
    }

    func pause() {
        guard !isAcquiringOutput else { return }
        playbackStartTask?.cancel()
        playbackStartTask = nil
        if isPlaying, let player { positionMs = Int(player.currentTime * 1000) }
        savePlaybackPosition(force: true)
        suspendBoardOutput()
        pausedByUser = true
        player?.pause()
        deactivateSessionIfNeeded()
        isPlaying = false
        clockTask?.cancel()
        clockTask = nil
    }

    func stop() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        suspendBoardOutput()
        pausedByUser = true
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        positionMs = 0
        savePlaybackPosition(force: true)
        currentKeyframeIndex = nil
        previewFrame = composedFrames.first ?? PackedFrame()
        clockTask?.cancel()
        clockTask = nil
        deactivateSessionIfNeeded()
        removeInterruptionObserver()
    }

    func seek(toMs ms: Int) {
        guard let player else { return }
        let clamped = max(0, min(durationMs, ms))
        player.currentTime = TimeInterval(clamped) / 1000
        positionMs = clamped
        savePlaybackPosition(force: true)
        currentKeyframeIndex = nil
        if let connection = lastConnection {
            synchronizeFrame(atMs: clamped, connection: connection, force: true)
        } else {
            synchronizePreview(atMs: clamped, force: true)
        }
    }

    // MARK: Audio session

    @discardableResult
    private func activateSessionIfNeeded() async -> Bool {
        guard !Task.isCancelled else { return false }
        sessionActive = true
        // Re-applied on every start: 口型 or 视频 may have changed or released
        // the shared session since this model last activated it.
        do {
            try await PlaybackAudioSession.acquire(.performance)
            guard !Task.isCancelled else { return false }
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            deactivateSessionIfNeeded()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func deactivateSessionIfNeeded() {
        guard sessionActive else { return }
        sessionActive = false
        PlaybackAudioSession.release(.performance)
    }

    private func registerInterruptionObserverIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }
    }

    private func removeInterruptionObserver() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            guard isPlaying else { return }
            if let player { positionMs = Int(player.currentTime * 1000) }
            player?.pause()
            isPlaying = false
            clockTask?.cancel()
            clockTask = nil
        case .ended:
            guard !pausedByUser, player != nil, let connection = lastConnection else { return }
            let raw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) else {
                finishPlayback()
                return
            }
            play(connection: connection)
        @unknown default:
            break
        }
    }

    // MARK: Clock

    private func startClock(connection: BoardConnection) {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick(connection: connection)
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { return }
            }
        }
    }

    private func tick(connection: BoardConnection) {
        guard let player else { return }
        let now = Int(player.currentTime * 1000)
        if abs(now - positionMs) >= Self.positionPublishStepMs {
            positionMs = now
        }
        savePlaybackPosition(force: false, atMs: now)
        if !player.isPlaying, isPlaying {
            if loops {
                player.currentTime = 0
                positionMs = 0
                savePlaybackPosition(force: true, atMs: 0)
                currentKeyframeIndex = nil
                if player.play() {
                    synchronizeFrame(atMs: 0, connection: connection, force: true)
                    return
                }
                finishPlayback()
                return
            }
            positionMs = now
            finishPlayback()
            return
        }
        synchronizeFrame(atMs: now, connection: connection, force: false)
    }

    private func synchronizeFrame(atMs ms: Int, connection: BoardConnection, force: Bool) {
        if let frame = synchronizePreview(atMs: ms, force: force) {
            push(frame, positionMs: ms, connection: connection)
        } else if outputSession != nil,
                  lastSubmittedPositionMs.map({ abs(ms - $0) >= 1_000 }) ?? true {
            // A held keyframe still carries a playback heartbeat so reconnect
            // recovery does not jump back by the length of a static passage.
            push(previewFrame, positionMs: ms, connection: connection)
        }
    }

    @discardableResult
    private func synchronizePreview(atMs ms: Int, force: Bool) -> PackedFrame? {
        guard let script, let index = script.index(atMs: ms),
              composedFrames.indices.contains(index),
              force || index != currentKeyframeIndex else { return nil }
        currentKeyframeIndex = index
        let frame = composedFrames[index]
        previewFrame = frame
        return frame
    }

    private func push(_ frame: PackedFrame, positionMs: Int, connection: BoardConnection) {
        guard connection.connectionState == .connected, let token = outputSession,
              connection.output.isCurrent(token), let playbackStreamID else { return }
        lastSubmittedPositionMs = positionMs
        lastConnection = connection
        sender?.submit(PresetLiveSubmission(frame: frame, positionMs: positionMs,
                                            streamID: playbackStreamID, token: token))
    }

    private func send(_ submission: PresetLiveSubmission) async {
        guard let connection = lastConnection, connection.connectionState == .connected,
              outputSession == submission.token, connection.output.isCurrent(submission.token) else { return }
        do {
            let reasonPosition = min(max(0, submission.positionMs), 99_999_999_999_999)
            _ = try await connection.setFrame(submission.frame, playback: .idle,
                                              reason: "live_preset:\(submission.streamID):\(reasonPosition)",
                                              outputSession: submission.token)
        } catch is CancellationError {
        } catch RatePumpError.dropped {
            if outputSession == submission.token {
                lastSubmittedPositionMs = nil
            }
        } catch {
            guard outputSession == submission.token,
                  connection.output.isCurrent(submission.token) else { return }
            lastSubmittedPositionMs = nil
            errorMessage = String(format: NSLocalizedString("发送失败：%@", comment: "frame send failed"),
                                  error.localizedDescription)
        }
    }

    private func finishPlayback() {
        savePlaybackPosition(force: true)
        isPlaying = false
        pausedByUser = true
        suspendBoardOutput()
        clockTask?.cancel()
        clockTask = nil
        deactivateSessionIfNeeded()
        removeInterruptionObserver()
    }

    // MARK: Staging helpers

    private struct RestoredCustomMaterial {
        var script: LivePerformanceScript?
        var frames: [PackedFrame] = []
        var scriptName: String?
        var player: AVAudioPlayer?
        var audioTitle: String?
    }

    private func restoreCustomMaterial(loadAudio: Bool = true) -> RestoredCustomMaterial {
        var result = RestoredCustomMaterial()
        if let library,
           let name = defaults.string(forKey: Self.scriptFileKey) {
            let url = fileStore.storedURL(named: name)
            if let data = try? Data(contentsOf: url) {
                let scriptParseState = RinaPerf.signposter.beginInterval("PresetLiveScriptParse")
                let parsed = try? parseScript(data, library: library,
                                              encodingError: NSLocalizedString("脚本编码无效，需为 UTF-8 文本", comment: "script encoding invalid"))
                RinaPerf.signposter.endInterval("PresetLiveScriptParse", scriptParseState)
                if let parsed {
                    result.script = parsed
                    result.frames = parsed.composedFrames(using: library)
                    result.scriptName = defaults.string(forKey: Self.scriptTitleKey) ?? userFacingStoredName(name)
                }
            }
        }
        if loadAudio, let name = defaults.string(forKey: Self.audioFileKey) {
            let url = fileStore.storedURL(named: name)
            if let restored = try? prepareAudio(url) {
                result.player = restored
                result.audioTitle = defaults.string(forKey: Self.audioTitleKey) ?? userFacingStoredName(name)
            }
        }
        return result
    }

    private func restoreCheckpointMaterial() -> Bool {
        guard let material = defaults.string(forKey: Self.playbackMaterialKey) else { return false }
        if material.hasPrefix(Self.customPlaybackPrefix) {
            guard storedCustomPlaybackMaterial == material else { return false }
            guard activePlaybackMaterial != material else { return canPlay }
            enterCustom(persistSelection: false)
            return canPlay && activePlaybackMaterial == material
        }
        guard material.hasPrefix(Self.builtInPlaybackPrefix) else { return false }
        let remainder = material.dropFirst(Self.builtInPlaybackPrefix.count)
        guard let separator = remainder.firstIndex(of: "|") else { return false }
        let id = String(remainder[..<separator])
        guard activePlaybackMaterial != material,
              let performance = builtInPerformances.first(where: { $0.id == id }) else {
            return activePlaybackMaterial == material && canPlay
        }
        return selectBuiltIn(performance, persistSelection: false)
            && canPlay && activePlaybackMaterial == material
    }

    private var activePlaybackMaterial: String? {
        if let selectedBuiltIn {
            let audioIdentity = defaults.string(forKey: audioKey(for: selectedBuiltIn)) ?? "bundle"
            return Self.builtInPlaybackPrefix + selectedBuiltIn + "|" + audioIdentity
        }
        if isCustomMode { return storedCustomPlaybackMaterial }
        return nil
    }

    private var storedCustomPlaybackMaterial: String? {
        guard let script = defaults.string(forKey: Self.scriptFileKey),
              let audio = defaults.string(forKey: Self.audioFileKey) else { return nil }
        return Self.customPlaybackPrefix + script + "|" + audio
    }

    private func preparePlaybackStreamForCurrentMaterial(restoring: Bool) {
        guard canPlay, let material = activePlaybackMaterial else { return }
        if !restoring {
            let savedMaterial = defaults.string(forKey: Self.playbackMaterialKey)
            if savedMaterial != material || defaults.string(forKey: Self.playbackStreamKey) == nil {
                playbackStreamID = UUID().uuidString
            } else if playbackStreamID == nil {
                playbackStreamID = defaults.string(forKey: Self.playbackStreamKey)
            }
        }
        guard let playbackStreamID else { return }
        defaults.set(material, forKey: Self.playbackMaterialKey)
        defaults.set(playbackStreamID, forKey: Self.playbackStreamKey)
    }

    private func reportMissingOriginalStream() {
        errorMessage = NSLocalizedString("无法找到此演出的原始播放流", comment: "performance recovery stream missing")
    }

    /// UserDefaults writes are throttled to roughly twice per second while
    /// playing, with exact checkpoints at transport and lifecycle boundaries.
    private func savePlaybackPosition(force: Bool, atMs: Int? = nil) {
        guard player != nil else { return }
        let checkpoint = max(0, min(durationMs, atMs ?? positionMs))
        if !force, let lastPersistedPositionMs,
           abs(checkpoint - lastPersistedPositionMs) < 500 { return }
        defaults.set(checkpoint, forKey: Self.playbackPositionKey)
        lastPersistedPositionMs = checkpoint
    }

    private func parseScript(_ data: Data, library: PartsLibrary,
                             encodingError: String) throws -> LivePerformanceScript {
        try Self.parseScript(data, library: library, encodingError: encodingError)
    }

    nonisolated private static func parseScript(_ data: Data, library: PartsLibrary,
                                                encodingError: String) throws -> LivePerformanceScript {
        guard let text = String(data: data, encoding: .utf8) else {
            throw PresetLiveImportError.message(encodingError)
        }
        return try LivePerformanceScriptParser.parse(text, library: library)
    }

    private func prepareAudio(_ url: URL) throws -> AVAudioPlayer {
        let loaded: AVAudioPlayer
        do {
            let audioInitState = RinaPerf.signposter.beginInterval("PresetLiveAudioInit")
            defer { RinaPerf.signposter.endInterval("PresetLiveAudioInit", audioInitState) }
            loaded = try AVAudioPlayer(contentsOf: url)
        }
        loaded.volume = isMuted ? 0 : 1
        // prepareToPlay() activates the shared audio session. Importing or
        // restoring a file must not acquire audio hardware on the main thread;
        // play() prepares it after startPlayback activates our session.
        return loaded
    }

    private func commit(script: LivePerformanceScript?, frames: [PackedFrame], scriptName: String?,
                        player: AVAudioPlayer?, audioTitle: String?,
                        selectedBuiltIn: BuiltInPerformance.ID?, customMode: Bool) {
        let commitState = RinaPerf.signposter.beginInterval("PresetLiveCommit")
        defer { RinaPerf.signposter.endInterval("PresetLiveCommit", commitState) }
        stop()
        self.script = script
        self.scriptName = scriptName
        self.composedFrames = frames
        self.player = player
        self.audioTitle = audioTitle
        self.selectedBuiltIn = selectedBuiltIn
        self.isCustomMode = customMode
        self.positionMs = 0
        self.durationMs = player.map { Int($0.duration * 1000) } ?? script?.durationMs ?? 0
        self.previewFrame = frames.first ?? PackedFrame()
        self.currentKeyframeIndex = nil
    }

    private func audioKey(for id: String) -> String { "performanceAudio.\(id)" }

    func hasAudioAvailable(for performance: BuiltInPerformance) -> Bool {
        if let name = defaults.string(forKey: audioKey(for: performance.id)),
           FileManager.default.fileExists(atPath: fileStore.storedURL(named: name).path) {
            return true
        }
        return performance.audioURL(in: bundle) != nil
    }

    private func userFacingStoredName(_ name: String) -> String {
        guard name.count > 37 else { return name }
        let separator = name.index(name.startIndex, offsetBy: 36)
        guard name[separator] == "-",
              UUID(uuidString: String(name.prefix(36))) != nil else { return name }
        return String(name[name.index(after: separator)...])
    }

    private func removeReplacedStoredFile(named previousName: String?, keeping newURL: URL) {
        guard let previousName else { return }
        let previousURL = fileStore.storedURL(named: previousName)
        guard previousURL != newURL else { return }
        fileStore.remove(previousURL)
    }

    private func importErrorDescription(_ error: Error) -> String {
        if case PresetLiveImportError.message(let value) = error { return value }
        if case PresetLiveImportError.selectionChanged = error {
            return NSLocalizedString("所选歌曲已改变，请重新导入", comment: "performance selection changed during import")
        }
        if case PresetLiveImportError.partsUnavailable = error {
            return NSLocalizedString("无法加载部件库", comment: "parts library unavailable")
        }
        if error is LivePerformanceScriptError { return String(describing: error) }
        return error.localizedDescription
    }
}

private enum PresetLiveImportError: Error {
    case message(String)
    case selectionChanged
    case partsUnavailable
}
