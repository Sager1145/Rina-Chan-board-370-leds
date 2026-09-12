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
    private(set) var positionMs = 0
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

    private let bundle: Bundle
    private let defaults: UserDefaults
    private let fileStore: PresetLiveFileStore
    private var library: PartsLibrary?
    private var player: AVAudioPlayer?
    private var outputSession: UUID?
    private var frameTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var didRestore = false
    private var didLoadDemo = false
    private var sessionActive = false
    @ObservationIgnored private var playbackStartTask: Task<Void, Never>?
    private var pausedByUser = true
    private var isAcquiringOutput = false
    private var interruptionObserver: NSObjectProtocol?
    private weak var lastConnection: BoardConnection?

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
            let parsed = try parseScript(data, library: library,
                                         encodingError: NSLocalizedString("演出脚本编码无效", comment: "built-in script encoding invalid"))
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

    private func enterCustom(persistSelection: Bool) {
        let prepared = restoreCustomMaterial()
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
    func importAudio(from url: URL) {
        if let selectedBuiltIn {
            importAudio(from: url, forBuiltIn: selectedBuiltIn)
        } else {
            importCustomAudio(from: url)
        }
    }

    func importAudio(from url: URL, forBuiltIn id: BuiltInPerformance.ID) {
        withImportedURL(url, failureFormat: NSLocalizedString("导入音频失败：%@", comment: "audio import failed")) {
            guard selectedBuiltIn == id else {
                throw PresetLiveImportError.selectionChanged
            }
            let storageKey = audioKey(for: id)
            let previousName = defaults.string(forKey: storageKey)
            let stagedPlayer = try prepareAudio(url)
            let copy = try fileStore.copyIntoStorage(url)
            // Validate the stored copy too; a provider can expose a readable
            // coordinated URL whose copied bytes are incomplete or changed.
            let storedPlayer: AVAudioPlayer
            do {
                storedPlayer = try prepareAudio(copy)
                guard selectedBuiltIn == id else { throw PresetLiveImportError.selectionChanged }
            } catch {
                fileStore.remove(copy)
                throw error
            }
            stop()
            player = storedPlayer
            audioTitle = builtInPerformances.first(where: { $0.id == id })?.title ?? url.lastPathComponent
            durationMs = Int(storedPlayer.duration * 1000)
            positionMs = 0
            currentKeyframeIndex = nil
            previewFrame = composedFrames.first ?? PackedFrame()
            defaults.set(copy.lastPathComponent, forKey: storageKey)
            removeReplacedStoredFile(named: previousName, keeping: copy)
            _ = stagedPlayer // Validation deliberately occurs before copying.
            errorMessage = nil
        }
    }

    func importScript(from url: URL) {
        withImportedURL(url, failureFormat: NSLocalizedString("导入脚本失败：%@", comment: "script import failed")) {
            guard let library else { throw PresetLiveImportError.partsUnavailable }
            let data = try Data(contentsOf: url)
            let parsed = try parseScript(data, library: library,
                                         encodingError: NSLocalizedString("脚本编码无效，需为 UTF-8 文本", comment: "script encoding invalid"))
            let frames = parsed.composedFrames(using: library)
            let previousName = defaults.string(forKey: Self.scriptFileKey)
            let copy = try fileStore.copyIntoStorage(url)
            if !isCustomMode { enterCustom(persistSelection: false) }
            commit(script: parsed, frames: frames, scriptName: url.lastPathComponent,
                   player: player, audioTitle: audioTitle,
                   selectedBuiltIn: nil, customMode: true)
            defaults.set(copy.lastPathComponent, forKey: Self.scriptFileKey)
            removeReplacedStoredFile(named: previousName, keeping: copy)
            defaults.set(url.lastPathComponent, forKey: Self.scriptTitleKey)
            defaults.set(true, forKey: Self.customModeKey)
            errorMessage = nil
        }
    }

    func importCustomAudio(from url: URL) {
        withImportedURL(url, failureFormat: NSLocalizedString("导入音频失败：%@", comment: "audio import failed")) {
            _ = try prepareAudio(url)
            let previousName = defaults.string(forKey: Self.audioFileKey)
            let copy = try fileStore.copyIntoStorage(url)
            let storedPlayer: AVAudioPlayer
            do { storedPlayer = try prepareAudio(copy) }
            catch { fileStore.remove(copy); throw error }
            if !isCustomMode { enterCustom(persistSelection: false) }
            commit(script: script, frames: composedFrames, scriptName: scriptName,
                   player: storedPlayer, audioTitle: url.lastPathComponent,
                   selectedBuiltIn: nil, customMode: true)
            defaults.set(copy.lastPathComponent, forKey: Self.audioFileKey)
            removeReplacedStoredFile(named: previousName, keeping: copy)
            defaults.set(url.lastPathComponent, forKey: Self.audioTitleKey)
            defaults.set(true, forKey: Self.customModeKey)
            errorMessage = nil
        }
    }

    private func withImportedURL(_ url: URL, failureFormat: String, operation: () throws -> Void) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try operation()
        } catch {
            errorMessage = String(format: failureFormat, importErrorDescription(error))
        }
    }

    // MARK: Board output and local playback

    func suspendBoardOutput() {
        outputSession = nil
        frameTask?.cancel()
        frameTask = nil
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

    func play(connection: BoardConnection) {
        playbackStartTask?.cancel()
        player?.pause()
        deactivateSessionIfNeeded()
        playbackStartTask = Task { [weak self] in
            await self?.startPlayback(connection: connection)
        }
    }

    private func startPlayback(connection: BoardConnection) async {
        guard !Task.isCancelled else { return }
        guard canPlay, let player else {
            errorMessage = NSLocalizedString("请先选择有效的脚本和音频", comment: "performance needs script and audio")
            return
        }
        if connection.connectionState == .connected {
            isAcquiringOutput = true
            outputSession = connection.output.begin(.performance)
            isAcquiringOutput = false
        } else {
            outputSession = nil
        }
        pausedByUser = false
        lastConnection = connection
        guard await activateSessionIfNeeded() else {
            if !Task.isCancelled { suspendBoardOutput() }
            return
        }
        guard !Task.isCancelled else { return }
        guard player.play() else {
            deactivateSessionIfNeeded()
            suspendBoardOutput()
            errorMessage = NSLocalizedString("无法开始播放音频", comment: "audio playback start failed")
            isPlaying = false
            return
        }
        registerInterruptionObserverIfNeeded()
        isPlaying = true
        currentKeyframeIndex = nil
        positionMs = Int(player.currentTime * 1000)
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
        positionMs = Int(player.currentTime * 1000)
        if !player.isPlaying, isPlaying {
            if loops {
                player.currentTime = 0
                positionMs = 0
                currentKeyframeIndex = nil
                if player.play() {
                    synchronizeFrame(atMs: 0, connection: connection, force: true)
                    return
                }
            }
            finishPlayback()
            return
        }
        synchronizeFrame(atMs: positionMs, connection: connection, force: false)
    }

    private func synchronizeFrame(atMs ms: Int, connection: BoardConnection, force: Bool) {
        guard let frame = synchronizePreview(atMs: ms, force: force) else { return }
        push(frame, connection: connection)
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

    private func push(_ frame: PackedFrame, connection: BoardConnection) {
        guard connection.connectionState == .connected, let token = outputSession,
              connection.output.isCurrent(token) else { return }
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            do {
                _ = try await connection.setFrame(frame, playback: .idle,
                                                  reason: "live_preset",
                                                  outputSession: token)
            } catch is CancellationError {
            } catch RatePumpError.dropped {
            } catch {
                guard let self, self.outputSession == token,
                      connection.output.isCurrent(token) else { return }
                self.errorMessage = String(format: NSLocalizedString("发送失败：%@", comment: "frame send failed"),
                                           error.localizedDescription)
            }
        }
    }

    private func finishPlayback() {
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

    private func restoreCustomMaterial() -> RestoredCustomMaterial {
        var result = RestoredCustomMaterial()
        if let library,
           let name = defaults.string(forKey: Self.scriptFileKey) {
            let url = fileStore.storedURL(named: name)
            if let data = try? Data(contentsOf: url),
               let parsed = try? parseScript(data, library: library,
                                             encodingError: NSLocalizedString("脚本编码无效，需为 UTF-8 文本", comment: "script encoding invalid")) {
                result.script = parsed
                result.frames = parsed.composedFrames(using: library)
                result.scriptName = defaults.string(forKey: Self.scriptTitleKey) ?? userFacingStoredName(name)
            }
        }
        if let name = defaults.string(forKey: Self.audioFileKey) {
            let url = fileStore.storedURL(named: name)
            if let restored = try? prepareAudio(url) {
                result.player = restored
                result.audioTitle = defaults.string(forKey: Self.audioTitleKey) ?? userFacingStoredName(name)
            }
        }
        return result
    }

    private func parseScript(_ data: Data, library: PartsLibrary,
                             encodingError: String) throws -> LivePerformanceScript {
        guard let text = String(data: data, encoding: .utf8) else {
            throw PresetLiveImportError.message(encodingError)
        }
        return try LivePerformanceScriptParser.parse(text, library: library)
    }

    private func prepareAudio(_ url: URL) throws -> AVAudioPlayer {
        let loaded = try AVAudioPlayer(contentsOf: url)
        loaded.volume = isMuted ? 0 : 1
        loaded.prepareToPlay()
        return loaded
    }

    private func commit(script: LivePerformanceScript?, frames: [PackedFrame], scriptName: String?,
                        player: AVAudioPlayer?, audioTitle: String?,
                        selectedBuiltIn: BuiltInPerformance.ID?, customMode: Bool) {
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
