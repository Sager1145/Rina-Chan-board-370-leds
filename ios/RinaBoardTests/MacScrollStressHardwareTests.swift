import CoreBluetooth
import Foundation
import RinaCore
import XCTest
@testable import RinaBoard

#if targetEnvironment(macCatalyst)
/// Serial, opt-in physical test. Disconnect the interactive app first.
/// Uses BLE in AP-only mode; never provisions or reads Wi-Fi credentials.
/// Scroll uploads replace idle RAM timelines, cleared by cleanup reboot.
@MainActor
final class MacScrollStressHardwareTests: XCTestCase {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Original: Codable {
        let status: DeviceStatus
        let frameHex: String
        let faces: FaceDocument
        let scroll: ScrollMeta
        let name: String?
        let customName: Bool?
        let bootID: String
    }
    @MainActor private final class Rig {
        let id: String
        let peripheralID: UUID
        let session: BoardSession
        let ble: BLETransport
        var original: Original?
        var touched = false
        var sentFrames = 0
        init(id: String, peripheralID: String, sessions: BoardSessionStore) throws {
            self.id = id
            self.peripheralID = try XCTUnwrap(UUID(uuidString: peripheralID))
            session = sessions.session(for: id, name: "RinaBoard-\(id)")
            ble = try XCTUnwrap(session.bleTransport as? BLETransport)
        }
        var connection: BoardConnection { session.connection }
    }
    private let rates = [1, 10, 20, 60]
    private let sourceText = "RINA 370 文字滚动 FPS 1 10 20 60 SYNC"

