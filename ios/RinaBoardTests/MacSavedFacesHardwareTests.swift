import CoreBluetooth
import Foundation
import RinaCore
import XCTest
@testable import RinaBoard

#if targetEnvironment(macCatalyst)
/// Opt-in, reversible acceptance through the production BLE carrier. No frames,
/// playback modes, brightness values, or other output controls are written.
@MainActor
final class MacSavedFacesHardwareTests: XCTestCase {
    private let boardIDs = ["80B54EF48E09", "80B54EF74801"]
    private static let evidenceDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rina-transfer-acceptance", isDirectory: true)

    @MainActor
    private final class Rig {
        let id: String
        let transport = BLETransport()
        let connection = BoardConnection()
        var originalRaw: Data?
        var originalDocument: FaceDocument?
        var originalFrame: PackedFrame?
        var originalRenderer: RendererStatus?
        var observedTransport: SaveProbeTransport?
        let evidenceDirectory: URL
        var mayHaveWritten = false
        var proof: [[String: Any]] = []

        init(id: String, evidenceDirectory: URL? = nil,
             observeSave: Bool = false) {
            self.id = id
            self.evidenceDirectory = evidenceDirectory ?? MacSavedFacesHardwareTests.evidenceDirectory
            if observeSave { observedTransport = SaveProbeTransport(base: transport) }
        }

        func record(_ event: String, _ details: [String: Any] = [:]) throws {
            var entry = details
            entry["event"] = event
            entry["at"] = ISO8601DateFormatter().string(from: Date())
            proof.append(entry)
            let data = try JSONSerialization.data(withJSONObject: ["boardID": id, "events": proof], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: evidenceDirectory.appendingPathComponent("hardware-\(id)-proof.json"), options: .atomic)
            print("[MacSavedFacesHardwareTests] \(id) \(event) \(details)")
        }
    }

    /// Observes actual wire traffic and forwards every reply byte unchanged.
    /// The sole fault is a real CoreBluetooth disconnect at the readback
    /// boundary, after the board has acknowledged its committed upsert.
    @MainActor
    private final class SaveProbeTransport: @MainActor RinaTransport {
        let base: BLETransport
        var kind: TransportKind { base.kind }
        var preferredChunkBytes: Int { base.preferredChunkBytes }
        var requests: [RinaLinkFrame] = []
        var upsertACKs: [UInt8] = []
        var disconnectNextReadback = false
        var injectedDisconnectConfirmed = false
        private var injectedDisconnectTask: Task<Bool, Error>?
        private var upsertSequences = Set<UInt8>()

        init(base: BLETransport) { self.base = base }
        func stateStream() -> AsyncStream<TransportState> { base.stateStream() }
        func incomingStream() -> AsyncStream<Data> {
            let source = base.incomingStream()
            let pair = AsyncStream.makeStream(of: Data.self)
            let task = Task { @MainActor [weak self] in
                let decoder = RinaLinkDecoder()
                for await bytes in source {
                    guard !Task.isCancelled else { break }
                    for frame in decoder.feed(bytes) where frame.type == RinaLinkMessageType.cmd.replyType {
                        if let self, self.upsertSequences.remove(frame.seq) != nil,
                           let reply = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                           reply["ok"] as? Bool == true, reply["gen"] as? NSNumber != nil {
                            self.upsertACKs.append(frame.seq)
                        }
                    }
                    pair.continuation.yield(bytes)
                }
                pair.continuation.finish()
            }
            pair.continuation.onTermination = { _ in task.cancel() }
            return pair.stream
        }
        func connect() async throws { try await base.connect() }
        func disconnect() { base.disconnect() }
        func send(_ data: Data) async throws {
            let frames = RinaLinkDecoder().feed(data)
            guard frames.count == 1, let frame = frames.first else {
                throw HardwareFailure("Probe expected one complete production protocol request")
            }
            // Reject output/settings operations before they reach hardware.
            let allowed: Set<UInt8> = [RinaLinkMessageType.cmd, .getStatus, .getPower, .getFrame,
                                      .getPreviewSync, .ping, .getFaces, .blobBegin, .blobChunk,
                                      .blobEnd, .blobAbort].map(\.rawValue).reduce(into: []) { $0.insert($1) }
            guard allowed.contains(frame.type) else { throw HardwareFailure("Unexpected hardware write type \(frame.type)") }
            if frame.type == RinaLinkMessageType.cmd.rawValue {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
                let command = try XCTUnwrap(json["cmd"] as? String)
                guard ["get_info", "subscribe", "face_upsert"].contains(command) else {
                    throw HardwareFailure("Refusing output/settings command \(command)")
                }
                if command == "face_upsert" { upsertSequences.insert(frame.seq) }
            }
            requests.append(frame)
            if frame.type == RinaLinkMessageType.getFaces.rawValue, disconnectNextReadback, !upsertACKs.isEmpty {
                disconnectNextReadback = false
                // Emitting .disconnected makes BoardConnection fail the pending
                // read and cancel this broker send task. Terminal callback
                // evidence must survive that expected cancellation.
                let terminal = Task.detached { @MainActor [base] in
                    try await base.disconnectAndWait(timeout: 8)
                }
                injectedDisconnectTask = terminal
                _ = try await terminal.value
                throw RinaTransportError.notConnected
            }
            try await base.send(data)
        }
        func waitForInjectedDisconnect() async throws -> Bool {
            guard let injectedDisconnectTask else { return false }
            injectedDisconnectConfirmed = try await injectedDisconnectTask.value
            if !injectedDisconnectConfirmed {
                // The carrier's own teardown calls disconnect() again, waking
                // the first gate waiter as superseded. savePrepared has now
                // returned and that teardown is quiescent: independently wait
                // for the retained peripheral's real terminal state.
                injectedDisconnectConfirmed = try await base.disconnectAndWait(timeout: 8)
            }
            return injectedDisconnectConfirmed
        }
        var upsertCount: Int {
            requests.filter { frame in
                guard frame.type == RinaLinkMessageType.cmd.rawValue,
                      let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { return false }
                return json["cmd"] as? String == "face_upsert"
            }.count
        }
        var facesReadCount: Int { requests.filter { $0.type == RinaLinkMessageType.getFaces.rawValue }.count }
    }

