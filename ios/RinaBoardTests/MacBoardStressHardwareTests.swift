import CoreBluetooth
import Foundation
import RinaCore
import XCTest
@testable import RinaBoard

#if targetEnvironment(macCatalyst)
/// BLE-only, opt-in stress of the Mac app's production models. Run serially
/// with the interactive app disconnected. Never changes faces, names, Wi-Fi
/// credentials, battery calibration, or firmware; never reboots a board.
@MainActor
final class MacBoardStressHardwareTests: XCTestCase {
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
        let name: String?
        let customName: Bool?
        let bootID: String?
    }
    @MainActor
    private final class Rig {
        let id: String
        let session: BoardSession
        let ble: BLETransport
        var original: Original?
        var touched = false
        init(id: String, session: BoardSession) throws {
            self.id = id
            self.session = session
            self.ble = try XCTUnwrap(session.bleTransport as? BLETransport)
        }
        var connection: BoardConnection { session.connection }
    }

    func testSingleGroupAndSelectedBoardBLEStressAndRestore() async throws {
        guard ProcessInfo.processInfo.environment["RINA_MAC_HARDWARE_TESTS"] == "1",
              ProcessInfo.processInfo.environment["RINA_MAC_STRESS_TESTS"] == "1" else {
            throw XCTSkip("Set RINA_MAC_HARDWARE_TESTS=1 and RINA_MAC_STRESS_TESTS=1 for physical stress")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rina-board-stress-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suiteName = "rina.mac.stress.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }
        let sessions = BoardSessionStore()
        let scanner = try XCTUnwrap(sessions.scanner as? BLETransport)
        let rigs = try boardIDs.map { try Rig(id: $0, session: sessions.session(for: $0, name: "RinaBoard-\($0)")) }
        let groups = BoardGroupStore(defaults: defaults)
        let coordinator = BoardGroupCoordinator(store: groups, sessions: sessions)
        sessions.isGroupOwned = { coordinator.isGroupOwned($0) }
        let fanOut = GroupControlFanOut(sessions: sessions, groups: groups, coordinator: coordinator)
        var testError: Error?
        do {
            try await connect(rigs, scanner: scanner)
            for rig in rigs {
                let status = try await rig.connection.getStatus()
                let frame = try await rig.connection.getFrame()
                let faces = try FaceDocument(jsonData: await rig.connection.getFaces())
                let scroll = try await rig.connection.getScrollMeta()
                let info = try await rig.connection.command(.getInfo)
                try require(info.ok, "\(rig.id): original device info")
                rig.original = Original(id: rig.id, status: status, frameHex: frame.hex94, faces: faces,
                                        scroll: scroll, name: info.name, customName: info.customName, bootID: info.bootId)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let recoveryURL = FileManager.default.temporaryDirectory.appendingPathComponent("rina-board-stress-originals.json")
            try encoder.encode(rigs.compactMap(\.original)).write(to: recoveryURL, options: .atomic)
            print("Board stress recovery snapshot: \(recoveryURL.path)")
            for rig in rigs {
                let original = try XCTUnwrap(rig.original)
                let renderer = try XCTUnwrap(original.status.renderer)
                try require(["manual", "auto"].contains(renderer.mode ?? "") && original.scroll.firmwareScrollActive != true &&
                            !["video", "performance", "lipSync", "text"].contains(renderer.outputMode ?? ""),
                            "\(rig.id): stress requires restorable manual/auto output, without an active opaque media/scroll owner")
                _ = try XCTUnwrap(renderer.brightness)
                _ = try XCTUnwrap(renderer.color)
                _ = try XCTUnwrap(renderer.autoIntervalMs)
            }
            // Freeze each original auto producer before peer-held assertions.
            for rig in rigs {
                rig.touched = true
                let controls = BoardControlCenterModel()
                controls.sync(from: rig.connection.status)
                if controls.isAutoMode(status: rig.connection.status) { await controls.toggleAutoMode(connection: rig.connection) }
                controls.connectionChanged()
                try require((try await rig.connection.getStatus()).renderer?.mode == "manual", "\(rig.id): stress manual admission")
            }
            for rig in rigs {
                let peer = try XCTUnwrap(rigs.first { $0 !== rig })
                sessions.select(rig.session)
                try await singleBoardFrames(rig, peer: peer, scratch: scratch)
                try await singleBoardSettings(rig, peer: peer)
            }

            let group = groups.create(name: "Temporary BLE stress group")
            for rig in rigs { try groups.addMember(groupID: group.id, member: .init(physicalBoardID: rig.id, displayName: rig.id)) }
            for mode in [BoardGroup.Mode.mirror, .stitched] {
                groups.setMode(id: group.id, mode: mode)
                if mode == .stitched { try groups.setGap(groupID: group.id, afterSlot: 0, columns: 2) }
                fanOut.setTarget(.group(group.id))
                let primary = try XCTUnwrap(fanOut.primaryConnection)
                let primaryRig = try XCTUnwrap(rigs.first { $0.connection === primary })
                try await groupFrames(primaryRig, rigs: rigs, mode: mode, scratch: scratch)
                try await groupSettings(primaryRig, rigs: rigs, mode: mode)
                try require(fanOut.memberErrors.isEmpty, "\(mode): group sink errors \(fanOut.memberErrors)")
            }
            fanOut.setTarget(.single)
            // Stitched mode's editor/control frames intentionally mirror in
            // production. Text viewports need a new opaque RAM timeline; this
            // stress suite preserves any existing timeline and never reboots.
            print("[MacBoardStressHardwareTests] stitchedTextUploadSkipped=true existingResidentTimelinePreserved=true")
            try await selectedBoardSwitches(rigs, sessions: sessions, scratch: scratch)
            try await identityAndStoredData(rigs)
            print("[MacBoardStressHardwareTests] phasesCompleted=true singleIntendedFrameReadbacks=100 singleHeldPeerReadbacks=100 groupMemberFrameReadbacks=200 selectedSwitchReadbacks=40")
        } catch { testError = error }

        let cleanup = Task.detached { @MainActor in
            fanOut.setTarget(.single)
            scanner.stopScan()
            var failures: [String] = []
            for rig in rigs {
                if rig.touched, let original = rig.original {
                    do { try await self.restore(rig, original: original) }
                    catch { failures.append("\(rig.id): restore: \(error.localizedDescription)") }
                }
                rig.connection.disconnect(userInitiated: true)
                do {
                    let confirmed = try await rig.ble.disconnectAndWait(timeout: 8)
                    if !confirmed { failures.append("\(rig.id): terminal disconnect unconfirmed") }
                    print("[MacBoardStressHardwareTests] \(rig.id) terminalDisconnectConfirmed=\(confirmed)")
                } catch { failures.append("\(rig.id): terminal disconnect: \(error.localizedDescription)") }
            }
            return failures
        }
        let failures = await cleanup.value
        for failure in failures { XCTFail(failure) }
        if let testError { throw testError }
        try require(failures.isEmpty, failures.joined(separator: "; "))
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    private func wait(_ label: String, timeout: TimeInterval = 3, condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if try await condition() { return }
            try require(Date() < deadline, "Timed out: \(label)")
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func connect(_ rigs: [Rig], scanner: BLETransport) async throws {
        let deadline = Date().addingTimeInterval(35)
        while !scanner.isScanning {
            try require(CBManager.authorization != .denied && CBManager.authorization != .restricted, "Bluetooth permission denied")
            try require(Date() < deadline, "Bluetooth scan did not become ready")
            scanner.startScan()
            try await Task.sleep(for: .milliseconds(100))
        }
        while !rigs.allSatisfy({ rig in scanner.discoveredPeripherals.contains { $0.advertisedName == "RinaBoard-\(rig.id)" } }) {
            try Task.checkCancellation()
            try require(Date() < deadline, "Exact two board advertisements missing")
            try await Task.sleep(for: .milliseconds(100))
        }
        for rig in rigs {
            rig.ble.peripheralIdentifier = try XCTUnwrap(scanner.discoveredPeripherals.first { $0.advertisedName == "RinaBoard-\(rig.id)" }?.id)
        }
        scanner.stopScan()
        for rig in rigs {
            try require(await rig.connection.connect(using: rig.ble), "\(rig.id): production BLE handshake \(rig.connection.lastError ?? "failed")")
            try require(rig.connection.boardIdentity == rig.id && rig.connection.transportKind == .bluetooth, "\(rig.id): exact physical BLE identity")
            print("[MacBoardStressHardwareTests] \(rig.id) productionBLEHandshakeIdentityVerified=true")
        }
        try require(rigs.allSatisfy { $0.connection.connectionState == .connected }, "Both independent BLE carriers must remain ready")
    }
    private func makeEditor(_ label: String, scratch: URL) -> ControlViewModel {
        let model = ControlViewModel(draftStorage: DraftStorage(directory: scratch.appendingPathComponent(label)))
        model.livePreview = false
        return model
    }
    private func draw(_ iteration: Int, model: ControlViewModel, connection: BoardConnection) {
        model.clear(connection: connection)
        model.toggle(led: iteration % 370, connection: connection)
        model.toggle(led: (iteration * 7 + 131) % 370, connection: connection)
    }
    private func holdTenFPS(since start: Date) async throws {
        let remaining = 0.1 - Date().timeIntervalSince(start)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
    }
    private func singleBoardFrames(_ rig: Rig, peer: Rig, scratch: URL) async throws {
        let phaseStart = Date()
        let peerFrame = try await peer.connection.getFrame()
        let model = makeEditor("single-\(rig.id)", scratch: scratch)
        defer { model.releaseOutput() }
        for index in 0..<50 {
            let start = Date()
            draw(index, model: model, connection: rig.connection)
            await model.send(connection: rig.connection)
            try require(model.errorMessage == nil && model.wasSent(in: rig.connection), "\(rig.id): editor send \(index) failed")
            let actual = try await rig.connection.getFrame()
            let held = try await peer.connection.getFrame()
            try require(actual == model.draftFrame && held == peerFrame, "\(rig.id): frame \(index) target/peer readback")
            try await holdTenFPS(since: start)
        }
        let elapsed = Date().timeIntervalSince(phaseStart)
        print("[MacBoardStressHardwareTests] \(rig.id) singleFrames=50 intendedReadbacks=50 peerUnchangedReadbacks=50 requestedFPS=10 elapsedSeconds=\(elapsed) measuredFPS=\(50 / elapsed)")
    }
    private func singleBoardSettings(_ rig: Rig, peer: Rig) async throws {
        let peerBefore = try await peer.connection.getStatus()
        let peerFrame = try await peer.connection.getFrame()
        let model = BoardControlCenterModel()
        defer { model.connectionChanged() }
        let baseline = try await rig.connection.getStatus()
        let initialBrightness = try XCTUnwrap(baseline.renderer?.brightness)
        for index in 0..<5 {
            let brightness = min(RinaLinkConstants.brightnessMax, max(RinaLinkConstants.brightnessMin, initialBrightness + (index % 2 == 0 ? -1 : 1)))
            let color = index % 2 == 0 ? "#275B8D" : "#8D275B"
            model.setBrightness(brightness, connection: rig.connection)
            await model.setColor(hex: color, connection: rig.connection)
            try await wait("\(rig.id) control burst \(index)") {
                let actual = try await rig.connection.getStatus()
                return actual.renderer?.brightness == brightness && actual.renderer?.color?.uppercased() == color
            }
            let actualPeer = try await peer.connection.getStatus()
            let actualFrame = try await peer.connection.getFrame()
            try require(actualPeer.renderer?.brightness == peerBefore.renderer?.brightness && actualPeer.renderer?.color == peerBefore.renderer?.color &&
                        actualFrame == peerFrame, "\(rig.id): control burst changed peer settings/frame")
        }
        print("[MacBoardStressHardwareTests] \(rig.id) singleControlBursts=5 targetAndPeerSettingsFrameReadbacksVerified=true")
    }
    private func groupFrames(_ primary: Rig, rigs: [Rig], mode: BoardGroup.Mode, scratch: URL) async throws {
        let phaseStart = Date()
        let editor = makeEditor("group-\(mode.rawValue)", scratch: scratch)
        defer { editor.releaseOutput() }
        for index in 0..<50 {
            let start = Date()
            draw(index + 70, model: editor, connection: primary.connection)
            await editor.send(connection: primary.connection)
            try require(editor.errorMessage == nil && editor.wasSent(in: primary.connection), "\(mode): group editor send \(index)")
            let expected = editor.draftFrame
            for rig in rigs { try await wait("\(mode) \(rig.id) group frame \(index)") { try await rig.connection.getFrame() == expected } }
            try await holdTenFPS(since: start)
        }
        let elapsed = Date().timeIntervalSince(phaseStart)
        print("[MacBoardStressHardwareTests] bothBoards mode=\(mode.rawValue) groupFrames=50 physicalMemberReadbacks=100 requestedFPS=10 elapsedSeconds=\(elapsed) measuredFPS=\(50 / elapsed)")
    }
    private func groupSettings(_ primary: Rig, rigs: [Rig], mode: BoardGroup.Mode) async throws {
        let controls = BoardControlCenterModel()
        defer { controls.connectionChanged() }
        for index in 0..<5 {
            let brightness = RinaLinkConstants.brightnessMin + 10 + index
            let color = index % 2 == 0 ? "#396FA5" : "#A5396F"
            controls.setBrightness(brightness, connection: primary.connection)
            await controls.setColor(hex: color, connection: primary.connection)
            for rig in rigs {
                try await wait("\(mode) \(rig.id) group control burst \(index)") {
                    let status = try await rig.connection.getStatus()
                    return status.renderer?.brightness == brightness && status.renderer?.color?.uppercased() == color
                }
            }
        }
        print("[MacBoardStressHardwareTests] bothBoards mode=\(mode.rawValue) groupControlBursts=5 physicalMemberSettingsReadbacks=10")
    }
    private func selectedBoardSwitches(_ rigs: [Rig], sessions: BoardSessionStore, scratch: URL) async throws {
        let editors = rigs.map { makeEditor("selected-\($0.id)", scratch: scratch) }
        defer { for editor in editors { editor.releaseOutput() } }
        for index in 0..<20 {
            let targetIndex = index % 2
            let target = rigs[targetIndex]
            let peer = rigs[1 - targetIndex]
            let heldFrame = try await peer.connection.getFrame()
            let heldStatus = try await peer.connection.getStatus()
            let generation = peer.connection.connectionGeneration
            sessions.select(target.session)
            try require(sessions.active === target.session, "Selected-board switch \(index) did not select target")
            let model = editors[targetIndex]
            draw(index + 170, model: model, connection: sessions.active.connection)
            await model.send(connection: sessions.active.connection)
            let controls = BoardControlCenterModel()
            let brightness = RinaLinkConstants.brightnessMin + 15 + index % 3
            let color = targetIndex == 0 ? "#2D7FA1" : "#A17F2D"
            controls.setBrightness(brightness, connection: sessions.active.connection)
            await controls.setColor(hex: color, connection: sessions.active.connection)
            try await wait("Selected target settings \(index)") {
                let status = try await target.connection.getStatus()
                return status.renderer?.brightness == brightness && status.renderer?.color?.uppercased() == color
            }
            controls.connectionChanged()
            let actual = try await target.connection.getFrame()
            let peerActual = try await peer.connection.getFrame()
            let peerStatus = try await peer.connection.getStatus()
            try require(model.errorMessage == nil && actual == model.draftFrame && peerActual == heldFrame &&
                        peerStatus.renderer?.brightness == heldStatus.renderer?.brightness && peerStatus.renderer?.color == heldStatus.renderer?.color &&
                        peer.connection.connectionGeneration == generation && peer.connection.connectionState == .connected &&
                        target.connection.boardIdentity == target.id && peer.connection.boardIdentity == peer.id,
                        "Selected-board switch \(index) target/held peer/identity/carrier isolation")
            print("[MacBoardStressHardwareTests] selectedSwitch=\(index + 1) target=\(target.id) targetFrameSettingsVerified=true peerFrameSettingsCarrierUnchanged=true")
        }
        print("[MacBoardStressHardwareTests] selectedBoardSwitches=20 physicalTargetPeerReadbacks=40")
    }
    private func identityAndStoredData(_ rigs: [Rig]) async throws {
        for rig in rigs {
            let original = try XCTUnwrap(rig.original)
            let info = try await rig.connection.command(.getInfo)
            let status = try await rig.connection.getStatus()
            let faces = try FaceDocument(jsonData: await rig.connection.getFaces())
            let scroll = try await rig.connection.getScrollMeta()
            try require(rig.connection.boardIdentity == rig.id && status.wifi?.boardId?.uppercased() == rig.id &&
                        rig.connection.transportKind == .bluetooth && info.bootId == original.bootID,
                        "\(rig.id): physical carrier/boot identity changed")
            try require(info.name == original.name && info.customName == original.customName && faces == original.faces && scroll == original.scroll,
                        "\(rig.id): saved data/name/resident timeline changed")
            try require(status.wifi?.mode == original.status.wifi?.mode && status.wifi?.homeSsid == original.status.wifi?.homeSsid &&
                        status.wifi?.hotspotSsid == original.status.wifi?.hotspotSsid && status.wifi?.apSsid == original.status.wifi?.apSsid,
                        "\(rig.id): Wi-Fi configuration changed")
            print("[MacBoardStressHardwareTests] \(rig.id) originalFacesNameNetworkTimelineBootPreserved=true")
        }
    }
    private func restore(_ rig: Rig, original: Original) async throws {
        let connection = rig.connection
        connection.output.invalidate()
        var failures: [String] = []
        func attempt(_ label: String, _ action: () async throws -> Void) async {
            do { try await action() } catch { failures.append("\(label): \(error.localizedDescription)") }
        }
        let renderer = try XCTUnwrap(original.status.renderer)
        await attempt("manual mode") { _ = try await connection.command(.setMode(mode: "manual")) }
        await attempt("brightness") { _ = try await connection.command(.setBrightness(raw: XCTUnwrap(renderer.brightness))) }
        await attempt("color") { _ = try await connection.command(.setColor(hex: XCTUnwrap(renderer.color))) }
        await attempt("interval") { _ = try await connection.command(.setAutoInterval(ms: XCTUnwrap(renderer.autoIntervalMs))) }
        await attempt("saved face selection") {
            if let index = renderer.autoFaceIndex, original.faces.sortedFaces.indices.contains(index) {
                _ = try await connection.command(.applySavedFace(index: index, id: original.faces.sortedFaces[index].id,
                                                               reason: renderer.lastReason ?? "stress_restore", playback: "idle"))
            }
        }
        await attempt("original frame") {
            let frame = try XCTUnwrap(PackedFrame(hex94: original.frameHex))
            if try await connection.getFrame() != frame { _ = try await connection.setFrame(frame, playback: .idle, reason: renderer.lastReason ?? "stress_restore") }
            try require(try await connection.getFrame() == frame, "Original held output readback failed")
        }
        await attempt("original mode/pause") {
            if renderer.mode == "auto" { _ = try await connection.command(.setMode(mode: "auto")) }
            if renderer.paused == true { _ = try await connection.command(.pause) }
        }
        await attempt("renderer settings readback") {
            let status = try await connection.getStatus()
            try require(status.renderer?.brightness == renderer.brightness && status.renderer?.color?.uppercased() == renderer.color?.uppercased() &&
                        status.renderer?.autoIntervalMs == renderer.autoIntervalMs && status.renderer?.mode == renderer.mode &&
                        (renderer.paused != true || status.renderer?.paused == true), "Original renderer settings readback failed")
        }
        await attempt("stored data verification") { try await identityAndStoredData([rig]) }
        try require(failures.isEmpty, failures.joined(separator: "; "))
        print("[MacBoardStressHardwareTests] \(rig.id) originalSettingsOutputRestored=true")
    }
}
#endif