    func testRapidTargetsFramesAndAllScrollRatesOnBothRealBoardsAndRestore() async throws {
        let environment = ProcessInfo.processInfo.environment
        func enabled(_ key: String) -> Bool {
            environment[key] == "1" || environment["TEST_RUNNER_\(key)"] == "1"
        }
        guard enabled("RINA_MAC_HARDWARE_TESTS"), enabled("RINA_MAC_STRESS_TESTS") else {
            throw XCTSkip("Set TEST_RUNNER_RINA_MAC_HARDWARE_TESTS=1 and TEST_RUNNER_RINA_MAC_STRESS_TESTS=1; run serially")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rina-scroll-stress-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suiteName = "rina.mac.scroll.stress.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }
        let sessions = BoardSessionStore()
        let rigs = [
            try Rig(id: "80B54EF48E09", peripheralID: "6F2161EE-AFE4-5C51-758C-B358FA08DDDE", sessions: sessions),
            try Rig(id: "80B54EF74801", peripheralID: "3747C06D-B6B5-815B-9B46-B77CF2070CCE", sessions: sessions)
        ]
        let scanner = try XCTUnwrap(sessions.scanner as? BLETransport)
        let store = BoardGroupStore(defaults: defaults)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        sessions.isGroupOwned = { coordinator.isGroupOwned($0) }
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)
        var testError: Error?
        var activeGroup: BoardGroup?
        do {
            try await connect(rigs, scanner: scanner)
            for rig in rigs {
                let status = try await rig.connection.getStatus()
                let scroll = try await rig.connection.getScrollMeta()
                let info = try await rig.connection.requestReliable(.getInfo)
                let renderer = try XCTUnwrap(status.renderer)
                try require(renderer.mode == "manual" && scroll.firmwareScrollActive != true &&
                            !["video", "performance", "lipSync", "text"].contains(renderer.outputMode ?? ""),
                            "\(rig.id): admission requires idle manual output; active original media cannot be backed up")
                try require(status.wifi?.staConnected != true, "\(rig.id): this suite requires the agreed AP-only state")
                rig.original = Original(status: status, frameHex: try await rig.connection.getFrame().hex94,
                                        faces: try FaceDocument(jsonData: await rig.connection.getFaces()), scroll: scroll,
                                        name: info.name, customName: info.customName, bootID: try XCTUnwrap(info.bootId))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rigs.compactMap(\.original)).write(to: scratch.appendingPathComponent("originals.json"), options: .atomic)
            for rig in rigs { rig.touched = true }
            try await rapidTargetBursts(rigs, sessions: sessions, scratch: scratch)
            for rig in rigs {
                sessions.select(rig.session)
                try await singleScroll(rig, peer: try XCTUnwrap(rigs.first { $0 !== rig }))
            }
            let created = store.create(name: "Temporary physical scroll stress")
            for rig in rigs { try store.addMember(groupID: created.id, member: .init(physicalBoardID: rig.id, displayName: rig.id)) }
            for mode in [BoardGroup.Mode.mirror, .stitched] {
                store.setMode(id: created.id, mode: mode)
                if mode == .stitched { try store.setGap(groupID: created.id, afterSlot: 0, columns: 2) }
                let group = try XCTUnwrap(store.groups.first { $0.id == created.id })
                activeGroup = group
                fanOut.setTarget(.group(group.id))
                try await groupFrameBursts(rigs, fanOut: fanOut, mode: mode, scratch: scratch)
                try await groupScroll(group, rigs: rigs, coordinator: coordinator)
                await coordinator.stop(group: group)
                activeGroup = nil
                fanOut.setTarget(.single)
            }
            try await storedDataUnchanged(rigs)
            try require(rigs.allSatisfy { $0.sentFrames >= 200 }, "Every board must receive at least 200 acknowledged frame submissions")
            print("[MacScrollStressHardwareTests] phasesComplete=true selectedTargetSwitches=40 acknowledgedFramesA=\(rigs[0].sentFrames) acknowledgedFramesB=\(rigs[1].sentFrames) singleMirrorStitchedRates=1,10,20,60 naturalReanchorWindowSeconds=34")
        } catch { testError = error }

        // Uncancelled cleanup still runs if a stress phase throws/cancels.
        // Stop app producers before restoring settings and rebooting RAM away.
        let groupToStop = activeGroup
        let cleanup = Task.detached { @MainActor in
            if let groupToStop { await coordinator.stop(group: groupToStop) }
            fanOut.setTarget(.single)
            scanner.stopScan()
            var failures: [String] = []
            for rig in rigs {
                if rig.touched, let original = rig.original {
                    do {
                        try await self.restore(rig, original: original)
                    } catch { failures.append("\(rig.id): restoration: \(error.localizedDescription)") }
                    do { try await self.clearTestRAMAndReconnect(rig, original: original) }
                    catch { failures.append("\(rig.id): cleanup reboot: \(error.localizedDescription)") }
                    // Runtime color/brightness/frame are not persisted by reboot.
                    do { try await self.restore(rig, original: original) }
                    catch { failures.append("\(rig.id): final runtime restoration: \(error.localizedDescription)") }
                }
                rig.connection.disconnect(userInitiated: true)
                do {
                    let terminal = try await rig.ble.disconnectAndWait(timeout: 8)
                    if !terminal { failures.append("\(rig.id): terminal BLE disconnect unconfirmed") }
                    print("[MacScrollStressHardwareTests] board=\(rig.id) terminalDisconnectConfirmed=\(terminal)")
                } catch { failures.append("\(rig.id): disconnect: \(error.localizedDescription)") }
            }
            return failures
        }
        let cleanupFailures = await cleanup.value
        for failure in cleanupFailures { XCTFail(failure) }
        if let testError { throw testError }
        try require(cleanupFailures.isEmpty, cleanupFailures.joined(separator: "; "))
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
            try self.require(CBManager.authorization != .denied && CBManager.authorization != .restricted, "Mac host Bluetooth permission denied")
            if !scanner.isScanning { scanner.startScan() }
            return scanner.isScanning
        }
        try await wait("Exact two physical advertisements", timeout: 35) {
            rigs.allSatisfy { rig in scanner.discoveredPeripherals.contains { $0.id == rig.peripheralID && $0.advertisedName == "RinaBoard-\(rig.id)" } }
        }
        scanner.stopScan()
        for rig in rigs {
            rig.ble.peripheralIdentifier = rig.peripheralID
            try require(await rig.connection.connect(using: rig.ble), "\(rig.id): production BLE handshake: \(rig.connection.lastError ?? "failed")")
            try require(rig.connection.boardIdentity == rig.id && rig.connection.transportKind == .bluetooth, "\(rig.id): physical identity/carrier mismatch")
        }
    }
    private func makeEditor(_ label: String, scratch: URL) -> ControlViewModel {
        let editor = ControlViewModel(draftStorage: DraftStorage(directory: scratch.appendingPathComponent(label)))
        editor.livePreview = false
        return editor
    }
    private func draw(_ index: Int, editor: ControlViewModel, connection: BoardConnection) {
        editor.clear(connection: connection)
        editor.toggle(led: index % 370, connection: connection)
        editor.toggle(led: (index * 13 + 173) % 370, connection: connection)
        editor.toggle(led: (index * 29 + 317) % 370, connection: connection)
    }
    private func rapidTargetBursts(_ rigs: [Rig], sessions: BoardSessionStore, scratch: URL) async throws {
        let editors = rigs.map { makeEditor("targets-\($0.id)", scratch: scratch) }
        defer { for editor in editors { editor.releaseOutput() } }
        for turn in 0..<40 {
            let slot = turn % 2
            let target = rigs[slot], peer = rigs[1 - slot]
            let heldFrame = try await peer.connection.getFrame()
            let heldStatus = try await peer.connection.getStatus()
            let peerGeneration = peer.connection.connectionGeneration
            sessions.select(target.session)
            try require(sessions.active === target.session, "Target switch \(turn): wrong selected session")
            let editor = editors[slot]
            for item in 0..<10 {
                draw(turn * 10 + item + slot * 59, editor: editor, connection: sessions.active.connection)
                await editor.send(connection: sessions.active.connection)
                try require(editor.errorMessage == nil && editor.wasSent(in: target.connection), "\(target.id): burst \(turn)/\(item): \(editor.errorMessage ?? "unconfirmed send")")
                target.sentFrames += 1
            }
            let controls = BoardControlCenterModel()
            let brightness = 20 + turn % 31
            let color = slot == 0 ? "#327EA5" : "#A57E32"
            controls.setBrightness(brightness, connection: target.connection)
            await controls.setColor(hex: color, connection: target.connection)
            try await wait("Target \(target.id) newest parameters after burst \(turn)") {
                let status = try await target.connection.getStatus()
                return status.renderer?.brightness == brightness && status.renderer?.color?.uppercased() == color
            }
            controls.connectionChanged()
            let actual = try await target.connection.getFrame()
            let peerActual = try await peer.connection.getFrame()
            let peerStatus = try await peer.connection.getStatus()
            try require(actual == editor.draftFrame && peerActual == heldFrame &&
                        peerStatus.renderer?.brightness == heldStatus.renderer?.brightness && peerStatus.renderer?.color == heldStatus.renderer?.color &&
                        peer.connection.connectionGeneration == peerGeneration && peer.connection.connectionState == .connected &&
                        target.connection.boardIdentity == target.id && peer.connection.boardIdentity == peer.id,
                        "Target switch \(turn): newest frame/settings or held peer/carrier isolation failed")
            print("[MacScrollStressHardwareTests] selectedTargetSwitch=\(turn + 1) board=\(target.id) burstFrames=10 newestFrameVerified=true heldPeerVerified=true")
        }
    }
    private func groupFrameBursts(_ rigs: [Rig], fanOut: GroupControlFanOut, mode: BoardGroup.Mode, scratch: URL) async throws {
        let primary = try XCTUnwrap(fanOut.primaryConnection)
        let editor = makeEditor("group-\(mode.rawValue)", scratch: scratch)
        defer { editor.releaseOutput() }
        for burst in 0..<4 {
            for item in 0..<10 {
                draw(600 + burst * 10 + item, editor: editor, connection: primary)
                await editor.send(connection: primary)
                try require(editor.errorMessage == nil && editor.wasSent(in: primary), "\(mode): primary burst send failed")
            }
            let expected = editor.draftFrame
            for rig in rigs { try await wait("\(mode) \(rig.id): group newest frame") { try await rig.connection.getFrame() == expected } }
            try require(fanOut.memberErrors.isEmpty, "\(mode): physical group sink errors \(fanOut.memberErrors)")
        }
        print("[MacScrollStressHardwareTests] mode=\(mode.rawValue) groupBurstSubmissions=40 bothNewestFrameReadbacksVerified=true")
    }

    private func singleScroll(_ rig: Rig, peer: Rig) async throws {
        let model = TextViewModel() // No restoreDraft: never reads/writes the user's text draft.
        defer { model.releaseOutput() }
        let held = try await peer.connection.getFrame()
        model.text = sourceText + " " + String(rig.id.suffix(4))
        model.requestedFps = 10
        await model.send(connection: rig.connection)
        try require(model.errorMessage == nil, "\(rig.id): text upload: \(model.errorMessage ?? "unknown")")
        let timeline = try XCTUnwrap(model.timeline)
        let timelineID = try XCTUnwrap(model.boundTimelineId)
        for fps in rates {
            // Same-main-actor slider burst: latest intent must win.
            for edit in [60, 1, 20, 10, fps] { model.setRequestedFps(Double(edit), connection: rig.connection) }
            try await verifyPlayback(rig, timeline: timelineID, fps: fps, frameCount: timeline.frameCount, group: false, paused: false)
            try await measureRates([rig], fps: fps, timeline: timelineID, duration: fps == 1 ? 3.2 : 1.5, label: "single-playing")
            let pauseBaselineFps = fps == 10 ? 20 : 10
            model.setRequestedFps(Double(pauseBaselineFps), connection: rig.connection)
            try await verifyPlayback(rig, timeline: timelineID, fps: pauseBaselineFps, frameCount: timeline.frameCount, group: false, paused: false)
            await model.pause(connection: rig.connection)
            try await Task.sleep(for: .milliseconds(300)) // Production pause/resume tap lockout.
            await model.seek(toFrame: min(31, timeline.frameCount - 1), connection: rig.connection)
            let index = min(31, timeline.frameCount - 1)
            for edit in [1, 60, 10, 20, fps] { model.setRequestedFps(Double(edit), connection: rig.connection) }
            try await verifyPlayback(rig, timeline: timelineID, fps: fps, frameCount: timeline.frameCount, group: false, paused: true)
            try await heldFrame(rig, expected: timeline.frame(at: index), index: index, timeline: timelineID)
            await model.resume(connection: rig.connection)
            try await verifyPlayback(rig, timeline: timelineID, fps: fps, frameCount: timeline.frameCount, group: false, paused: false)
            try await measureRates([rig], fps: fps, timeline: timelineID, duration: fps == 1 ? 3.2 : 1.5, label: "single-resumed")
            try require(try await peer.connection.getFrame() == held, "\(rig.id): single text/retune routed to idle peer \(peer.id)")
            try require(model.errorMessage == nil, "\(rig.id): text playback model error: \(model.errorMessage ?? "")")
        }
        await model.stop(connection: rig.connection)
        try require((try await rig.connection.getStatus()).renderer?.firmwareScrollActive == false, "\(rig.id): single Stop readback")
        // stop_scroll restores an idle face after a documented 90 ms delay.
        try await Task.sleep(for: .milliseconds(200))
    }

    private func groupScroll(_ group: BoardGroup, rigs: [Rig], coordinator: BoardGroupCoordinator) async throws {
        try require(rigs.allSatisfy { $0.connection.supports(.group60Fps) }, "Both real firmwares must advertise group60Fps")
        try await coordinator.play(group: group, text: sourceText, fps: 10, loop: true)
        let timeline = try XCTUnwrap(coordinator.debugTimelineId)
        for fps in rates {
            try await rapidGroupRates(group, coordinator: coordinator, finalFps: fps)
            let snapshot = try XCTUnwrap(coordinator.playbackSnapshot)
            for rig in rigs { try await verifyPlayback(rig, timeline: timeline, fps: fps, frameCount: snapshot.frameCount, group: true, paused: false) }
            var clocks: [String: ClockOffsetEstimator] = [:]
            for rig in rigs { clocks[rig.id] = try await clock(rig) }
            try await measureRates(rigs, fps: fps, timeline: timeline, duration: fps == 1 ? 3.2 : 1.5,
                                   label: "\(group.mode.rawValue)-playing", clocks: clocks)
            let pauseBaselineFps = fps == 10 ? 20 : 10
            await coordinator.updatePlayback(group: group, fps: pauseBaselineFps, loop: true)
            for rig in rigs { try await verifyPlayback(rig, timeline: timeline, fps: pauseBaselineFps, frameCount: snapshot.frameCount, group: true, paused: false) }
            await coordinator.pause(group: group)
            try require(coordinator.isPaused, "\(group.mode): app group pause not accepted")
            await coordinator.step(group: group, direction: 7)
            let pausedIndex = coordinator.pausedFrame
            let pausedMeta = try await rigs[0].connection.getScrollMeta()
            let oldInterval = try XCTUnwrap(pausedMeta.scrollIntervalMs)
            // A paused group changes its pending anchor only. Physical boards
            // keep the old interval and exact windows until Resume.
            for edit in [60, 1, 20, 10, fps] { await coordinator.updatePlayback(group: group, fps: edit, loop: true) }
            try require(coordinator.isPaused, "\(group.mode): paused speed edits resumed the group")
            for (slot, member) in snapshot.memberOrder.enumerated() {
                let rig = try XCTUnwrap(rigs.first { $0.id == member.physicalBoardID })
                let meta = try await rig.connection.getScrollMeta()
                try require(meta.scrollIntervalMs == oldInterval && meta.firmwareScrollPaused == true && meta.scrollTimelineId == timeline,
                            "\(rig.id): paused group edits changed interval/timeline/pause")
                let expected = GroupScrollBitmap.frame(bitmap: snapshot.bitmap, viewportX: snapshot.viewportXs[slot], frameIndex: pausedIndex)
                try await heldFrame(rig, expected: expected, index: pausedIndex, timeline: timeline)
            }
            await coordinator.resume(group: group)
            try require(coordinator.isPlaying && !coordinator.isPaused, "\(group.mode): group Resume failed")
            for rig in rigs { try await verifyPlayback(rig, timeline: timeline, fps: fps, frameCount: snapshot.frameCount, group: true, paused: false) }
            try await measureRates(rigs, fps: fps, timeline: timeline, duration: fps == 1 ? 3.2 : 1.5,
                                   label: "\(group.mode.rawValue)-resumed", clocks: clocks)
        }
        if group.mode == .stitched {
            // Resume starts the production 30-tick reanchor loop anew. No
            // debug seam: this observes uninterrupted real high-rate output
            // across the natural reanchor and verifies the same timeline.
            var clocks: [String: ClockOffsetEstimator] = [:]
            for rig in rigs { clocks[rig.id] = try await clock(rig) }
            try await measureRates(rigs, fps: 60, timeline: timeline, duration: 34,
                                   label: "stitched-natural-30s-reanchor", clocks: clocks)
            try require(coordinator.isPlaying && coordinator.activeGroupID == group.id && coordinator.debugTimelineId == timeline,
                        "Natural reanchor changed group/timeline/playback ownership")
        }
    }
    private func rapidGroupRates(_ group: BoardGroup, coordinator: BoardGroupCoordinator, finalFps: Int) async throws {
        // Ensure the first request reaches its clock-sampling await before
        // subsequent calls coalesce into the coordinator's pending intent.
        var admitted = false
        let first = Task { @MainActor in
            admitted = true
            await coordinator.updatePlayback(group: group, fps: 1, loop: true)
        }
        while !admitted { await Task.yield() }
        for edit in [60, 10, 20, 1, 60, finalFps] { await coordinator.updatePlayback(group: group, fps: edit, loop: true) }
        await first.value
        try require(coordinator.isPlaying, "\(group.mode): rapid playing rate edits lost group playback")
    }
    private func verifyPlayback(_ rig: Rig, timeline: String, fps: Int, frameCount: Int, group: Bool, paused: Bool) async throws {
        let interval = ScrollRasterizer.intervalMs(forFps: fps)
        try await wait("\(rig.id): \(fps) FPS group=\(group) paused=\(paused)") {
            let meta = try await rig.connection.getScrollMeta()
            let status = try await rig.connection.getStatus() // Reliable GET_STATUS, bypasses drop-oldest command pump.
            let metadataMatches = meta.scrollTimelineId == timeline && meta.scrollIntervalMs == interval && meta.frameCount == frameCount && meta.uploadComplete == true &&
                meta.firmwareScrollPaused == paused && meta.firmwareScrollActive == true &&
                (!group || paused || meta.groupTimed == true) && status.renderer?.scrollIntervalMs == interval &&
                status.renderer?.scrollTimelineId == timeline && status.renderer?.firmwareScrollPaused == paused
            guard metadataMatches else { return false }
            if !paused {
                // A retune can precede the next physical tick by a whole
                // interval (one second at 1 FPS). Wait for its presentation.
                let presented = try await rig.connection.getPreviewSync()
                return presented.scrollIntervalMs == interval && presented.rateEligible == true && presented.scrollTimelineId == timeline
            }
            return true
        }
        let preview = try await rig.connection.getPreviewSync()
        try require(preview.scrollTimelineId == timeline && preview.presentedAtUs != nil && preview.presentedSeq != nil && preview.scrollAdvanceSeq != nil,
                    "\(rig.id): missing physical presentation metadata at \(fps) FPS")
    }
    private func heldFrame(_ rig: Rig, expected: PackedFrame, index: Int, timeline: String) async throws {
        for _ in 0..<2 {
            let actual = try await rig.connection.getFrame()
            let preview = try await rig.connection.getPreviewSync()
            try require(actual == expected && preview.scrollTimelineId == timeline && preview.firmwareScrollPaused == true &&
                        preview.presentedFrameIndex == index,
                        "\(rig.id): paused hardware frame/presented cursor differs from expected viewport \(index)")
            try await Task.sleep(for: .milliseconds(150))
        }
    }
    private func monotonicUs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1_000_000) }
    private func clock(_ rig: Rig) async throws -> ClockOffsetEstimator {
        var estimator = ClockOffsetEstimator()
        for _ in 0..<4 {
            let m1 = monotonicUs()
            let reply: ClockSampleReply = try await rig.connection.requestReliableDecoding(.clockSample)
            let m4 = monotonicUs()
            try require(reply.ok == true && reply.bootId == rig.original?.bootID, "\(rig.id): physical clock/boot identity mismatch")
            estimator.addSample(ClockSample(m1: m1, b2: try XCTUnwrap(reply.rxUs), b3: try XCTUnwrap(reply.txUs), m4: m4), bootId: try XCTUnwrap(reply.bootId))
        }
        try require((estimator.bestRttUs ?? Int64.max) <= 200_000, "\(rig.id): clock uncertainty exceeds 200 ms; cannot assess physical synchronization")
        return estimator
    }
    private func measureRates(_ rigs: [Rig], fps: Int, timeline: String, duration: TimeInterval, label: String,
                              clocks: [String: ClockOffsetEstimator] = [:]) async throws {
        let interval = ScrollRasterizer.intervalMs(forFps: fps)
        let expectedFPS = 1000.0 / Double(interval) // 60 label is 17 ms: about 58.82 physical FPS.
        let deadline = Date().addingTimeInterval(duration)
        var first: [String: PreviewSync] = [:], last: [String: PreviewSync] = [:]
        var synchronizedSamples = 0
        repeat {
            var current: [String: PreviewSync] = [:]
            for rig in rigs {
                let sample = try await rig.connection.getPreviewSync()
                try require(sample.scrollTimelineId == timeline && sample.scrollIntervalMs == interval &&
                            sample.firmwareScrollActive == true && sample.firmwareScrollPaused == false,
                            "\(label) \(rig.id): wrong timeline/interval or unexpected pause")
                let presented = try XCTUnwrap(sample.presentedSeq)
                _ = try XCTUnwrap(sample.presentedAtUs)
                _ = try XCTUnwrap(sample.scrollAdvanceSeq)
                if sample.rateEligible == true {
                    if first[rig.id] == nil { first[rig.id] = sample }
                    if let previous = last[rig.id] {
                        try require(presented >= (previous.presentedSeq ?? 0), "\(label) \(rig.id): presentation sequence regressed")
                    }
                    last[rig.id] = sample
                }
                current[rig.id] = sample
            }
            if rigs.count == 2, !clocks.isEmpty {
                try synchronized(current, rigs: rigs, clocks: clocks, interval: interval, label: label)
                synchronizedSamples += 1
            }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        for rig in rigs {
            let begin = try XCTUnwrap(first[rig.id]), end = try XCTUnwrap(last[rig.id])
            let elapsedUs = try XCTUnwrap(end.presentedAtUs) - XCTUnwrap(begin.presentedAtUs)
            let advances = try XCTUnwrap(end.scrollAdvanceSeq) &- XCTUnwrap(begin.scrollAdvanceSeq)
            let presentations = try XCTUnwrap(end.presentedSeq) - XCTUnwrap(begin.presentedSeq)
            try require(elapsedUs > 0 && advances >= 2 && presentations >= 2, "\(label) \(rig.id): insufficient actual tick/presentation evidence")
            let actualFPS = Double(advances) * 1_000_000 / Double(elapsedUs)
            try require(abs(actualFPS - expectedFPS) / expectedFPS <= 0.12,
                        "\(label) \(rig.id): measured \(actualFPS) FPS, expected \(expectedFPS) from \(interval) ms; advances=\(advances), presented=\(presentations), elapsedUs=\(elapsedUs)")
            print("[MacScrollStressHardwareTests] phase=\(label) board=\(rig.id) requestedFPS=\(fps) intervalMs=\(interval) expectedPhysicalFPS=\(expectedFPS) measuredPhysicalFPS=\(actualFPS) scrollAdvanceDelta=\(advances) presentedSeqDelta=\(presentations) presentedElapsedUs=\(elapsedUs) latencyCorrectedSyncSamples=\(synchronizedSamples)")
        }
    }
    private func synchronized(_ samples: [String: PreviewSync], rigs: [Rig], clocks: [String: ClockOffsetEstimator],
                              interval: Int, label: String) throws {
        let a = try XCTUnwrap(samples[rigs[0].id]), b = try XCTUnwrap(samples[rigs[1].id])
        let clockA = try XCTUnwrap(clocks[rigs[0].id]), clockB = try XCTUnwrap(clocks[rigs[1].id])
        let atA = try XCTUnwrap(clockA.phoneTime(forBoard: XCTUnwrap(a.presentedAtUs)))
        let atB = try XCTUnwrap(clockB.phoneTime(forBoard: XCTUnwrap(b.presentedAtUs)))
        let count = try XCTUnwrap(a.presentedFrameCount ?? a.frameCount)
        try require(count > 1 && (b.presentedFrameCount ?? b.frameCount) == count, "\(label): group frame counts disagree")
        let indexA = try XCTUnwrap(a.presentedFrameIndex), indexB = try XCTUnwrap(b.presentedFrameIndex)
        // Compare phase at a common instant, accounting for sequential BLE
        // reads and wraparound. Never equate two raw moving cursors.
        let phaseDelta = Double(indexB - indexA) - Double(atB - atA) / Double(interval * 1000)
        let wrappedError = abs(phaseDelta - (phaseDelta / Double(count)).rounded() * Double(count))
        let uncertaintyUs = Double((clockA.bestRttUs ?? 0) + (clockB.bestRttUs ?? 0)) / 2
        let tolerance = 1.5 + uncertaintyUs / Double(interval * 1000)
        try require(wrappedError <= tolerance, "\(label): corrected group phase error \(wrappedError) frames > \(tolerance); indexes \(indexA)/\(indexB), presentationTimeDeltaUs=\(atB - atA)")
    }

    private func storedDataUnchanged(_ rigs: [Rig]) async throws {
        for rig in rigs {
            let original = try XCTUnwrap(rig.original)
            let faces = try FaceDocument(jsonData: await rig.connection.getFaces())
            let info = try await rig.connection.requestReliable(.getInfo)
            let status = try await rig.connection.getStatus()
            try require(faces == original.faces && info.name == original.name && info.customName == original.customName,
                        "\(rig.id): full saved-face JSON/name changed")
            try require(status.wifi?.mode == original.status.wifi?.mode && status.wifi?.homeSsid == original.status.wifi?.homeSsid &&
                        status.wifi?.hotspotSsid == original.status.wifi?.hotspotSsid && status.wifi?.apSsid == original.status.wifi?.apSsid && status.wifi?.staConnected != true,
                        "\(rig.id): original AP-only Wi-Fi state changed")
        }
    }
    private func restore(_ rig: Rig, original: Original) async throws {
        let connection = rig.connection
        connection.output.invalidate()
        var failures: [String] = []
        func attempt(_ label: String, _ operation: () async throws -> Void) async {
            do { try await operation() } catch { failures.append("\(label): \(error.localizedDescription)") }
        }
        let renderer = try XCTUnwrap(original.status.renderer)
        await attempt("stop scroll") { _ = try await connection.requestReliable(.stopScroll(restoreAuto: false, clear: false)) }
        await attempt("manual mode") { _ = try await connection.requestReliable(.setMode(mode: "manual")) }
        await attempt("brightness") { _ = try await connection.requestReliable(.setBrightness(raw: XCTUnwrap(renderer.brightness))) }
        await attempt("color") { _ = try await connection.requestReliable(.setColor(hex: XCTUnwrap(renderer.color))) }
        await attempt("auto interval") { _ = try await connection.requestReliable(.setAutoInterval(ms: XCTUnwrap(renderer.autoIntervalMs))) }
        await attempt("loop") { if let loop = original.scroll.scrollLoop { _ = try await connection.requestReliable(.setScrollLoop(loop: loop)) } }
        await attempt("original full face JSON") {
            if try FaceDocument(jsonData: await connection.getFaces()) != original.faces {
                try await connection.saveFaces(document: original.faces)
            }
        }
        await attempt("original name") {
            let info = try await connection.requestReliable(.getInfo)
            if info.name != original.name || info.customName != original.customName {
                _ = try await connection.requestReliable(.setDeviceName(name: original.customName == true ? (original.name ?? "") : ""))
            }
        }
        await attempt("saved face index") {
            if let index = renderer.autoFaceIndex, original.faces.sortedFaces.indices.contains(index) {
                _ = try await connection.requestReliable(.applySavedFace(index: index, id: original.faces.sortedFaces[index].id, reason: "scroll_stress_restore", playback: "idle"))
            }
        }
        await attempt("original frame") {
            // stop_scroll's delayed face restoration must settle first.
            try await Task.sleep(for: .milliseconds(200))
            let frame = try XCTUnwrap(PackedFrame(hex94: original.frameHex))
            _ = try await connection.setFrame(frame, playback: .idle, reason: renderer.lastReason ?? "scroll_stress_restore")
            try require(try await connection.getFrame() == frame, "Original displayed frame differs")
        }
        await attempt("settings/name/faces readback") {
            let status = try await connection.getStatus()
            try require(status.renderer?.brightness == renderer.brightness && status.renderer?.color?.uppercased() == renderer.color?.uppercased() &&
                        status.renderer?.autoIntervalMs == renderer.autoIntervalMs && status.renderer?.mode == renderer.mode &&
                        status.renderer?.autoFaceIndex == renderer.autoFaceIndex && status.renderer?.firmwareScrollActive == false,
                        "Original runtime face/brightness/color/interval/mode restoration failed")
            try await storedDataUnchanged([rig])
        }
        try require(failures.isEmpty, failures.joined(separator: "; "))
        print("[MacScrollStressHardwareTests] board=\(rig.id) originalFullFacesNameAPSettingsRuntimeRestored=true")
    }
    private func clearTestRAMAndReconnect(_ rig: Rig, original: Original) async throws {
        // Firmware settings persistence debounce is 1000 ms.
        try await Task.sleep(for: .milliseconds(1200))
        _ = try await rig.connection.requestReliable(.reboot)
        rig.connection.disconnect(userInitiated: true)
        try require(try await rig.ble.disconnectAndWait(timeout: 8), "\(rig.id): reboot terminal disconnect unconfirmed")
        try await Task.sleep(for: .seconds(2))
        try require(await rig.connection.connect(using: rig.ble), "\(rig.id): cleanup reboot reconnect failed")
        let info = try await rig.connection.requestReliable(.getInfo)
        let meta = try await rig.connection.getScrollMeta()
        try require(rig.connection.boardIdentity == rig.id && info.bootId != original.bootID && meta.firmwareScrollActive != true && (meta.frameCount ?? 0) == 0,
                    "\(rig.id): cleanup reboot failed to clear test RAM timeline")
        try await storedDataUnchanged([rig])
        print("[MacScrollStressHardwareTests] board=\(rig.id) cleanupRebootVerified=true testRAMTimelineCleared=true")
    }
}
#endif