    func testTwoBoardCoordinatorCommittedDisconnectExplicitRetryAndOwnOverwriteRestoresOriginals() async throws {
        guard ProcessInfo.processInfo.environment["RINA_SAVE_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set RINA_SAVE_HARDWARE_TESTS=1 to exercise the real two-board save coordinator")
        }
        // Each test/run keeps immutable recovery evidence, regardless of suite order.
        let directory = Self.evidenceDirectory.appendingPathComponent("dual-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("[MacSavedFacesHardwareTests] coordinatorEvidenceDirectory=\(directory.path)")
        let rigs = boardIDs.map { Rig(id: $0, evidenceDirectory: directory, observeSave: true) }
        defer { for rig in rigs { rig.connection.disconnect(userInitiated: true); rig.transport.stopScan() } }
        var testError: Error?
        do {
            let discovered = try await discoverBoards(using: rigs[0].transport)
            for rig in rigs {
                rig.transport.peripheralIdentifier = discovered[rig.id]
                try await connect(rig)
                try await backupForCoordinator(rig)
            }
            guard rigs.allSatisfy({ $0.originalRaw != nil && $0.connection.boardIdentity == $0.id
                && $0.connection.connectionState == .connected }) else {
                throw HardwareFailure("Both exact-identity durable backups are required before coordinator writes")
            }
            try await exerciseCoordinator(rigs, directory: directory)
        } catch {
            testError = error
            for rig in rigs { try? rig.record("coordinatorStopped", ["error": String(describing: error)]) }
        }
        // A cancelled XCTest task cannot cancel recovery. Try both boards even
        // if one restoration fails, and retain all raw backups and journals.
        let cleanup = Task.detached { @MainActor in
            var failures: [String] = []
            for rig in rigs {
                rig.observedTransport?.disconnectNextReadback = false
                do {
                    if rig.mayHaveWritten {
                        let originalRaw = try XCTUnwrap(rig.originalRaw)
                        if rig.connection.connectionState != .connected { try await self.connect(rig) }
                        guard rig.connection.boardIdentity == rig.id else { throw HardwareFailure("Restoration identity mismatch") }
                        _ = try await rig.connection.getFaces()
                        let boot = try XCTUnwrap(rig.connection.bootId)
                        let gen = try XCTUnwrap(rig.connection.currentFacesGeneration)
                        _ = try await rig.connection.uploadBlob(kind: .faces,
                            meta: ["expectedBootId": boot, "expectedGen": gen], data: originalRaw)
                        let restored = try await rig.connection.getFaces()
                        let actual = try JSONSerialization.jsonObject(with: restored) as? NSDictionary
                        let wanted = try JSONSerialization.jsonObject(with: originalRaw) as? NSDictionary
                        guard let actual, let wanted, actual.isEqual(wanted) else {
                            throw HardwareFailure("Restored raw library differs, including unknown record/root metadata")
                        }
                        try self.assertDocument(FaceDocument(jsonData: restored), equals: XCTUnwrap(rig.originalDocument), boardID: rig.id)
                        try await self.assertCoordinatorOutput(rig, phase: "afterCoordinatorRestore")
                        try rig.record("coordinatorOriginalRestored", ["exactJSONRecords": true, "frameUnchanged": true])
                    }
                } catch {
                    failures.append("\(rig.id): original library restoration failed: \(error); recovery: \(rig.evidenceDirectory.path)")
                    try? rig.record("coordinatorRestoreFailed", ["error": String(describing: error)])
                }
                rig.connection.disconnect(userInitiated: true)
                do {
                    let confirmed = try await rig.transport.disconnectAndWait(timeout: 8)
                    if !confirmed { failures.append("\(rig.id): terminal BLE disconnect unconfirmed") }
                    try rig.record("coordinatorTerminalDisconnect", ["confirmed": confirmed])
                } catch { failures.append("\(rig.id): terminal disconnect: \(error)") }
            }
            return failures
        }
        let failures = await cleanup.value
        for failure in failures { XCTFail(failure) }
        if let testError { throw testError }
        guard failures.isEmpty else { throw HardwareFailure("Coordinator hardware cleanup failed") }
    }

