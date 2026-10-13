import AVFoundation
import CoreBluetooth
import CoreVideo
import Foundation
import RinaCore
import XCTest
@testable import RinaBoard

#if targetEnvironment(macCatalyst)
/// Deliberately serial: this suite owns both physical carriers until restoration
/// and CoreBluetooth's terminal disconnect callbacks complete. Never run it
/// concurrently with another hardware suite or the interactive app.
@MainActor
final class MacFeatureHardwareTests: XCTestCase {
    private let boardIDs = ["80B54EF48E09", "80B54EF74801"]

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Original: Codable {
        let id: String
        let status: DeviceStatus
        let frameHex: String
        let faces: FaceDocument
        let scroll: ScrollMeta
        let deviceName: String?
        let customName: Bool?
        let bootID: String
    }

    /// Tracks the production model's PCM pulls while forwarding every audio
    /// operation to the real AVAudioEngine capture. No injected microphone.
    private final class CaptureProbe: LipSyncCapturing, @unchecked Sendable {
        let capture = LipSyncAudioCapture()
        private let lock = NSLock()
        private var reads = 0
        @MainActor func start() async throws { try await capture.start() }
        func stop() { capture.stop() }
        var isRunning: Bool { capture.isRunning }
        var currentSampleRate: Double { capture.currentSampleRate }
        var sampledWindows: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double) {
            let window = capture.latestWindow(count: count)
            lock.lock(); reads += 1; lock.unlock()
            return window
        }
    }

    @MainActor
    private final class Rig {
        let id: String
        let session: BoardSession
        let transport: BLETransport
        var original: Original?
        var touched = false
        let temporaryName: String
        var temporaryIDs = Set<String>()
        init(id: String, session: BoardSession) throws {
            self.id = id
            self.session = session
            self.transport = try XCTUnwrap(session.bleTransport as? BLETransport)
            self.temporaryName = "Mac hardware \(UUID().uuidString.prefix(8))"
        }
        var connection: BoardConnection { session.connection }
    }

    func testAllFeaturesOnBothRealBoardsAndRestore() async throws {
        guard ProcessInfo.processInfo.environment["RINA_MAC_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set RINA_MAC_HARDWARE_TESTS=1 for the two real boards")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rina-mac-features-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suiteName = "rina.mac.hardware.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }
        let sessions = BoardSessionStore()
        let rigs = try boardIDs.map { id in
            try Rig(id: id, session: sessions.session(for: id, name: "RinaBoard-\(id)"))
        }
        let scanner = try XCTUnwrap(sessions.scanner as? BLETransport)
        let groupStore = BoardGroupStore(defaults: defaults)
        let coordinator = BoardGroupCoordinator(store: groupStore, sessions: sessions)
        sessions.isGroupOwned = { coordinator.isGroupOwned($0) }
        let fanOut = GroupControlFanOut(sessions: sessions, groups: groupStore, coordinator: coordinator)
        let transportModel = ConnectionViewModel(startBonjourBrowsing: false)
        let transportBoards = BoardStore(defaults: defaults)
        var activeGroup: BoardGroup?
        var testError: Error?
        do {
            try await connect(rigs, scanner: scanner)
            for rig in rigs {
                let connection = rig.connection
                try await wait("\(rig.id) provisioned station Wi-Fi readiness", timeout: 25) {
                    let status = try await connection.getStatus()
                    return status.wifi?.staConnected == true && status.wifi?.ip != nil && status.wifi?.ip != "0.0.0.0"
                }
                let status = try await connection.getStatus()
                let faces = try FaceDocument(jsonData: await connection.getFaces())
                let frame = try await connection.getFrame()
                let scroll = try await connection.getScrollMeta()
                let info = try await connection.command(.getInfo)
                try require(info.ok, "\(rig.id): get_info snapshot")
                let bootID = try XCTUnwrap(info.bootId)
                try require(!bootID.isEmpty, "\(rig.id): boot identity snapshot")
                rig.original = Original(id: rig.id, status: status, frameHex: frame.hex94, faces: faces, scroll: scroll, deviceName: info.name, customName: info.customName, bootID: bootID)
                transportBoards.upsert(KnownBoard(id: try XCTUnwrap(rig.transport.peripheralIdentifier).uuidString,
                                                 name: info.name ?? rig.id, lastHost: status.wifi?.ip))
            }
            // This recovery file deliberately stays outside scratch after the run. It
            // contains board telemetry and faces, never credential passwords.
            let originals = rigs.compactMap(\.original)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let recoveryURL = FileManager.default.temporaryDirectory.appendingPathComponent("rina-full-feature-originals.json")
            try encoder.encode(originals).write(to: recoveryURL, options: .atomic)
            print("Full feature recovery snapshot: \(recoveryURL.path)")
            for rig in rigs {
                let original = try XCTUnwrap(rig.original)
                try require(original.status.wifi?.boardId?.uppercased() == rig.id, "\(rig.id): status identity")
                try require(original.status.wifi?.staConnected == true, "\(rig.id): provision test Wi-Fi before the BLE coexistence run")
                try require(rig.connection.transportKind == .bluetooth, "\(rig.id): coexistence commands must use production BLE")
                try require((original.scroll.frameCount ?? 0) == 0 && original.scroll.firmwareScrollActive != true,
                            "\(rig.id): resident scroll cannot be backed up; refusing destructive timeline replacement")
                let renderer = try XCTUnwrap(original.status.renderer)
                try require(["manual", "auto"].contains(renderer.mode ?? "") &&
                            !["text", "video", "performance", "lipSync"].contains(renderer.outputMode ?? ""),
                            "\(rig.id): original output is not safely restorable manual/auto")
                _ = try XCTUnwrap(renderer.brightness)
                _ = try XCTUnwrap(renderer.color)
                _ = try XCTUnwrap(renderer.autoIntervalMs)
                try require(!original.faces.faces.isEmpty && original.faces.sortedFaces.enumerated().allSatisfy { index, face in face.order == index + 1 },
                            "\(rig.id): face reorder would renumber noncanonical original ranks; refusing to change them")
            }
            let media = try await makeMedia(in: scratch)
            var featureFailures: [String] = []
            for rig in rigs {
                rig.touched = true // Arm before any potentially applied write.
                let features: [(String, @MainActor () async throws -> Void)] = [
                    ("controls/faces", { try await self.exerciseControlsAndFaces(rig, scratch: scratch) }),
                    ("name/network scan", { try await self.exerciseNameAndScan(rig, defaults: defaults) }),
                    ("text", { try await self.exerciseText(rig) }),
                    ("performance", { try await self.exercisePerformance(rig, defaults: defaults, scratch: scratch, audio: media.audio) }),
                    ("video", { try await self.exerciseVideo(rig, defaults: defaults, scratch: scratch, video: media.video) }),
                    ("microphone", { try await self.exerciseMicrophone(rig, defaults: defaults) }),
                    ("debug", { try await self.exerciseDebugAndTelemetry(rig) })
                ]
                for (name, exercise) in features {
                    do { try await exercise() }
                    catch {
                        featureFailures.append("\(rig.id) \(name): \(error.localizedDescription)")
                        print("[MacFeatureHardwareTests] FAIL \(rig.id) \(name): \(error.localizedDescription)")
                        // Later coverage is meaningful only while the exact
                        // original carrier is still ready.
                        if rig.connection.connectionState != .connected { break }
                    }
                }
            }
            var group = groupStore.create(name: "Temporary hardware group")
            for rig in rigs {
                try groupStore.addMember(groupID: group.id, member: .init(physicalBoardID: rig.id, displayName: rig.id))
            }
            groupStore.setMode(id: group.id, mode: .mirror)
            group = try XCTUnwrap(groupStore.groups.first { $0.id == group.id })
            activeGroup = group
            for carrier in ["bothBLE", "mixedBLEAndTCP", "bothTCP"] {
                do {
                    if carrier == "mixedBLEAndTCP" {
                        try await selectCarrier(.wifi, rig: rigs[1], rigs: rigs, sessions: sessions, model: transportModel, boards: transportBoards)
                    } else if carrier == "bothTCP" {
                        try await selectCarrier(.wifi, rig: rigs[0], rigs: rigs, sessions: sessions, model: transportModel, boards: transportBoards)
                    }
                    storeMirrorGroup(group.id, store: groupStore)
                    let currentGroup = try XCTUnwrap(groupStore.groups.first { $0.id == group.id })
                    try await exerciseGroup(currentGroup, rigs: rigs, store: groupStore, coordinator: coordinator,
                                            fanOut: fanOut, scratch: scratch, defaults: defaults, audio: media.audio,
                                            video: media.video, carrier: carrier)
                } catch {
                    featureFailures.append("group \(carrier): \(error.localizedDescription)")
                    if let currentGroup = groupStore.groups.first(where: { $0.id == group.id }) {
                        await coordinator.stop(group: currentGroup)
                    }
                    fanOut.setTarget(.single)
                }
            }
            do {
                storeMirrorGroup(group.id, store: groupStore)
                let currentGroup = try XCTUnwrap(groupStore.groups.first { $0.id == group.id })
                try await exerciseActiveGroupRecovery(currentGroup, rigs: rigs, coordinator: coordinator, fanOut: fanOut,
                                                      sessions: sessions, model: transportModel, boards: transportBoards)
            } catch {
                featureFailures.append("active group carrier/member recovery: \(error.localizedDescription)")
                if let currentGroup = groupStore.groups.first(where: { $0.id == group.id }) { await coordinator.stop(group: currentGroup) }
                fanOut.setTarget(.single)
            }
            // Exercise the public transport selector in the reverse direction
            // before any restoration, retaining the original BLE carriers.
            for rig in rigs {
                do { try await selectCarrier(.bluetooth, rig: rig, rigs: rigs, sessions: sessions, model: transportModel, boards: transportBoards) }
                catch { featureFailures.append("\(rig.id) return to BLE: \(error.localizedDescription)") }
            }
            try require(featureFailures.isEmpty, featureFailures.joined(separator: "\n"))
        } catch { testError = error }

        // Unstructured producer stops happen before restoring the board. The
        // detached task cannot inherit a failed/cancelled test's cancellation.
        let groupForCleanup = activeGroup
        let cleanup = Task.detached { @MainActor in
            fanOut.setTarget(.single)
            if let groupForCleanup {
                let current = groupStore.groups.first { $0.id == groupForCleanup.id } ?? groupForCleanup
                await coordinator.stop(group: current)
            }
            coordinator.stopIdentifyLoop()
            scanner.stopScan()
            var failures: [String] = []
            for rig in rigs {
                if rig.touched, let original = rig.original {
                    // A failed mixed-carrier run may leave this board on TCP.
                    // Recover the owned BLE carrier before attempting cleanup.
                    do {
                        if rig.connection.transportKind != .bluetooth || rig.connection.connectionState != .connected {
                            await transportModel.selectTransport(.bluetooth, session: rig.session, sessions: sessions, boardStore: transportBoards)
                            try self.require(rig.connection.transportKind == .bluetooth && rig.connection.connectionState == .connected,
                                             "\(rig.id): cleanup could not restore BLE carrier")
                        }
                        try await self.restore(rig, original: original)
                        // Test the production reboot command only after all
                        // persistent state and the original output are back.
                        // Fresh boot also discards the test's RAM scroll blob.
                        var rebootFailure: Error?
                        do { try await self.rebootAndReconnect(rig, original: original) }
                        catch { rebootFailure = error }
                        // Always restore transient color/brightness/frame even
                        // when the read-only persistence validation fails.
                        try await self.restore(rig, original: original)
                        if let rebootFailure { throw rebootFailure }
                    }
                    catch { failures.append("\(rig.id): restoration: \(error.localizedDescription)") }
                }
                rig.connection.disconnect(userInitiated: true)
                do {
                    let confirmed = try await rig.transport.disconnectAndWait(timeout: 8)
                    if !confirmed { failures.append("\(rig.id): terminal BLE disconnect unconfirmed") }
                    print("[MacFeatureHardwareTests] \(rig.id) terminalDisconnectConfirmed=\(confirmed)")
                } catch { failures.append("\(rig.id): disconnect: \(error.localizedDescription)") }
            }
            return failures
        }
        let cleanupFailures = await cleanup.value
        for failure in cleanupFailures { XCTFail(failure) }
        if let testError { throw testError }
        try require(cleanupFailures.isEmpty, "Hardware cleanup failed")
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private func wait(_ label: String, timeout: TimeInterval = 8,
                      condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if try await condition() { return }
            try require(Date() < deadline, "Timed out: \(label)")
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func connect(_ rigs: [Rig], scanner: BLETransport) async throws {
        try await wait("Bluetooth scan readiness", timeout: 35) {
            try self.require(CBManager.authorization != .denied && CBManager.authorization != .restricted,
                             "Mac test host Bluetooth permission denied")
            if !scanner.isScanning { scanner.startScan() }
            return scanner.isScanning
        }
        try await wait("Exact two advertisements", timeout: 35) {
            rigs.allSatisfy { rig in scanner.discoveredPeripherals.contains { $0.advertisedName == "RinaBoard-\(rig.id)" } }
        }
        for rig in rigs {
            rig.transport.peripheralIdentifier = try XCTUnwrap(scanner.discoveredPeripherals.first {
                $0.advertisedName == "RinaBoard-\(rig.id)"
            }?.id)
        }
        scanner.stopScan()
        for rig in rigs {
            try require(await rig.connection.connect(using: rig.transport), "\(rig.id): handshake \(rig.connection.lastError ?? "failed")")
            try require(rig.connection.boardIdentity == rig.id, "\(rig.id): physical identity mismatch")
        }
        try require(rigs.allSatisfy { $0.connection.connectionState == .connected }, "Both independent BLE sessions must stay connected")
    }

    private func exerciseControlsAndFaces(_ rig: Rig, scratch: URL) async throws {
        let connection = rig.connection
        let original = try XCTUnwrap(rig.original)
        let controls = BoardControlCenterModel()
        defer { controls.connectionChanged() }
        controls.sync(from: try await connection.getStatus())
        if controls.isAutoMode(status: connection.status) { await controls.toggleAutoMode(connection: connection) }
        try require((try await connection.getStatus()).renderer?.mode == "manual", "\(rig.id): manual mode")
        let brightness = try XCTUnwrap(original.status.renderer?.brightness)
        let probe = brightness == RinaLinkConstants.brightnessMin ? brightness + 1 : brightness - 1
        controls.setBrightness(probe, connection: connection)
        try await wait("\(rig.id) brightness") { (try await connection.getStatus()).renderer?.brightness == probe }
        let coexistence = try await connection.getStatus()
        try require(coexistence.wifi?.staConnected == true && rig.connection.transportKind == .bluetooth,
                    "\(rig.id): Bluetooth command/readback while station Wi-Fi stays connected")
        print("[MacFeatureHardwareTests] \(rig.id) bluetoothUsableWithWiFiEnabled=true")
        controls.setAutoInterval(1, connection: connection)
        try await wait("\(rig.id) auto interval") { (try await connection.getStatus()).renderer?.autoIntervalMs == 1000 }
        await controls.setColor(hex: "#315E99", connection: connection)
        try await wait("\(rig.id) color") { (try await connection.getStatus()).renderer?.color?.uppercased() == "#315E99" }
        let beforeStep = try await connection.getStatus()
        let oldIndex = try XCTUnwrap(beforeStep.renderer?.autoFaceIndex)
        let count = try XCTUnwrap(connection.status?.renderer?.autoFaceCount)
        await controls.step(face: 1, connection: connection)
        try require((try await connection.getStatus()).renderer?.autoFaceIndex == (oldIndex + 1) % count, "\(rig.id): next expression")
        await controls.step(face: -1, connection: connection)
        try require((try await connection.getStatus()).renderer?.autoFaceIndex == oldIndex, "\(rig.id): previous expression")
        await controls.toggleAutoMode(connection: connection)
        try require((try await connection.getStatus()).renderer?.mode == "auto", "\(rig.id): automatic mode")
        let autoIndex = connection.status?.renderer?.autoFaceIndex
        try await wait("\(rig.id) automatic face advance", timeout: 4) { (try await connection.getStatus()).renderer?.autoFaceIndex != autoIndex }
        await controls.toggleAutoMode(connection: connection)

        let editor = ControlViewModel(draftStorage: DraftStorage(directory: scratch.appendingPathComponent("draft-\(rig.id)")))
        defer { editor.releaseOutput() }
        editor.livePreview = false
        editor.clear(connection: connection)
        editor.toggle(led: 20, connection: connection)
        editor.toggle(led: 200, connection: connection)
        await editor.send(connection: connection)
        try require(try await connection.getFrame() == editor.draftFrame, "\(rig.id): editor send frame")
        editor.undo(connection: connection)
        await editor.send(connection: connection)
        try require(try await connection.getFrame() == editor.draftFrame && editor.draftFrame.litCount == 1, "\(rig.id): editor undo")
        editor.invert(connection: connection)
        await editor.send(connection: connection)
        try require(try await connection.getFrame() == editor.draftFrame && editor.draftFrame.litCount == 369, "\(rig.id): editor invert")
        editor.clear(connection: connection)
        editor.mirrorDrawing = true
        try require(editor.paint(led: 20, connection: connection), "\(rig.id): mirrored brush stroke admission")
        editor.endStroke()
        await editor.send(connection: connection)
        try require(try await connection.getFrame() == editor.draftFrame && editor.draftFrame.litCount == 2, "\(rig.id): mirrored drawing stroke readback")
        editor.livePreview = true
        editor.toggle(led: 200, connection: connection)
        try await wait("\(rig.id) live editor preview") { try await connection.getFrame() == editor.draftFrame }
        editor.livePreview = false
        editor.resetPartsToDefault(connection: connection)
        editor.setSyncEyes(true, connection: connection)
        await editor.send(connection: connection)
        try require(try await connection.getFrame() == editor.draftFrame && !editor.draftFrame.isEmpty, "\(rig.id): parts composition")

        let library = FaceLibraryModel(localStore: LocalFaceStore(fileURL: scratch.appendingPathComponent("faces-\(rig.id).json")))
        try require(await library.reload(connection: connection), "\(rig.id): faces read")
        let before = Set(library.faceDocument.faces.map(\.id))
        let outcome = await library.save(.init(name: rig.temporaryName, type: "custom", frameHex: editor.draftFrame.hex94), connection: connection)
        // Capture a write that landed even when the model reports an error.
        let document = try FaceDocument(jsonData: await connection.getFaces())
        rig.temporaryIDs.formUnion(document.faces.filter { !before.contains($0.id) && $0.name == rig.temporaryName }.map(\.id))
        guard case .saved(let savedID) = outcome else { throw Failure(message: "\(rig.id): face create \(library.errorMessage ?? "failed")") }
        let id = try XCTUnwrap(savedID)
        rig.temporaryIDs.insert(id)
        try require(await library.reload(connection: connection), "\(rig.id): created face reload")
        var face = try XCTUnwrap(library.face(id: id, in: .board))
        try require(face.packedFrame == editor.draftFrame, "\(rig.id): saved frame readback")
        await library.rename(face, to: rig.temporaryName + " renamed", connection: connection)
        try require(await library.reload(connection: connection), "\(rig.id): rename reload")
        face = try XCTUnwrap(library.face(id: id, in: .board))
        try require(face.name == rig.temporaryName + " renamed", "\(rig.id): rename readback")
        var updatedFrame = editor.draftFrame
        updatedFrame.toggle(100)
        let update = await library.save(.init(id: id, name: face.name, type: "custom", frameHex: updatedFrame.hex94,
                                             expect: FaceExpectation(name: face.name, frameHex: try XCTUnwrap(face.packedFrame).hex94)),
                                        connection: connection)
        try require(update == .saved(id: id), "\(rig.id): temporary face content update")
        try require(await library.reload(connection: connection), "\(rig.id): updated face reload")
        face = try XCTUnwrap(library.face(id: id, in: .board))
        try require(face.packedFrame == updatedFrame, "\(rig.id): updated face content readback")
        let duplicate = await library.duplicate(face, from: .board, connection: connection)
        guard case .saved(let duplicateID) = duplicate else { throw Failure(message: "\(rig.id): duplicate temporary face") }
        let copyID = try XCTUnwrap(duplicateID)
        rig.temporaryIDs.insert(copyID)
        try require(await library.reload(connection: connection), "\(rig.id): duplicate reload")
        var reordered = library.faces(in: .board)
        let firstPosition = try XCTUnwrap(reordered.firstIndex { $0.id == id })
        let secondPosition = try XCTUnwrap(reordered.firstIndex { $0.id == copyID })
        reordered.swapAt(firstPosition, secondPosition)
        try require(await library.reorderFaces(reordered, connection: connection), "\(rig.id): reorder temporary faces")
        let orderReadback = try FaceDocument(jsonData: await connection.getFaces())
        try require(orderReadback.sortedFaces.map(\.id) == reordered.map(\.id), "\(rig.id): reorder board readback")
        try require(await library.reload(connection: connection), "\(rig.id): reordered reload")
        face = try XCTUnwrap(library.face(id: id, in: .board))
        try require(await library.apply(face, connection: connection), "\(rig.id): apply temporary saved face")
        try require(try await connection.getFrame() == face.packedFrame, "\(rig.id): saved face displayed")
        let export = try XCTUnwrap(library.exportData(faces: [face], from: .board))
        let exported = try FaceDocument(jsonData: export)
        try require(exported.faces.count == 1 && exported.faces[0].packedFrame == face.packedFrame, "\(rig.id): face export")
        await library.importDocument(from: export, to: .local, connection: connection)
        try require(library.errorMessage == nil && library.userFaces(in: .local).contains { $0.packedFrame == face.packedFrame }, "\(rig.id): isolated local import")
        await library.delete(face, connection: connection)
        let copiedFace = try XCTUnwrap(library.face(id: copyID, in: .board))
        await library.delete(copiedFace, connection: connection)
        let after = try FaceDocument(jsonData: await connection.getFaces())
        try require(!after.faces.contains { $0.id == id }, "\(rig.id): temporary face delete readback")
        print("[MacFeatureHardwareTests] \(rig.id) controlsEditorFaces=true")
    }

    private func exerciseText(_ rig: Rig) async throws {
        let connection = rig.connection
        let text = TextViewModel() // Never restore/persist the user's draft.
        defer { text.releaseOutput(); text.suspendPreviewLoop() }
        text.text = "RINA 370"
        text.requestedFps = 10
        await text.send(connection: connection)
        try require(text.errorMessage == nil && text.boundTimelineId != nil, "\(rig.id): text upload \(text.errorMessage ?? "missing timeline")")
        let meta = try await connection.getScrollMeta()
        try require(meta.uploadComplete == true && meta.sourceText == text.text && meta.frameCount == text.frameCount && meta.scrollTimelineId == text.boundTimelineId,
                    "\(rig.id): uploaded text metadata")
        let first = try await connection.getPreviewSync()
        try await wait("\(rig.id) scroll progression") {
            let next = try await connection.getPreviewSync()
            return next.scrollAdvanceSeq != first.scrollAdvanceSeq && next.scrollAdvanceSeq != nil
        }
        await text.pause(connection: connection)
        try await wait("\(rig.id) text paused") { (try await connection.getStatus()).renderer?.firmwareScrollPaused == true }
        await text.seek(toFrame: 2, connection: connection)
        let paused = try await connection.getPreviewSync()
        try require(paused.frameIndex == 2 || paused.presentedFrameIndex == 2, "\(rig.id): text seek telemetry")
        let timeline = try XCTUnwrap(text.timeline)
        try require(try await connection.getFrame() == timeline.frames[2], "\(rig.id): text seek exact frame")
        await text.stepFrame(direction: 1, connection: connection)
        try require(try await connection.getFrame() == timeline.frames[3], "\(rig.id): text step exact frame")
        // Pause/resume's documented tap lockout is 250 ms.
        try await Task.sleep(for: .milliseconds(300))
        await text.resume(connection: connection)
        try await wait("\(rig.id) text resumed") { (try await connection.getStatus()).renderer?.firmwareScrollPaused == false }
        text.setRequestedFps(12, connection: connection)
        try await wait("\(rig.id) text speed") { (try await connection.getScrollMeta()).uiFps == 12 }
        await text.stop(connection: connection)
        try require((try await connection.getStatus()).renderer?.firmwareScrollActive == false, "\(rig.id): text stopped")
        print("[MacFeatureHardwareTests] \(rig.id) textUploadPlaybackSeekStepSpeed=true")
    }

    private func exercisePerformance(_ rig: Rig, defaults: UserDefaults, scratch: URL, audio: URL) async throws {
        let model = PresetLiveModel(defaults: defaults, fileStore: PresetLiveFileStore(directory: scratch.appendingPathComponent("live-\(rig.id)")))
        defer { model.stop() }
        model.loadDemoScriptIfNeeded()
        try require(!model.builtInPerformances.isEmpty, "\(rig.id): bundled performance catalog")
        for performance in model.builtInPerformances {
            try require(model.selectBuiltIn(performance) && !model.composedFrames.isEmpty,
                        "\(rig.id): bundled preset \(performance.id) parses and composes")
        }
        let selected = try XCTUnwrap(model.builtInPerformances.first)
        try require(model.selectBuiltIn(selected), "\(rig.id): built-in script selection")
        await model.importAudio(from: audio, forBuiltIn: selected.id)
        try require(model.canPlay && model.errorMessage == nil && !model.composedFrames.isEmpty, "\(rig.id): real audio + preset script import")
        model.isMuted = true
        await model.play(connection: rig.connection).value
        try await wait("\(rig.id) preset live decoded audio clock") { model.isPlaying && model.positionMs > 250 }
        try await wait("\(rig.id) preset live board owner") { (try await rig.connection.getStatus()).renderer?.outputMode == "performance" }
        model.pause()
        let position = model.positionMs
        try await wait("\(rig.id) preset live held frame") { try await rig.connection.getFrame() == model.previewFrame }
        try require(!model.isPlaying && position > 0, "\(rig.id): performance pause")
        model.seek(toMs: 1000)
        await model.play(connection: rig.connection).value
        try await wait("\(rig.id) preset live seek/resume") { model.isPlaying && model.positionMs >= 1100 }
        model.stop()
        try require(!model.isPlaying && model.positionMs == 0, "\(rig.id): performance stop")
        let script = scratch.appendingPathComponent("hardware-\(rig.id).rinalive")
        try "#fps 10\n#title Hardware custom\n0!101,201,301,400\n10!101,201,305,400\n20!101,201,301,400\n".write(to: script, atomically: true, encoding: .utf8)
        model.enterCustom()
        await model.importScript(from: script)
        await model.importCustomAudio(from: audio)
        try require(model.canPlay && model.errorMessage == nil && model.isCustomMode && model.composedFrames.count == 3,
                    "\(rig.id): custom script/audio import")
        await model.play(connection: rig.connection).value
        try await wait("\(rig.id) custom live timeline") { model.isPlaying && model.positionMs >= 1100 }
        model.pause()
        let expectedCustom = model.composedFrames[1]
        try require(model.previewFrame == expectedCustom, "\(rig.id): custom script chooses timed keyframe")
        try await wait("\(rig.id) custom keyframe board readback") { try await rig.connection.getFrame() == expectedCustom }
        model.stop()
        print("[MacFeatureHardwareTests] \(rig.id) realAudioPresetPerformance=true")
    }

    private func exerciseVideo(_ rig: Rig, defaults: UserDefaults, scratch: URL, video: URL) async throws {
        let model = VideoPlayerModel(defaults: defaults, store: PresetLiveFileStore(directory: scratch.appendingPathComponent("video-\(rig.id)")))
        defer { model.stop(); model.clearVideo() }
        model.isMuted = true
        model.loops = true
        model.settings = VideoFrameQuantizer.Settings(autoThreshold: false)
        await model.importFile(from: video)
        try require(model.hasVideo && model.durationMs >= 3500 && model.errorMessage == nil, "\(rig.id): AVAsset real file import")
        model.play(connection: rig.connection)
        try await wait("\(rig.id) decoded video playback") { model.isPlaying && model.positionMs > 250 && !model.previewFrame.isEmpty }
        try await wait("\(rig.id) video board owner") { (try await rig.connection.getStatus()).renderer?.outputMode == "video" }
        model.pause()
        try await wait("\(rig.id) quantized video held frame") { try await rig.connection.getFrame() == model.previewFrame }
        try require(!model.isPlaying && model.positionMs > 0, "\(rig.id): video pause")
        model.seek(toMs: 2000)
        model.play(connection: rig.connection)
        try await wait("\(rig.id) video seek/resume") { model.isPlaying && model.positionMs >= 2100 }
        model.stop()
        try require(!model.isPlaying && model.positionMs == 0, "\(rig.id): video stop")
        print("[MacFeatureHardwareTests] \(rig.id) realAVAssetVideoDecodeQuantizePlayback=true")
    }

    private func exerciseMicrophone(_ rig: Rig, defaults: UserDefaults) async throws {
        let probe = CaptureProbe()
        let capture = probe.capture
        let model = LipSyncModel(defaults: defaults, capture: probe)
        defer { model.stop(connection: rig.connection); capture.stop() }
        await model.start(connection: rig.connection)
        try require(model.isRunning && capture.isRunning && model.errorMessage == nil, "\(rig.id): actual microphone start \(model.errorMessage ?? "capture not running")")
        try await wait("\(rig.id) actual microphone PCM reception") { capture.latestWindow(count: 2048).samples.count >= 1024 }
        let pcm = capture.latestWindow(count: 2048)
        try require(pcm.sampleRate > 0 && pcm.samples.allSatisfy(\.isFinite), "\(rig.id): captured PCM samples/rate")
        try await wait("\(rig.id) production microphone analysis ticks") { probe.sampledWindows >= 3 }
        try await wait("\(rig.id) lip sync output owner") { (try await rig.connection.getStatus()).renderer?.outputMode == "lipSync" }
        // Silence is a valid microphone signal: classify/close the mouth and
        // prove that composition reaches the physical renderer.
        try await wait("\(rig.id) microphone composition displayed") { try await rig.connection.getFrame() == model.previewFrame }
        model.stop(connection: rig.connection)
        try await wait("\(rig.id) queued microphone stop") { !capture.isRunning && !model.isRunning }
        try await wait("\(rig.id) stopped closed mouth displayed") { try await rig.connection.getFrame() == model.previewFrame }
        print("[MacFeatureHardwareTests] \(rig.id) actualMicrophonePCM=\(pcm.samples.count) sampleRate=\(pcm.sampleRate) modelCaptureWindows=\(probe.sampledWindows) lipSyncStartStop=true")
    }

    private func exerciseDebugAndTelemetry(_ rig: Rig) async throws {
        let model = DebugViewModel()
        await model.refreshOverview(connection: rig.connection)
        try require(model.lastLocalError == nil && model.statusSnapshot != nil && model.powerSnapshot != nil && model.deviceInfo != nil,
                    "\(rig.id): production Debug status/power/device info")
        await model.pingBoard(connection: rig.connection)
        try require(model.pingMs != nil && model.commandFailures == 0, "\(rig.id): debug ping")
        for input in ["PING", "GET_STATUS", "GET_POWER", "get_info", "wifi_status"] {
            model.monitorInput = input
            await model.sendMonitorCommand(connection: rig.connection)
            try require(model.commandFailures == 0 && model.commandRejected == 0, "\(rig.id): safe monitor \(input)")
        }
        for pattern in [DebugPattern.checker, .border, .off] {
            await model.sendPattern(pattern, connection: rig.connection)
            let actual = try await rig.connection.getFrame()
            try require(model.frameFailures == 0 && model.commandRejected == 0 && actual == model.debugFrame,
                        "\(rig.id): debug pattern \(pattern)")
        }
        try require(model.monitorEntries.contains { $0.message.contains("RX") }, "\(rig.id): serial monitor response rows")
        print("[MacFeatureHardwareTests] \(rig.id) debugSafeMonitorPatternsPowerStatus=true")
    }

    private func exerciseNameAndScan(_ rig: Rig, defaults: UserDefaults) async throws {
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let boards = BoardStore(defaults: defaults)
        let peripheralID = try XCTUnwrap(rig.transport.peripheralIdentifier).uuidString
        boards.upsert(KnownBoard(id: peripheralID, name: rig.id))
        model.boardNameInput = "Test\(rig.id.suffix(4))"
        await model.renameBoard(connection: rig.connection, boardStore: boards,
                                groupStore: BoardGroupStore(defaults: defaults), ble: rig.transport)
        let reply = try await rig.connection.command(.getInfo)
        try require(model.lastErrorMessage == nil && reply.name == model.boardNameInput && reply.customName == true,
                    "\(rig.id): production board rename readback")
        await model.scanNetworks(connection: rig.connection)
        try require(model.lastErrorMessage == nil, "\(rig.id): production Wi-Fi scan \(model.lastErrorMessage ?? "")")
        let scan = try XCTUnwrap(rig.connection.lastWifiScan)
        try require(scan.ok == true && scan.scanning != true && scan.networks != nil,
                    "\(rig.id): Wi-Fi scan needs a completed board result, including an explicit empty list")
        print("[MacFeatureHardwareTests] \(rig.id) boardRenameWiFiScan=true networks=\(scan.networks?.count ?? 0)")
    }

    private func storeMirrorGroup(_ id: UUID, store: BoardGroupStore) {
        store.setMode(id: id, mode: .mirror)
    }

    private func exerciseGroupControlsAndMedia(rigs: [Rig], primary: Rig, fanOut: GroupControlFanOut,
                                               scratch: URL, defaults: UserDefaults, audio: URL, video: URL,
                                               carrier: String) async throws {
        let connection = primary.connection
        // Debug output is deliberately board-local. Take group control with
        // the production editor before testing settings fanout.
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: scratch.appendingPathComponent("group-draft-\(carrier)")))
        defer { editor.releaseOutput() }
        editor.livePreview = false
        editor.clear(connection: connection)
        editor.toggle(led: 20, connection: connection)
        await editor.send(connection: connection)
        let initialManual = editor.draftFrame
        for rig in rigs { try await wait("\(carrier) \(rig.id) group editor control handover") { try await rig.connection.getFrame() == initialManual } }
        let controls = BoardControlCenterModel()
        defer { controls.connectionChanged() }
        let before = try await connection.getStatus()
        controls.sync(from: before)
        let oldBrightness = try XCTUnwrap(before.renderer?.brightness)
        let brightness = oldBrightness == RinaLinkConstants.brightnessMin ? oldBrightness + 1 : oldBrightness - 1
        let color = carrier == "bothBLE" ? "#5A87B4" : (carrier == "mixedBLEAndTCP" ? "#B45A87" : "#87B45A")
        let interval = carrier == "bothBLE" ? 2000 : (carrier == "mixedBLEAndTCP" ? 2500 : 3000)
        controls.setBrightness(brightness, connection: connection)
        await controls.setColor(hex: color, connection: connection)
        controls.setAutoInterval(Double(interval) / 1000, connection: connection)
        for rig in rigs {
            try await wait("\(carrier) \(rig.id) group control settings") {
                let actual = try await rig.connection.getStatus()
                return actual.renderer?.brightness == brightness && actual.renderer?.color?.uppercased() == color &&
                    actual.renderer?.autoIntervalMs == interval
            }
        }
        let current = try await connection.getStatus()
        let oldIndex = try XCTUnwrap(current.renderer?.autoFaceIndex)
        let count = try XCTUnwrap(current.renderer?.autoFaceCount)
        try require(count > 1, "Group expression stepping needs two saved faces")
        for direction in [1, -1] {
            await controls.step(face: direction, connection: connection)
            let status = try await connection.getStatus()
            let expectedIndex = direction == 1 ? (oldIndex + 1) % count : oldIndex
            try require(status.renderer?.autoFaceIndex == expectedIndex, "\(carrier): group B1/B2 primary expression index")
            let expected = try await connection.getFrame()
            for rig in rigs { try await wait("\(carrier) \(rig.id) group expression frame") { try await rig.connection.getFrame() == expected } }
        }
        for button in ["B4", "B5"] {
            let prior = try await connection.getStatus()
            let reply = try await connection.command(.button(button: button))
            let actual = try await connection.getStatus()
            let expected = try XCTUnwrap(actual.renderer?.brightness)
            let priorBrightness = try XCTUnwrap(prior.renderer?.brightness)
            try require(reply.ok && expected != priorBrightness,
                        "\(carrier): group \(button) brightness button primary readback")
            for rig in rigs { try await wait("\(carrier) \(rig.id) group \(button) brightness") { (try await rig.connection.getStatus()).renderer?.brightness == expected } }
        }
        editor.livePreview = true
        editor.clear(connection: connection)
        editor.toggle(led: 20, connection: connection)
        editor.toggle(led: 200, connection: connection)
        let liveFrame = editor.draftFrame
        for rig in rigs { try await wait("\(carrier) \(rig.id) group live editor frame") { try await rig.connection.getFrame() == liveFrame } }
        editor.releaseOutput()

        // These existing helpers import real media and exercise the real
        // producer on the group's primary. Its BoardConnection is attached
        // to GroupControlFanOut, so both physical renderers must receive it.
        try await exercisePerformance(primary, defaults: defaults, scratch: scratch, audio: audio)
        try await verifyHeldGroupOutput(rigs: rigs, primary: primary, mode: "performance", label: "\(carrier) performance")
        try await exerciseVideo(primary, defaults: defaults, scratch: scratch, video: video)
        try await verifyHeldGroupOutput(rigs: rigs, primary: primary, mode: "video", label: "\(carrier) video")
        try await exerciseMicrophone(primary, defaults: defaults)
        try await verifyHeldGroupOutput(rigs: rigs, primary: primary, mode: "lipSync", label: "\(carrier) actual microphone")
        try require(fanOut.memberErrors.isEmpty && fanOut.primaryConnection === connection,
                    "\(carrier): group control/media fanout failed or changed primary")
        print("[MacFeatureHardwareTests] bothBoards carrier=\(carrier) groupBrightnessColorIntervalButtonsLiveEditorRealPerformanceVideoMicrophone=true")
    }

    /// Producers are stopped before this hold. Require three stable samples
    /// so queued final frames can settle without comparing moving playback.
    private func verifyHeldGroupOutput(rigs: [Rig], primary: Rig, mode: String, label: String) async throws {
        var previous: PackedFrame?
        var stableSamples = 0
        try await wait("\(label) both physical held frames and stream owners") {
            let primaryStatus = try await primary.connection.getStatus()
            let frame = try await primary.connection.getFrame()
            guard primaryStatus.renderer?.outputMode == mode, let stream = primaryStatus.renderer?.outputStreamID, !stream.isEmpty else { return false }
            for rig in rigs {
                let status = try await rig.connection.getStatus()
                let actual = try await rig.connection.getFrame()
                guard rig.connection.connectionState == .connected && status.renderer?.outputMode == mode &&
                    status.renderer?.outputStreamID == stream && actual == frame else { stableSamples = 0; return false }
            }
            stableSamples = previous == frame ? stableSamples + 1 : 1
            previous = frame
            return stableSamples >= 3
        }
    }

    private func selectCarrier(_ selection: ConnectionViewModel.TransportSelection, rig: Rig, rigs: [Rig],
                               sessions: BoardSessionStore, model: ConnectionViewModel, boards: BoardStore) async throws {
        let unchanged = rigs.filter { $0 !== rig }
        let generations = unchanged.map { $0.connection.connectionGeneration }
        let kinds = unchanged.map { $0.connection.transportKind }
        var frames: [PackedFrame] = []
        for other in unchanged {
            // stop_scroll acknowledges its blank before the firmware's 90 ms
            // saved-face restore. Capture the idle peer only once that output
            // has settled; the exact post-switch comparison still starts
            // before selectTransport and covers the whole carrier switch.
            var previous: PackedFrame?
            var stableSamples = 0
            try await wait("\(other.id) idle peer frame before carrier switch") {
                let status = try await other.connection.getStatus()
                let frame = try await other.connection.getFrame()
                guard status.renderer?.firmwareScrollActive == false else {
                    stableSamples = 0
                    return false
                }
                stableSamples = previous == frame ? stableSamples + 1 : 1
                previous = frame
                return stableSamples >= 3
            }
            frames.append(try XCTUnwrap(previous))
        }
        let selectedSession = sessions.active
        let originalKind = rig.connection.transportKind
        await model.selectTransport(selection, session: rig.session, sessions: sessions, boardStore: boards)
        try require(model.lastErrorMessage == nil && rig.connection.connectionState == .connected &&
                    rig.connection.boardIdentity == rig.id && model.selectedTransport(for: rig.session) == selection,
                    "\(rig.id): production transport selector \(selection) handshake/identity \(model.lastErrorMessage ?? "")")
        try require(sessions.active === selectedSession, "Switching a carrier unexpectedly selected another board")
        if selection == .wifi {
            let original = try XCTUnwrap(rig.original)
            guard case .wifi(let host, let port) = rig.connection.transportKind else {
                throw Failure(message: "\(rig.id): expected actual TCP carrier")
            }
            try require(host == original.status.wifi?.ip && port == RinaLinkConstants.tcpPort,
                        "\(rig.id): TCP must address the original board's reported STA IP and port 5370")
            if originalKind == .bluetooth {
                // The switched connection now uses TCP; keep the old BLE
                // object alive and prove its terminal callback independently.
                let terminal = try await rig.transport.disconnectAndWait(timeout: 8)
                try require(terminal, "\(rig.id): old BLE carrier terminal callback after TCP switch")
                print("[MacFeatureHardwareTests] \(rig.id) oldBLECarrierTerminalAfterTCPSwitch=true")
            }
        } else {
            try require(rig.connection.transportKind == .bluetooth, "\(rig.id): expected actual BLE carrier")
        }
        let switchedStatus = try await rig.connection.getStatus()
        try require(switchedStatus.wifi?.staConnected == true && switchedStatus.wifi?.boardId?.uppercased() == rig.id,
                    "\(rig.id): Wi-Fi association and physical identity survive carrier switch")
        _ = try await rig.connection.getFrame()
        for (index, other) in unchanged.enumerated() {
            try require(other.connection.connectionState == .connected && other.connection.connectionGeneration == generations[index] &&
                        other.connection.transportKind == kinds[index], "\(other.id): unrelated carrier interrupted by \(rig.id) switch")
            let status = try await other.connection.getStatus()
            let actualFrame = try await other.connection.getFrame()
            try require(status.wifi?.boardId?.uppercased() == other.id && status.wifi?.staConnected == true && actualFrame == frames[index],
                        "\(other.id): unrelated board status/frame changed during \(rig.id) switch")
        }
        print("[MacFeatureHardwareTests] \(rig.id) selectedCarrier=\(selection.rawValue) unrelatedBoardCarrierFramePreserved=true")
    }

    private func exerciseActiveGroupRecovery(_ group: BoardGroup, rigs: [Rig], coordinator: BoardGroupCoordinator,
                                             fanOut: GroupControlFanOut, sessions: BoardSessionStore,
                                             model: ConnectionViewModel, boards: BoardStore) async throws {
        try require(rigs.allSatisfy { rig in
            guard rig.connection.connectionState == .connected else { return false }
            if case .wifi = rig.connection.transportKind { return true }
            return false
        }, "Active group recovery must start with both actual TCP carriers ready")
        fanOut.setTarget(.group(group.id))
        defer { fanOut.setTarget(.single) }
        let initialPrimaryID = try XCTUnwrap(fanOut.primaryID)
        let changing = try XCTUnwrap(rigs.first { $0.id == initialPrimaryID })
        let survivor = try XCTUnwrap(rigs.first { $0 !== changing })
        try await coordinator.play(group: group, text: "LIVE RECOVERY 370", fps: 10, loop: true)
        let epoch = coordinator.debugPlayEpoch
        let initialMeta = try await changing.connection.getScrollMeta()
        let timelineID = try XCTUnwrap(initialMeta.scrollTimelineId)
        let survivorGeneration = survivor.connection.connectionGeneration
        for selection in [ConnectionViewModel.TransportSelection.bluetooth, .wifi] {
            let before = try await survivor.connection.getPreviewSync()
            let advance = try XCTUnwrap(before.scrollAdvanceSeq)
            let oldKind = changing.connection.transportKind
            await model.selectTransport(selection, session: changing.session, sessions: sessions, boardStore: boards)
            try require(model.lastErrorMessage == nil && changing.connection.connectionState == .connected &&
                        changing.connection.boardIdentity == changing.id && model.selectedTransport(for: changing.session) == selection,
                        "Active group carrier switch \(selection) handshake/identity")
            if oldKind == .bluetooth {
                let terminal = try await changing.transport.disconnectAndWait(timeout: 8)
                try require(terminal, "Active group old BLE terminal callback")
            }
            try require(coordinator.isPlaying && !coordinator.isPaused && coordinator.activeGroupID == group.id && coordinator.debugPlayEpoch == epoch,
                        "Active carrier switch restarted or stopped the original group play")
            try require(survivor.connection.connectionGeneration == survivorGeneration && survivor.connection.connectionState == .connected,
                        "Active carrier switch interrupted the surviving TCP session")
            try await wait("Active carrier switch survivor keeps advancing", timeout: 12) {
                let preview = try await survivor.connection.getPreviewSync()
                guard let nextAdvance = preview.scrollAdvanceSeq else { return false }
                return preview.groupTimed == true && preview.scrollTimelineId == timelineID && nextAdvance != advance
            }
            try await wait("Active carrier switch natural member rejoin", timeout: 20) {
                coordinator.isLiveParticipant(try XCTUnwrap(group.members.first { $0.physicalBoardID == changing.id }))
            }
            let rejoined = try await changing.connection.getScrollMeta()
            try require(rejoined.groupTimed == true && rejoined.scrollTimelineId == timelineID &&
                        changing.connection.bootId == changing.original?.bootID,
                        "Carrier switch failed to rejoin the original boot/timeline")
            try await wait("Active carrier switch primary promotion") { fanOut.primaryID == survivor.id && sessions.active === survivor.session }
            print("[MacFeatureHardwareTests] bothBoards activeGroupCarrierSwitch=\(selection.rawValue) originalTimelineContinuesNaturalRejoinPrimaryPromotion=true")
        }

        // Drop the promoted primary's real TCP carrier. Keep the other board
        // playing, then reconnect the member through the public selector.
        let continuing = try await changing.connection.getPreviewSync()
        let continuingAdvance = try XCTUnwrap(continuing.scrollAdvanceSeq)
        let changingGeneration = changing.connection.connectionGeneration
        survivor.connection.disconnect(userInitiated: true)
        try require(survivor.connection.connectionState == .disconnected, "Group member explicit disconnect")
        try await wait("Disconnected group primary promotes remaining member") { fanOut.primaryID == changing.id && sessions.active === changing.session }
        try await wait("Offline group member survivor continues", timeout: 12) {
            let preview = try await changing.connection.getPreviewSync()
            guard let nextAdvance = preview.scrollAdvanceSeq else { return false }
            return preview.groupTimed == true && preview.scrollTimelineId == timelineID && nextAdvance != continuingAdvance
        }
        try require(changing.connection.connectionGeneration == changingGeneration && coordinator.isPlaying && coordinator.debugPlayEpoch == epoch,
                    "Explicit member disconnect interrupted or restarted the surviving group play")
        await model.selectTransport(.wifi, session: survivor.session, sessions: sessions, boardStore: boards)
        try require(survivor.connection.connectionState == .connected && survivor.connection.boardIdentity == survivor.id,
                    "Disconnected group member production TCP reconnect")
        try await wait("Disconnected member natural group rejoin", timeout: 20) {
            coordinator.isLiveParticipant(try XCTUnwrap(group.members.first { $0.physicalBoardID == survivor.id }))
        }
        try require(coordinator.activeGroupID == group.id && coordinator.debugPlayEpoch == epoch,
                    "Member reconnect changed the original active group/play epoch")
        await coordinator.pause(group: group)
        try require(coordinator.isPaused, "Recovered group pause")
        let held = try await changing.connection.getFrame()
        try await wait("Recovered mirror group exact bounded hold") { try await survivor.connection.getFrame() == held }
        for rig in rigs {
            let preview = try await rig.connection.getPreviewSync()
            try require(preview.firmwareScrollPaused == true && preview.scrollTimelineId == timelineID &&
                        (preview.frameIndex == coordinator.pausedFrame || preview.presentedFrameIndex == coordinator.pausedFrame),
                        "\(rig.id): recovered paused timeline/frame synchronization")
        }
        await coordinator.resume(group: group)
        try require(coordinator.isPlaying && !coordinator.isPaused, "Recovered group resume")
        for rig in rigs {
            let before = try await rig.connection.getPreviewSync()
            let beforeAdvance = try XCTUnwrap(before.scrollAdvanceSeq)
            try await wait("\(rig.id) recovered group resumes advancing") {
                let after = try await rig.connection.getPreviewSync()
                guard let afterAdvance = after.scrollAdvanceSeq else { return false }
                return after.groupTimed == true && afterAdvance != beforeAdvance
            }
        }
        await coordinator.stop(group: group)
        // Do not reselect the group target. A new held frame must still fan
        // out through the primary promoted by the recovery above.
        let promotedPrimary = try XCTUnwrap(fanOut.primaryConnection)
        var probe = PackedFrame()
        probe.set(42); probe.set(242)
        _ = try await promotedPrimary.setFrame(probe, playback: .idle, reason: "group_recovery_target_probe")
        for rig in rigs { try await wait("\(rig.id) original group control target retained") { try await rig.connection.getFrame() == probe } }
        try require(fanOut.memberErrors.isEmpty, "Recovered group target has sink errors")
        print("[MacFeatureHardwareTests] bothBoards activeGroupMemberDisconnectReconnectNaturalRejoinPrimaryPromotionTargetRetained=true")
    }

    private func exerciseGroup(_ group: BoardGroup, rigs: [Rig], store: BoardGroupStore, coordinator: BoardGroupCoordinator,
                               fanOut: GroupControlFanOut, scratch: URL, defaults: UserDefaults, audio: URL, video: URL,
                               carrier: String) async throws {
        let bleCount = rigs.filter { $0.connection.transportKind == .bluetooth }.count
        let tcpCount = rigs.filter { if case .wifi = $0.connection.transportKind { return true }; return false }.count
        let expectedBLE = carrier == "bothBLE" ? 2 : (carrier == "mixedBLEAndTCP" ? 1 : 0)
        try require(bleCount == expectedBLE && tcpCount == 2 - expectedBLE && rigs.allSatisfy { $0.connection.connectionState == .connected },
                    "\(carrier): both physical boards must be ready on the specified real carriers")
        fanOut.setTarget(.group(group.id))
        defer { fanOut.setTarget(.single) }
        let primary = try XCTUnwrap(fanOut.primaryConnection)
        let primaryRig = try XCTUnwrap(rigs.first { $0.connection === primary })
        var controlsAndMediaFailure: Error?
        do {
            try await exerciseGroupControlsAndMedia(rigs: rigs, primary: primaryRig, fanOut: fanOut, scratch: scratch,
                                                    defaults: defaults, audio: audio, video: video, carrier: carrier)
        } catch {
            controlsAndMediaFailure = error
            print("[MacFeatureHardwareTests] FAIL carrier=\(carrier) group controls/media: \(error.localizedDescription)")
            try require(rigs.allSatisfy { $0.connection.connectionState == .connected },
                        "\(carrier): cannot continue group text coverage after a link failure")
        }
        let library = FaceLibraryModel(localStore: LocalFaceStore(fileURL: scratch.appendingPathComponent("group-faces.json")))
        try require(await library.reload(connection: primary), "Group primary face list")
        let cycler = GroupAutoCycler(fanOut: fanOut, faceLibrary: library, intervalProvider: { 1 })
        defer { cycler.stop() }
        await cycler.step(direction: 1)
        let expected = try XCTUnwrap(library.faces(in: .board)[cycler.currentIndex].packedFrame)
        for rig in rigs { try await wait("\(rig.id) group manual fanout") { try await rig.connection.getFrame() == expected } }
        try require(cycler.start(), "Group automatic cycle admission")
        let previousIndex = cycler.currentIndex
        try await wait("Group automatic cycle advancement", timeout: 4) { cycler.currentIndex != previousIndex }
        cycler.stop()
        let automaticFrame = try XCTUnwrap(library.faces(in: .board)[cycler.currentIndex].packedFrame)
        for rig in rigs { try await wait("\(rig.id) group automatic fanout") { try await rig.connection.getFrame() == automaticFrame } }
        try await coordinator.play(group: group, text: "RINA GROUP", fps: 10, loop: true)
        try require(coordinator.isPlaying, "Production group playback started")
        for rig in rigs {
            let meta = try await rig.connection.getScrollMeta()
            try require(meta.groupTimed == true && meta.uploadComplete == true, "\(rig.id): group timed upload/start")
        }
        await coordinator.pause(group: group)
        try require(coordinator.isPaused, "Group pause")
        for rig in rigs { try require((try await rig.connection.getStatus()).renderer?.firmwareScrollPaused == true, "\(rig.id): group pause readback") }
        let held = try await rigs[0].connection.getFrame()
        try require(try await rigs[1].connection.getFrame() == held, "Mirror group exact paused output synchronization")
        let oldFrame = coordinator.pausedFrame
        await coordinator.step(group: group, direction: 1)
        try require(coordinator.pausedFrame != oldFrame, "Group step")
        let stepped = try await rigs[0].connection.getFrame()
        try require(try await rigs[1].connection.getFrame() == stepped, "Mirror group exact stepped output synchronization")
        await coordinator.resume(group: group)
        try require(!coordinator.isPaused, "Group resume")
        for rig in rigs { try await wait("\(rig.id) group resume readback") { (try await rig.connection.getScrollMeta()).groupTimed == true } }
        await coordinator.stop(group: group)
        for rig in rigs { try require((try await rig.connection.getStatus()).renderer?.firmwareScrollActive == false, "\(rig.id): group stop readback") }
        store.setMode(id: group.id, mode: .stitched)
        try store.setGap(groupID: group.id, afterSlot: 0, columns: 2)
        store.swapMembers(groupID: group.id, 0, 1)
        let stitched = try XCTUnwrap(store.groups.first { $0.id == group.id })
        try await coordinator.play(group: stitched, text: "STITCH 370", fps: 10, loop: true)
        await coordinator.pause(group: stitched)
        try require(coordinator.isPaused, "Stitched group pause")
        let layout = try XCTUnwrap(stitched.stitchedLayout)
        let bitmap = try GroupScrollBitmap.build(text: "STITCH 370", font: BoardGroupCoordinator.loadDefaultFont(), virtualWidth: layout.virtualWidth)
        var heldFrames: [String: PackedFrame] = [:]
        for (slot, member) in stitched.members.enumerated() {
            let rig = try XCTUnwrap(rigs.first { $0.id == member.physicalBoardID })
            let expected = GroupScrollBitmap.frame(bitmap: bitmap, viewportX: layout.viewportX(slot: slot), frameIndex: coordinator.pausedFrame)
            try require(try await rig.connection.getFrame() == expected, "\(rig.id): stitched swapped slot and gap exact window")
            heldFrames[rig.id] = expected
        }
        await coordinator.updatePlayback(group: stitched, fps: 12, loop: false)
        // Paused updates change the coordinator's pending anchor. They must
        // hold the exact physical windows until resume applies that anchor.
        try require(coordinator.isPaused, "Group speed/loop update preserves pause")
        for rig in rigs {
            let status = try await rig.connection.getStatus()
            let meta = try await rig.connection.getScrollMeta()
            let frame = try await rig.connection.getFrame()
            try require(status.renderer?.firmwareScrollPaused == true && meta.scrollIntervalMs == 100 && meta.scrollLoop == true &&
                        frame == heldFrames[rig.id],
                        "\(rig.id): deferred group speed/loop update preserves physical pause/frame")
        }
        await coordinator.resume(group: stitched)
        try require(coordinator.isPlaying && !coordinator.isPaused, "Group resumes with pending speed/loop update")
        for rig in rigs {
            let meta = try await rig.connection.getScrollMeta()
            // group_start's interval controls the renderer; uiFps is upload
            // metadata and can retain the original 10 fps label.
            try require(meta.groupTimed == true && meta.scrollIntervalMs == ScrollRasterizer.intervalMs(forFps: 12) && meta.scrollLoop == false,
                        "\(rig.id): group speed/loop readback")
        }
        await coordinator.stop(group: stitched)
        print("[MacFeatureHardwareTests] bothBoards carrier=\(carrier) groupManualAutoMirrorStitchedGapSwapTimedPauseStepResumeStop=true")
        if let controlsAndMediaFailure { throw controlsAndMediaFailure }
    }

    private func restore(_ rig: Rig, original: Original) async throws {
        let connection = rig.connection
        connection.output.invalidate()
        var failures: [String] = []
        func attempt(_ label: String, _ operation: () async throws -> Void) async {
            do { try await operation() }
            catch { failures.append("\(label): \(error.localizedDescription)") }
        }
        // Find ambiguous successful creates by the unique test-only name as
        // well as known IDs; never delete a pre-existing face.
        let beforeIDs = Set(original.faces.faces.map(\.id))
        await attempt("find temporary faces") {
            let current = try FaceDocument(jsonData: await connection.getFaces())
            for face in current.faces where !beforeIDs.contains(face.id) &&
                (rig.temporaryIDs.contains(face.id) || face.name.hasPrefix(rig.temporaryName)) {
                await attempt("delete \(face.id)") { _ = try await connection.faceDelete(id: face.id) }
            }
        }
        await attempt("original faces readback") {
            let after = try FaceDocument(jsonData: await connection.getFaces())
            try require(after == original.faces, "Original full saved-face document changed")
        }
        await attempt("stop test scroll") { _ = try await connection.command(.stopScroll(restoreAuto: false, clear: false)) }
        let renderer = try XCTUnwrap(original.status.renderer)
        await attempt("brightness") { _ = try await connection.command(.setBrightness(raw: XCTUnwrap(renderer.brightness))) }
        await attempt("color") { _ = try await connection.command(.setColor(hex: XCTUnwrap(renderer.color))) }
        await attempt("auto interval") { _ = try await connection.command(.setAutoInterval(ms: XCTUnwrap(renderer.autoIntervalMs))) }
        await attempt("device name") {
            _ = try await connection.command(.setDeviceName(name: original.customName == true ? (original.deviceName ?? "") : ""))
        }
        await attempt("scroll loop") {
            if let loop = original.scroll.scrollLoop { _ = try await connection.command(.setScrollLoop(loop: loop)) }
        }
        await attempt("manual restoration mode") { _ = try await connection.command(.setMode(mode: "manual")) }
        await attempt("original saved face selection") {
            if let id = renderer.autoFaceId,
               let index = original.faces.sortedFaces.firstIndex(where: { $0.id == id }) {
                _ = try await connection.command(.applySavedFace(index: index, id: id, reason: "hardware_restore", playback: "idle"))
            } else if let index = renderer.autoFaceIndex, original.faces.sortedFaces.indices.contains(index) {
                _ = try await connection.command(.applySavedFace(index: index, id: original.faces.sortedFaces[index].id,
                                                               reason: "hardware_restore", playback: "idle"))
            }
        }
        await attempt("original frame") {
            let originalFrame = try XCTUnwrap(PackedFrame(hex94: original.frameHex))
            if try await connection.getFrame() != originalFrame {
                _ = try await connection.setFrame(originalFrame, playback: .idle, reason: renderer.lastReason ?? "hardware_restore")
            }
            try require(try await connection.getFrame() == originalFrame, "Original displayed frame not restored")
        }
        await attempt("original mode") { if renderer.mode == "auto" { _ = try await connection.command(.setMode(mode: "auto")) } }
        await attempt("original pause") { if renderer.paused == true { _ = try await connection.command(.pause) } }
        await attempt("settings readback") {
            let restored = try await connection.getStatus()
            try require(restored.renderer?.brightness == renderer.brightness && restored.renderer?.color?.uppercased() == renderer.color?.uppercased() &&
                        restored.renderer?.autoIntervalMs == renderer.autoIntervalMs && restored.renderer?.mode == renderer.mode,
                        "Original renderer settings not restored")
            try require(restored.wifi?.mode == original.status.wifi?.mode && restored.wifi?.homeSsid == original.status.wifi?.homeSsid &&
                        restored.wifi?.hotspotSsid == original.status.wifi?.hotspotSsid && restored.wifi?.apSsid == original.status.wifi?.apSsid,
                        "Original Wi-Fi configuration changed")
        }
        // Settings are deliberately untouched; credentials are never requested
        // or mutated. Device name and startup default must still match.
        await attempt("device name readback") {
            let info = try await connection.command(.getInfo)
            try require(info.name == original.deviceName && info.customName == original.customName, "Original device name changed")
        }
        try require(failures.isEmpty, failures.joined(separator: "; "))
        print("[MacFeatureHardwareTests] \(rig.id) originalFacesSettingsOutputRestored=true")
    }

    private func rebootAndReconnect(_ rig: Rig, original: Original) async throws {
        let before = try await rig.connection.command(.getInfo)
        let beforeBootID = try XCTUnwrap(before.bootId)
        try require(beforeBootID == original.bootID, "\(rig.id): unexpected boot before explicit restart")
        // Mode persistence is debounced for 1000 ms in storage.cpp. Give the
        // restored mode its documented write window before requesting reboot.
        try await Task.sleep(for: .milliseconds(1200))
        let reply = try await rig.connection.command(.reboot)
        try require(reply.ok, "\(rig.id): reboot rejected")
        rig.connection.disconnect(userInitiated: true)
        let terminated = try await rig.transport.disconnectAndWait(timeout: 8)
        try require(terminated, "\(rig.id): reboot carrier terminal disconnect")
        // Firmware explicitly schedules the reboot 200 ms after its ACK;
        // boot/advertisement readiness is proved by the subsequent handshake.
        try await Task.sleep(for: .seconds(2))
        try require(await rig.connection.connect(using: rig.transport), "\(rig.id): reboot reconnect handshake")
        try require(rig.connection.boardIdentity == rig.id, "\(rig.id): reboot physical identity")
        let after = try await rig.connection.command(.getInfo)
        let afterBootID = try XCTUnwrap(after.bootId)
        try require(!afterBootID.isEmpty && afterBootID != beforeBootID, "\(rig.id): reboot must change bootId")
        // Everything below is read-only and precedes postboot restoration.
        // Runtime color, brightness and SET_FRAME output are not persisted by
        // saveRuntimeSettings(), so those are restored separately afterwards.
        let status = try await rig.connection.getStatus()
        let faces = try FaceDocument(jsonData: await rig.connection.getFaces())
        try require(status.renderer?.mode == original.status.renderer?.mode &&
                    status.renderer?.autoIntervalMs == original.status.renderer?.autoIntervalMs,
                    "\(rig.id): persisted mode/auto interval did not survive reboot")
        try require(after.name == original.deviceName && after.customName == original.customName,
                    "\(rig.id): persisted device name did not survive reboot")
        try require(faces == original.faces, "\(rig.id): saved-face content/order/startup default did not survive reboot")
        try require(status.wifi?.mode == original.status.wifi?.mode && status.wifi?.homeSsid == original.status.wifi?.homeSsid &&
                    status.wifi?.hotspotSsid == original.status.wifi?.hotspotSsid && status.wifi?.apSsid == original.status.wifi?.apSsid,
                    "\(rig.id): persisted Wi-Fi configuration did not survive reboot")
        try await wait("\(rig.id) postboot station Wi-Fi readiness", timeout: 25) { (try await rig.connection.getStatus()).wifi?.staConnected == true }
        print("[MacFeatureHardwareTests] \(rig.id) rebootReconnectVerified=true beforeBootId=\(beforeBootID) afterBootId=\(afterBootID) persistedModeIntervalNameFacesWiFiVerifiedBeforeRestore=true")
    }

    private func makeMedia(in directory: URL) async throws -> (video: URL, audio: URL) {
        let audio = directory.appendingPathComponent("hardware-tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 176400))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100)) * 0.02 }
        let audioFile = try AVAudioFile(forWriting: audio, settings: format.settings)
        try audioFile.write(from: buffer)

        let video = directory.appendingPathComponent("hardware-checker.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        try require(writer.startWriting(), "Synthetic media writer start")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<120 {
            try await wait("Synthetic media writer ready") { input.isReadyForMoreMediaData || writer.status == .failed }
            try require(writer.status != .failed, "Synthetic media writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            var pixelBuffer: CVPixelBuffer?
            try require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
                        "Synthetic pixel buffer allocation")
            let pixel = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<64 {
                for x in 0..<64 {
                    let value: UInt8 = ((x / 8 + y / 8 + frame / 30) % 2 == 0) ? 255 : 0
                    let offset = y * stride + x * 4
                    base[offset] = value; base[offset + 1] = value; base[offset + 2] = value; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            try require(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "Synthetic video frame append")
        }
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Real video fixture export: \(writer.error?.localizedDescription ?? "failed")")
        return (video, audio)
    }
}
#endif