    private func backupForCoordinator(_ rig: Rig) async throws {
        let raw = try await rig.connection.getFaces()
        let document = try FaceDocument(jsonData: raw)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let records = try XCTUnwrap(object["faces"] as? [[String: Any]])
        let frame = try await rig.connection.getFrame()
        let status = try await rig.connection.getStatus()
        guard rig.connection.boardIdentity == rig.id, status.wifi?.boardId?.uppercased() == rig.id,
              records.count == document.faces.count, Set(document.faces.map(\.id)).count == document.faces.count,
              document.faces.allSatisfy({ $0.packedFrame != nil }) else {
            throw HardwareFailure("\(rig.id): exact physical identity or complete valid backup could not be established")
        }
        guard rig.connection.supportsConditionalFaceWrites, document.faces.count <= 126,
              let renderer = status.renderer, renderer.mode?.lowercased().contains("auto") != true,
              renderer.playback?.lowercased().contains("auto") != true, renderer.firmwareScrollActive != true else {
            throw XCTSkip("\(rig.id): conditional writes, two free face slots, and stationary output are required")
        }
        let backup: [String: Any] = ["boardID": rig.id, "facesBase64": raw.base64EncodedString(),
            "faces": object, "frameHex": frame.hex94, "status": try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)),
            "bootId": rig.connection.bootId ?? "", "gen": rig.connection.currentFacesGeneration ?? -1,
            "capturedAt": ISO8601DateFormatter().string(from: Date())]
        let backupURL = rig.evidenceDirectory.appendingPathComponent("hardware-\(rig.id)-before.json")
        let rawURL = rig.evidenceDirectory.appendingPathComponent("hardware-\(rig.id)-faces-original.json")
        try durableWrite(raw, to: rawURL)
        try durableWrite(JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys]), to: backupURL)
        guard try Data(contentsOf: rawURL) == raw else { throw HardwareFailure("Durable raw backup readback mismatch") }
        rig.originalRaw = raw; rig.originalDocument = document; rig.originalFrame = frame; rig.originalRenderer = renderer
        try rig.record("coordinatorBackupDurable", ["path": backupURL.path, "rawPath": rawURL.path,
                                                    "faces": document.faces.count, "bytes": raw.count])
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private func exerciseCoordinator(_ rigs: [Rig], directory: URL) async throws {
        let a = rigs[0], b = rigs[1]
        let probeA = try XCTUnwrap(a.observedTransport), probeB = try XCTUnwrap(b.observedTransport)
        let destinations = try rigs.map { try XCTUnwrap(FrozenFaceSaveDestination(name: $0.id, connection: $0.connection)) }
        let storage = DraftStorage(directory: directory.appendingPathComponent("drafts", isDirectory: true))
        let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
        var draft = PackedFrame(); for led in [3, 17, 101, 233, 369] { draft.set(led) }
        let name = "HW dual \(UUID().uuidString.prefix(8))"
        let snapshot = MultiBoardFaceSaveSnapshot(frameHex: draft.hex94, type: "custom", originBoardID: destinations[0].id)
        guard await coordinator.prepare(name: name, snapshot: snapshot, destinations: destinations) else {
            throw HardwareFailure("Coordinator prepare: \(coordinator.errorMessage ?? "unknown")")
        }
        let initial = try XCTUnwrap(coordinator.operation)
        let stableIDs = try initial.targets.map { try XCTUnwrap($0.payload.id) }
        guard Set(stableIDs).count == 2, initial.targets.allSatisfy(\.createOnly) else {
            throw HardwareFailure("Dual create must allocate a distinct stable ID for each board")
        }
        let prepared = MultiBoardFaceSaveCoordinator(storage: storage)
        await prepared.restore()
        guard prepared.operation?.targets.map(\.payload.id) == stableIDs.map(Optional.some) else {
            throw HardwareFailure("Per-board stable IDs were not durable before hardware mutation")
        }
        try durableWrite(JSONEncoder().encode(initial), to: directory.appendingPathComponent("prepared-operation.json"))
        for rig in rigs { try rig.record("coordinatorPrepared", ["stableIDs": stableIDs]); rig.mayHaveWritten = true }
        probeB.disconnectNextReadback = true
        let aWrites = probeA.upsertCount, bWrites = probeB.upsertCount
        await coordinator.savePrepared()
        let partial = try XCTUnwrap(coordinator.operation)
        try durableWrite(JSONEncoder().encode(partial), to: directory.appendingPathComponent("pending-operation.json"))
        let terminalConfirmed = try await probeB.waitForInjectedDisconnect()
        let observed: [String: Any] = ["statuses": partial.targets.map(\.status.rawValue),
            "messages": partial.targets.map { $0.message ?? "" },
            "upsertCounts": [probeA.upsertCount - aWrites, probeB.upsertCount - bWrites],
            "realACKCounts": [probeA.upsertACKs.count, probeB.upsertACKs.count],
            "terminalDisconnectConfirmed": terminalConfirmed]
        for rig in rigs { try rig.record("coordinatorPartialObserved", observed) }
        guard partial.targets.map(\.status) == [.confirmed, .pending], probeB.injectedDisconnectConfirmed,
              probeA.upsertCount == aWrites + 1, probeB.upsertCount == bWrites + 1,
              probeA.upsertACKs.count == 1, probeB.upsertACKs.count == 1 else {
            throw HardwareFailure("Expected A confirmed and B pending after an acknowledged commit and real disconnect; observed \(observed)")
        }
        try b.record("realDisconnectAfterCommit", ["stableID": stableIDs[1], "realACK": true, "terminalBLECallback": true])
        try await assertCoordinatorOutput(a, phase: "afterPartialSave")
        let restored = MultiBoardFaceSaveCoordinator(storage: storage)
        await restored.restore()
        guard restored.operation?.targets.map(\.status) == [.confirmed, .pending],
              restored.operation?.targets.map(\.payload.id) == stableIDs.map(Optional.some) else {
            throw HardwareFailure("Pending journal failed to preserve statuses and stable IDs")
        }
        try await connect(b)
        let rebound = try XCTUnwrap(FrozenFaceSaveDestination(name: b.id, connection: b.connection))
        guard rebound.physicalID == destinations[1].physicalID, rebound.carrier != destinations[1].carrier,
              restored.operation?.targets.map(\.status) == [.confirmed, .pending],
              probeB.upsertCount == bWrites + 1 else {
            throw HardwareFailure("Reconnect must preserve pending status until explicit retry")
        }
        try await assertCoordinatorOutput(b, phase: "afterReconnectBeforeExplicitRetry")
        let aReadsBeforeRetry = probeA.facesReadCount
        await restored.retry(using: [destinations[0], rebound])
        guard restored.allConfirmed, probeA.facesReadCount == aReadsBeforeRetry,
              probeA.upsertCount == aWrites + 1, probeB.upsertCount == bWrites + 1,
              restored.operation?.targets.map(\.payload.id) == stableIDs.map(Optional.some) else {
            throw HardwareFailure("Explicit retry must skip A and confirm B's committed UUID without another upsert")
        }
        let confirmed = try XCTUnwrap(restored.operation)
        for (rig, target) in zip(rigs, confirmed.targets) {
            try await verifyCoordinatorLibrary(rig, targets: [target], addedCount: 1)
            try await assertCoordinatorOutput(rig, phase: "afterExplicitRetry")
            try rig.record("coordinatorRetryConfirmed", ["stableID": target.payload.id ?? "", "upserts": 1,
                                                        "duplicate": false, "frameUnchanged": true])
        }
        await restored.finishIfConfirmed()
        // Edit the test-owned A record: overwrite only on its owner, create an
        // independent copy on B even though both boards received the first draft.
        let currentA = try XCTUnwrap(FrozenFaceSaveDestination(name: a.id, connection: a.connection))
        var edited = draft; edited.set(44)
        let own = MultiBoardFaceSaveSnapshot(frameHex: edited.hex94, type: "custom", originBoardID: currentA.id,
            editingFaceID: stableIDs[0], overwriteID: stableIDs[0],
            overwriteSource: BoardFaceSaveSource(boardID: currentA.id, generation: currentA.generation,
                expectedBootId: a.connection.bootId, expectedGen: a.connection.currentFacesGeneration),
            expectation: FaceExpectation(name: name, frameHex: draft.hex94))
        guard await restored.prepare(name: name + " edit", snapshot: own, destinations: [currentA, rebound]) else {
            throw HardwareFailure("Own overwrite prepare: \(restored.errorMessage ?? "unknown")")
        }
        let edit = try XCTUnwrap(restored.operation)
        guard edit.targets[0].payload.id == stableIDs[0], !edit.targets[0].createOnly,
              edit.targets[1].createOnly, !stableIDs.contains(edit.targets[1].payload.id ?? "") else {
            throw HardwareFailure("Own overwrite reused a foreign identity or failed to create B's independent copy")
        }
        try durableWrite(JSONEncoder().encode(edit), to: directory.appendingPathComponent("own-overwrite-prepared.json"))
        await restored.savePrepared()
        guard restored.allConfirmed, probeA.upsertCount == aWrites + 2, probeB.upsertCount == bWrites + 2 else {
            throw HardwareFailure("Own-board overwrite / remote-copy save was not confirmed on both boards")
        }
        let final = try XCTUnwrap(restored.operation)
        try await verifyCoordinatorLibrary(a, targets: [final.targets[0]], addedCount: 1)
        try await verifyCoordinatorLibrary(b, targets: [confirmed.targets[1], final.targets[1]], addedCount: 2)
        for rig in rigs {
            try await assertCoordinatorOutput(rig, phase: "afterOwnOverwriteAndRemoteCopy")
            try rig.record("coordinatorOwnOverwriteRemoteCopyConfirmed", ["frameUnchanged": true])
        }
        try durableWrite(JSONEncoder().encode(final), to: directory.appendingPathComponent("confirmed-operation.json"))
        await restored.finishIfConfirmed()
    }

    private func verifyCoordinatorLibrary(_ rig: Rig, targets: [MultiBoardFaceSaveCoordinator.Target], addedCount: Int) async throws {
        let raw = try await rig.connection.getFaces()
        let document = try FaceDocument(jsonData: raw)
        let original = try XCTUnwrap(rig.originalDocument)
        guard document.faces.count == original.faces.count + addedCount,
              Set(document.faces.map(\.id)).count == document.faces.count else {
            throw HardwareFailure("\(rig.id): coordinator duplicated or lost a saved-face record")
        }
        let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(rig.originalRaw)) as? [String: Any])
        let actualObject = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let originals = try XCTUnwrap(originalObject["faces"] as? [[String: Any]])
        let actual = try XCTUnwrap(actualObject["faces"] as? [[String: Any]])
        for record in originals {
            let found = try XCTUnwrap(actual.first { $0["id"] as? String == record["id"] as? String })
            guard NSDictionary(dictionary: found).isEqual(NSDictionary(dictionary: record)) else {
                throw HardwareFailure("\(rig.id): original record changed during coordinator saves")
            }
        }
        for target in targets {
            let face = try XCTUnwrap(document.faces.first { $0.id == target.payload.id })
            guard face.name == target.payload.name, face.type.rawValue == target.payload.type,
                  face.packedFrame?.hex94 == target.payload.frameHex, face.call == target.payload.call,
                  face.order == target.expectedOrder else {
                throw HardwareFailure("\(rig.id): stable-ID readback differs from the submitted coordinator payload")
            }
        }
    }

    private func assertCoordinatorOutput(_ rig: Rig, phase: String) async throws {
        try await assertOutputAndTelemetry(rig, phase: phase)
        let now = try await rig.connection.getStatus().renderer
        let before = try XCTUnwrap(rig.originalRenderer)
        guard let now, now.color == before.color, now.brightness == before.brightness,
              now.mode == before.mode, now.playback == before.playback, now.paused == before.paused,
              now.autoFaceIndex == before.autoFaceIndex, now.lit == before.lit,
              now.outputMode == before.outputMode, now.firmwareScrollActive == before.firmwareScrollActive else {
            throw HardwareFailure("\(rig.id): output settings/index changed during \(phase)")
        }
    }

    func testTwoBoardsMixed128FacesReadReconnectAndRestore() async throws {
        guard ProcessInfo.processInfo.environment["RINA_SAVE_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set RINA_SAVE_HARDWARE_TESTS=1 to exercise the two physical saved-face libraries")
        }
        try FileManager.default.createDirectory(at: Self.evidenceDirectory, withIntermediateDirectories: true)
        print("[MacSavedFacesHardwareTests] evidenceDirectory=\(Self.evidenceDirectory.path)")
        let rigs = boardIDs.map { Rig(id: $0) }
        defer {
            for rig in rigs {
                rig.connection.disconnect(userInitiated: true)
                rig.transport.stopScan()
            }
        }
        var testError: Error?
        do {
            for rig in rigs { try rig.record("started") }
            let discovered = try await discoverBoards(using: rigs[0].transport)
            for rig in rigs {
                rig.transport.peripheralIdentifier = discovered[rig.id]
                try await connect(rig)
                let raw = try await rig.connection.getFaces()
                let document = try FaceDocument(jsonData: raw)
                let rawObject = try JSONSerialization.jsonObject(with: raw)
                guard let rawFaces = (rawObject as? [String: Any])?["faces"] as? [[String: Any]],
                      rawFaces.count == document.faces.count,
                      document.faces.allSatisfy({ $0.packedFrame != nil }) else {
                    throw HardwareFailure("\(rig.id): original library contains skipped/invalid entries; refusing fixture import")
                }
                let frame = try await rig.connection.getFrame()
                let statusFrame = try await rig.connection.send(type: .getStatus, payload: Data())
                let status = try JSONDecoder().decode(DeviceStatus.self, from: statusFrame.payload)
                let statusObject = try JSONSerialization.jsonObject(with: statusFrame.payload)
                let backup: [String: Any] = [
                    "boardID": rig.id,
                    "capturedAt": ISO8601DateFormatter().string(from: Date()),
                    "facesBase64": raw.base64EncodedString(), // exact bytes, including unknown root/face metadata
                    "faces": rawObject,
                    "frameHex": frame.hex94,
                    "status": statusObject,
                    "bootId": rig.connection.bootId ?? "",
                    "gen": rig.connection.currentFacesGeneration ?? -1
                ]
                let backupURL = Self.evidenceDirectory.appendingPathComponent("hardware-\(rig.id)-before.json")
                // Keep a previous run's recovery evidence when re-running after a failure.
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    try FileManager.default.copyItem(at: backupURL,
                        to: Self.evidenceDirectory.appendingPathComponent("hardware-\(rig.id)-before-\(UUID().uuidString).json"))
                }
                try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys]).write(to: backupURL, options: .atomic)
                rig.originalRaw = raw
                rig.originalDocument = document
                rig.originalFrame = frame
                try rig.record("backupWritten", ["path": backupURL.path, "documentBytes": raw.count, "faces": document.faces.count])
                let mode = status.renderer?.mode?.lowercased() ?? ""
                let playback = status.renderer?.playback?.lowercased() ?? ""
                guard !mode.contains("auto"), !playback.contains("auto"), status.renderer?.firmwareScrollActive != true else {
                    throw XCTSkip("\(rig.id) has automatic/scroll playback active; leave its output untouched and run in manual mode")
                }
                guard rig.connection.supportsPartsReferences, rig.connection.supportsConditionalFaceWrites else {
                    throw XCTSkip("\(rig.id) requires faces_parts_v4 and faces_conditional_v1 firmware capabilities")
                }
                guard document.faces.filter({ $0.type == .default }).count <= 125 else {
                    throw XCTSkip("\(rig.id) has too many protected defaults to build both fixture formats and reserve the final upsert slot")
                }
                try await assertOutputAndTelemetry(rig, phase: "beforeImport")
            }
            guard rigs.allSatisfy({ $0.connection.connectionState == .connected }) else {
                throw HardwareFailure("Both production BLE links must remain connected before fixture writes")
            }
            let parts = try loadParts()
            for rig in rigs { try await exercise(rig, parts: parts) }
        } catch {
            testError = error
            for rig in rigs { try? rig.record("testStopped", ["error": String(describing: error)]) }
        }

        // Cancellation of a test must not cancel the only restoration attempt.
        let cleanup = Task.detached { @MainActor in
            var failures: [String] = []
            for rig in rigs {
                if rig.mayHaveWritten, let originalRaw = rig.originalRaw,
                   let original = rig.originalDocument {
                    do {
                        if rig.connection.connectionState != .connected { try await self.connect(rig) }
                        guard rig.connection.boardIdentity == rig.id else {
                            throw HardwareFailure("Restoration identity mismatch")
                        }
                        _ = try await rig.connection.getFaces() // fresh server-confirmed CAS cursor
                        let boot = try XCTUnwrap(rig.connection.bootId)
                        let gen = try XCTUnwrap(rig.connection.currentFacesGeneration)
                        _ = try await rig.connection.uploadBlob(kind: .faces,
                            meta: ["expectedBootId": boot, "expectedGen": gen], data: originalRaw)
                        let restored = try FaceDocument(jsonData: await rig.connection.getFaces())
                        try self.assertDocument(restored, equals: original, boardID: rig.id)
                        try await self.assertOutputAndTelemetry(rig, phase: "afterRestore")
                        try rig.record("originalLibraryRestored", ["faces": restored.faces.count, "frameUnchanged": true])
                    } catch {
                        failures.append("\(rig.id): original library restoration/verification failed: \(error). Keep hardware-\(rig.id)-before.json")
                        try? rig.record("restoreFailed", ["error": String(describing: error)])
                    }
                }
                do {
                    rig.connection.disconnect(userInitiated: true)
                    let confirmed = try await rig.transport.disconnectAndWait(timeout: 8)
                    if !confirmed { failures.append("\(rig.id): terminal BLE disconnect unconfirmed") }
                    try rig.record("terminalDisconnect", ["confirmed": confirmed])
                } catch {
                    rig.connection.disconnect(userInitiated: true)
                    failures.append("\(rig.id): disconnect failed: \(error)")
                }
            }
            return failures
        }
        let failures = await cleanup.value
        for failure in failures { XCTFail(failure) }
        if let testError { throw testError }
        guard failures.isEmpty else { throw HardwareFailure("Saved-face hardware cleanup failed") }
    }

    private func discoverBoards(using scanner: BLETransport) async throws -> [String: UUID] {
        let deadline = Date().addingTimeInterval(35)
        while !scanner.isScanning {
            try Task.checkCancellation()
            if CBManager.authorization == .denied || CBManager.authorization == .restricted {
                throw HardwareFailure("Bluetooth permission denied for the Mac test host")
            }
            scanner.startScan()
            guard Date() < deadline else { throw HardwareFailure("Bluetooth unavailable: \(scanner.lastError ?? "unknown")") }
            try await Task.sleep(for: .milliseconds(100))
        }
        var found: [String: UUID] = [:]
        while found.count < boardIDs.count {
            try Task.checkCancellation()
            for id in boardIDs {
                if let peripheral = scanner.discoveredPeripherals.first(where: { $0.advertisedName == "RinaBoard-\(id)" }) {
                    found[id] = peripheral.id
                }
            }
            guard Date() < deadline else { throw HardwareFailure("Missing exact board advertisements: \(boardIDs.filter { found[$0] == nil })") }
            if found.count < boardIDs.count { try await Task.sleep(for: .milliseconds(100)) }
        }
        scanner.stopScan()
        return found
    }

    private func connect(_ rig: Rig) async throws {
        let carrier: any RinaTransport = rig.observedTransport.map { $0 as any RinaTransport } ?? rig.transport
        guard await rig.connection.connect(using: carrier), rig.connection.boardIdentity == rig.id else {
            throw HardwareFailure("\(rig.id) BLE handshake/physical identity failed: \(rig.connection.lastError ?? "unknown")")
        }
        if rig.observedTransport != nil { rig.connection.stopAutomaticReconnect() }
    }

    private func loadParts() throws -> PartsLibrary {
        let bundle = Bundle(for: BoardConnection.self)
        let url = try XCTUnwrap(bundle.url(forResource: "expression_parts", withExtension: "json"), "Missing bundled expression catalog")
        return try PartsLibrary(jsonData: Data(contentsOf: url))
    }

    private func fixture(for rig: Rig, parts: PartsLibrary) throws -> FaceDocument {
        var document = try XCTUnwrap(rig.originalDocument)
        document.faces = document.faces.filter { $0.type == .default }
        var order = document.faces.map(\.order).max() ?? 0
        while document.faces.count < 127 {
            let index = document.faces.count
            order += 1
            if index.isMultiple(of: 2) {
                let call = partsCall(index, parts: parts)
                let frame = parts.compose(call: call)
                document.faces.append(SavedFace(id: "hw_save_v1_\(rig.id)_\(index)", name: "HW parts \(index)", type: .parts,
                    frameBytes: frame.bytes.map(Int.init), order: order,
                    call: .init(leye: call.leye, reye: call.reye, mouth: call.mouth, cheek: call.cheek),
                    partsCatalog: parts.format, partsVersion: parts.version))
            } else {
                var state = UInt64(index + 1) &* 0x9e3779b97f4a7c15
                var bytes = (0..<PackedFrame.byteCount).map { _ -> UInt8 in
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    return UInt8(truncatingIfNeeded: state)
                }
                bytes[PackedFrame.byteCount-1] &= 3
                document.faces.append(SavedFace(id: "hw_save_v1_\(rig.id)_\(index)", name: "HW bitmap \(index)", type: .custom,
                    frameBytes: bytes.map(Int.init), order: order))
            }
        }
        return document
    }

    private func partsCall(_ index: Int, parts: PartsLibrary) -> PartsCall {
        var call = PartsCall.defaultCall
        for (offset, group) in PartGroup.allCases.enumerated() {
            let ids = parts.ids(for: group)
            call[group] = ids[(index * 7 + offset * 3) % ids.count]
        }
        return call
    }

    private func exercise(_ rig: Rig, parts: PartsLibrary) async throws {
        var expected = try fixture(for: rig, parts: parts)
        let started = Date()
        rig.mayHaveWritten = true // ACK loss can occur after the flash commit.
        try await rig.connection.saveFaces(document: expected)
        let imported = try FaceDocument(jsonData: await rig.connection.getFaces())
        try assertDocument(imported, equals: expected, boardID: rig.id)
        try await assertOutputAndTelemetry(rig, phase: "after127Import")
        try rig.record("mixed127Imported", ["milliseconds": Date().timeIntervalSince(started) * 1000,
                                           "documentBytes": try expected.encoded().count, "frameUnchanged": true])
        let call = partsCall(128, parts: parts)
        let frame = parts.compose(call: call)
        let id = "hw_save_v1_\(rig.id)_parts128"
        var upsert = FaceUpsertPayload(id: id, name: "HW ID-only parts", type: "parts", frameHex: frame.hex94,
            call: .init(leye: call.leye, reye: call.reye, mouth: call.mouth, cheek: call.cheek))
        upsert.partsCatalog = parts.format; upsert.partsVersion = parts.version; upsert.partsReferenceOnly = true
        let reply = try await rig.connection.faceUpsert(upsert, createOnly: true,
            expectedBootId: rig.connection.bootId, expectedGen: rig.connection.currentFacesGeneration)
        guard reply.ok == true else { throw HardwareFailure("\(rig.id): ID-only create rejected") }
        expected.faces.append(SavedFace(id: id, name: upsert.name, type: .parts,
            frameBytes: frame.bytes.map(Int.init), order: (expected.faces.map(\.order).max() ?? 0) + 1,
            editable: true, deletable: true, locked: false, isStartupDefault: false, sourceFile: "saved_faces.json",
            call: upsert.call, partsCatalog: parts.format, partsVersion: parts.version))
        let maximumRaw = try await rig.connection.getFaces()
        try assertDocument(FaceDocument(jsonData: maximumRaw), equals: expected, boardID: rig.id)
        guard expected.faces.count == 128 else { throw HardwareFailure("Fixture did not reach 128 faces") }
        try rig.record("idOnly128Verified", ["stableID": id, "expandedBytes": maximumRaw.count])
        for iteration in 0..<3 {
            let readStarted = Date()
            let raw = try await rig.connection.getFaces()
            guard raw == maximumRaw else { throw HardwareFailure("\(rig.id): unchanged repeat read differs") }
            try rig.record("unchangedRead", ["iteration": iteration, "milliseconds": Date().timeIntervalSince(readStarted) * 1000])
        }
        async let first = rig.connection.getFaces()
        async let second = rig.connection.getFaces()
        async let third = rig.connection.getFaces()
        let concurrent = try await (first, second, third)
        guard concurrent.0 == maximumRaw, concurrent.1 == maximumRaw, concurrent.2 == maximumRaw else {
            throw HardwareFailure("\(rig.id): concurrent readers disagree")
        }
        try await assertOutputAndTelemetry(rig, phase: "afterConcurrentReads")
        try rig.record("concurrentReadsVerified", ["readers": 3, "frameUnchanged": true])
        rig.connection.disconnect(userInitiated: true)
        guard try await rig.transport.disconnectAndWait(timeout: 8) else { throw HardwareFailure("\(rig.id): disconnect before reconnect unconfirmed") }
        try await connect(rig)
        let reconnected = try FaceDocument(jsonData: await rig.connection.getFaces())
        try assertDocument(reconnected, equals: expected, boardID: rig.id)
        try await assertOutputAndTelemetry(rig, phase: "afterReconnect")
        try rig.record("reconnect128Verified", ["frameUnchanged": true, "faces": reconnected.faces.count])
    }

    private func assertDocument(_ actual: FaceDocument, equals expected: FaceDocument, boardID: String) throws {
        guard actual.format == expected.format, actual.version == expected.version, actual.matrix == expected.matrix,
              actual.category == expected.category, actual.startupDefaultId == expected.startupDefaultId,
              actual.faces.count == expected.faces.count else { throw HardwareFailure("\(boardID): library count/startup metadata mismatch") }
        let actualIDs = actual.faces.map(\.id)
        guard Set(actualIDs).count == actualIDs.count, Set(actualIDs) == Set(expected.faces.map(\.id)) else {
            throw HardwareFailure("\(boardID): exact saved-face ID set mismatch")
        }
        let byID = Dictionary(uniqueKeysWithValues: actual.faces.map { ($0.id, $0) })
        for wanted in expected.faces {
            guard let found = byID[wanted.id], found.name == wanted.name, found.type == wanted.type,
                  found.order == wanted.order, found.frameBytes == wanted.frameBytes,
                  found.call == wanted.call, found.editable == wanted.editable, found.deletable == wanted.deletable,
                  found.locked == wanted.locked, found.isStartupDefault == wanted.isStartupDefault,
                  found.sourceFile == wanted.sourceFile, found.savedAt == wanted.savedAt, found.updatedAt == wanted.updatedAt,
                  wanted.partsCatalog == nil || found.partsCatalog == wanted.partsCatalog,
                  wanted.partsVersion == nil || found.partsVersion == wanted.partsVersion else {
                throw HardwareFailure("\(boardID): semantic/pixel mismatch for \(wanted.id)")
            }
        }
    }

    private func assertOutputAndTelemetry(_ rig: Rig, phase: String) async throws {
        let actual = try await rig.connection.getFrame()
        guard actual == rig.originalFrame else { throw HardwareFailure("\(rig.id): displayed frame changed during \(phase)") }
        let response = try await rig.connection.send(type: .getStatus, payload: Data())
        guard let root = try JSONSerialization.jsonObject(with: response.payload) as? [String: Any] else {
            throw HardwareFailure("\(rig.id): invalid status during \(phase)")
        }
        let renderer = root["renderer"] as? [String: Any]
        if let failures = (renderer?["ledRefreshFail"] ?? root["ledRefreshFail"]) as? NSNumber {
            guard failures.intValue == 0 else { throw HardwareFailure("\(rig.id): ledRefreshFail=\(failures) during \(phase)") }
            try rig.record("outputVerified", ["phase": phase, "frameUnchanged": true, "ledRefreshFail": failures])
        } else {
            try rig.record("outputVerified", ["phase": phase, "frameUnchanged": true, "ledRefreshFail": "notReported"])
        }
    }

    private struct HardwareFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
