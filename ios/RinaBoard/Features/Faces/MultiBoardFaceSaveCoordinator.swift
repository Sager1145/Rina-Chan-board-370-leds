import Foundation
import RinaCore

/// A user's destination selection, frozen before naming. Reconnection never
/// silently changes a first submission's destination carrier.
@MainActor
struct FrozenFaceSaveDestination: Identifiable {
    let id: String
    let name: String
    let generation: UUID
    let carrier: UUID
    let physicalID: String?
    let connection: BoardConnection

    init?(name: String, connection: BoardConnection) {
        guard connection.connectionState == .connected, let key = connection.boardKey else { return nil }
        id = key
        self.name = name
        generation = connection.connectionGeneration
        carrier = connection.carrierGeneration
        physicalID = connection.boardIdentity?.uppercased()
        self.connection = connection
    }

    static func connected(in sessions: BoardSessionStore) -> [Self] {
        var seen = Set<String>()
        return sessions.sessions.compactMap { session in
            guard let target = Self(name: session.name, connection: session.connection),
                  seen.insert(target.id).inserted else { return nil }
            return target
        }
    }

    var isCurrent: Bool {
        connection.connectionState == .connected && connection.boardKey == id
            && connection.connectionGeneration == generation && connection.carrierGeneration == carrier
    }
}

struct MultiBoardFaceSaveSnapshot: Codable, Equatable {
    var frameHex: String
    var type: String
    var call: SavedFace.CallIds?
    var originBoardID: String?
    var editingFaceID: String?
    var overwriteID: String?
    var overwriteSource: BoardFaceSaveSource?
    var expectation: FaceExpectation?
}

@Observable
@MainActor
final class MultiBoardFaceSaveCoordinator {
    enum Status: String, Codable {
        case ready, saving, pending, failed, conflict, unavailable, confirmed
        var title: String {
            switch self {
            case .ready: return String(localized: "等待保存")
            case .saving: return String(localized: "正在保存并核对")
            case .pending: return String(localized: "结果待确认")
            case .failed: return String(localized: "保存失败")
            case .conflict: return String(localized: "内容冲突")
            case .unavailable: return String(localized: "连接已改变")
            case .confirmed: return String(localized: "已保存并核对")
            }
        }
    }
    struct Target: Codable, Identifiable {
        let id: String
        let name: String
        var physicalID: String?
        var generation: UUID
        var carrier: UUID
        var payload: FaceUpsertPayload
        var source: BoardFaceSaveSource
        let createOnly: Bool
        var expectedOrder: Int?
        var mayHaveWritten = false
        var status: Status
        var message: String?
    }
    struct Operation: Codable, Identifiable {
        let id: UUID
        let name: String
        let snapshot: MultiBoardFaceSaveSnapshot
        var targets: [Target]
    }

    private(set) var operation: Operation?
    private(set) var isRunning = false
    private(set) var resultsRevision = 0
    var errorMessage: String?
    var allConfirmed: Bool { operation?.targets.isEmpty == false && operation?.targets.allSatisfy { $0.status == .confirmed } == true }
    var hasUnconfirmed: Bool { operation?.targets.contains { $0.status != .confirmed } == true }
    /// The saved operation exists but cannot be decoded. Saves stay blocked
    /// until the user explicitly ends it.
    var hasUnreadableJournal: Bool { journalReadFailed }
    /// Anything that still gates new saves and needs the results sheet.
    var hasRetainedResult: Bool { operation != nil || journalReadFailed }
    private let storage: DraftStorage
    private var connections: [String: FrozenFaceSaveDestination] = [:]
    private var preparedIsRetry = false
    private var journalReadFailed = false

    init(storage: DraftStorage = .shared) { self.storage = storage }

    func restore() async {
        guard operation == nil else { return }
        journalReadFailed = false
        do {
            if let data = try await storage.read("multi_board_face_save") {
                operation = try JSONDecoder().decode(Operation.self, from: data)
                for index in operation!.targets.indices where operation!.targets[index].status == .saving {
                    operation!.targets[index].status = .pending
                }
            }
        } catch {
            journalReadFailed = true
            errorMessage = error.localizedDescription
        }
    }

    /// All IDs and the exact per-board representation are durable before any
    /// board request. Confirmed targets survive partial failure and relaunch.
    func prepare(name: String, snapshot: MultiBoardFaceSaveSnapshot,
                 destinations: [FrozenFaceSaveDestination]) async -> Bool {
        guard !isRunning else { return false }
        await restore()
        guard !journalReadFailed else { return false }
        do {
            let singlePending = try await ControlViewModel.hasPendingSave(in: storage)
            guard !singlePending else {
                errorMessage = String(localized: "请先连接原面板，核对上次单面板保存")
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 64, !destinations.isEmpty else {
            errorMessage = String(localized: "请选择面板，并输入不超过 64 个 UTF-8 字节的名称")
            return false
        }
        let selected = Dictionary(destinations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let previous = operation, previous.targets.allSatisfy({ $0.status == .confirmed }) {
            errorMessage = String(localized: "上次保存已完成，请先查看保存结果并点击完成")
            return false
        }
        if let previous = operation, previous.targets.contains(where: { $0.status != .confirmed }) {
            guard previous.name == clean, previous.snapshot == snapshot,
                  Set(previous.targets.map(\.id)) == Set(selected.keys) else {
                errorMessage = String(localized: "请先在“继续上次保存”中核对未完成的保存")
                return false
            }
            connections = selected
            preparedIsRetry = true
            return true
        }
        var targets: [Target] = []
        for destination in destinations where !targets.contains(where: { $0.id == destination.id }) {
            let overwrite = snapshot.overwriteSource?.boardID == destination.id ? snapshot.overwriteID : nil
            let source = overwrite != nil ? snapshot.overwriteSource! : BoardFaceSaveSource(
                boardID: destination.id, generation: destination.generation)
            let payload = FaceUpsertPayload(id: overwrite ?? "user_\(UUID().uuidString.lowercased())",
                                             name: clean, type: snapshot.type, frameHex: snapshot.frameHex,
                                             call: snapshot.call, expect: overwrite != nil ? snapshot.expectation : nil)
            let library = FaceLibraryModel()
            targets.append(Target(id: destination.id, name: destination.name, physicalID: destination.physicalID,
                                  generation: destination.generation, carrier: destination.carrier,
                                  payload: library.canonicalPayload(payload, supportsPartsReferences: destination.connection.supportsPartsReferences),
                                  source: source, createOnly: overwrite == nil, status: .ready))
        }
        operation = Operation(id: UUID(), name: clean, snapshot: snapshot, targets: targets)
        connections = selected
        preparedIsRetry = false
        return await persist()
    }

    func savePrepared() async { await run(retrying: preparedIsRetry, candidates: Array(connections.values)) }

    /// This explicit action may rebind an original physical destination after
    /// reconnect. A newly connected board is never added to the operation.
    func retry(using candidates: [FrozenFaceSaveDestination]) async {
        await run(retrying: true, candidates: candidates)
    }

    private func run(retrying: Bool, candidates: [FrozenFaceSaveDestination]) async {
        guard !isRunning, operation != nil else { return }
        isRunning = true
        defer { isRunning = false }
        let available = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in operation!.targets.indices {
            guard operation!.targets[index].status != .confirmed else { continue }
            var target = operation!.targets[index]
            guard let destination = available[target.id], destination.isCurrent,
                  (destination.generation == target.generation && destination.carrier == target.carrier)
                    || (retrying && target.physicalID != nil && target.physicalID == destination.physicalID) else {
                target.status = .unavailable
                target.message = String(localized: "原面板未连接；重新连接后可重试")
                update(target, at: index)
                _ = await persist()
                continue
            }
            let library = FaceLibraryModel()
            let hadPossibleWrite = target.mayHaveWritten
            target.status = .saving
            target.message = nil
            update(target, at: index)
            guard await persist() else { break }
            guard await library.reload(connection: destination.connection), destination.isCurrent else {
                target.status = hadPossibleWrite ? .pending : .unavailable
                target.message = library.errorMessage ?? String(localized: "读取面板失败")
                update(target, at: index)
                _ = await persist()
                continue
            }
            target.payload = library.canonicalPayload(target.payload, supportsPartsReferences: destination.connection.supportsPartsReferences)
            if retrying {
                if library.matchesSavedPayload(target.payload, expectedOrder: target.expectedOrder) {
                    target.status = .confirmed
                    target.generation = destination.generation
                    target.carrier = destination.carrier
                    update(target, at: index)
                    guard await persist() else { break }
                    continue
                }
                if target.createOnly, library.face(id: target.payload.id!, in: .board) != nil {
                    target.status = .conflict
                    target.message = String(localized: "相同 ID 的板上内容已改变，请检查该面板")
                    update(target, at: index)
                    _ = await persist()
                    continue
                }
                if target.createOnly && hadPossibleWrite && !destination.connection.supportsConditionalFaceWrites {
                    target.status = .pending
                    target.message = String(localized: "此固件无法安全重试，请升级后核对")
                    update(target, at: index)
                    _ = await persist()
                    continue
                }
            }
            if !target.createOnly {
                guard let stored = library.face(id: target.payload.id!, in: .board) else {
                    target.status = .conflict
                    target.message = String(localized: "原表情已不存在，请重新载入后另存")
                    update(target, at: index)
                    _ = await persist()
                    continue
                }
                if let expectation = target.payload.expect,
                   stored.name != expectation.name || stored.packedFrame?.hex94 != expectation.frameHex {
                    target.status = .conflict
                    target.message = String(localized: "原表情已在别处改变，请重新载入后保存")
                    update(target, at: index)
                    _ = await persist()
                    continue
                }
            }
            target.generation = destination.generation
            target.carrier = destination.carrier
            if target.createOnly {
                target.source = BoardFaceSaveSource(boardID: target.id, generation: destination.generation,
                                                    expectedBootId: destination.connection.bootId,
                                                    expectedGen: destination.connection.currentFacesGeneration)
                target.expectedOrder = (library.faceDocument.faces.map(\.order).max() ?? 0) + 1
            } else {
                target.expectedOrder = library.face(id: target.payload.id!, in: .board)?.order
            }
            // Persist the reconciled cursor and original stable ID before send.
            target.status = .pending
            target.mayHaveWritten = true
            update(target, at: index)
            guard await persist(), destination.isCurrent else { break }
            let result = await library.save(target.payload, source: target.source,
                                             createOnly: target.createOnly, connection: destination.connection)
            switch result {
            case .saved: target.status = .confirmed; target.message = nil
            case .pending: target.status = .pending; target.message = library.errorMessage
            case .failed: target.status = .failed; target.message = library.errorMessage
            }
            update(target, at: index)
            guard await persist() else { break }
        }
    }

    /// A completed result remains a save gate until explicit review/Finish.
    /// In particular a restart may occur before its editor ID was adopted.
    static func hasRetainedOperation(in storage: DraftStorage) async throws -> Bool {
        guard let data = try await storage.read("multi_board_face_save") else { return false }
        let operation = try JSONDecoder().decode(Operation.self, from: data)
        return !operation.targets.isEmpty
    }

    func finishIfConfirmed() async {
        guard allConfirmed, !isRunning else { return }
        do { try await storage.remove("multi_board_face_save"); operation = nil }
        catch { errorMessage = error.localizedDescription }
    }

    /// Explicitly ends the retained operation, confirmed or not, so unrelated
    /// saves can start again. Nothing is sent: confirmed targets keep their
    /// face, and a target that may already have been written is not rolled
    /// back. An unreadable journal is kept aside as evidence. `beforeEnding`
    /// (adopting the primary result) runs inside the same busy window, so a
    /// retry cannot start and rewrite the journal while this suspends.
    @discardableResult
    func endOperation(beforeEnding: () async -> Void = {}) async -> Bool {
        guard !isRunning, hasRetainedResult else { return false }
        isRunning = true
        defer { isRunning = false }
        await beforeEnding()
        do {
            if journalReadFailed, let data = try await storage.read("multi_board_face_save") {
                try await storage.write(data, name: "multi_board_face_save_unreadable")
            }
            try await storage.remove("multi_board_face_save")
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        operation = nil
        journalReadFailed = false
        connections = [:]
        preparedIsRetry = false
        errorMessage = nil
        resultsRevision &+= 1
        return true
    }

    private func update(_ target: Target, at index: Int) {
        operation!.targets[index] = target
        resultsRevision &+= 1
    }

    private func persist() async -> Bool {
        do {
            try await storage.write(JSONEncoder().encode(operation), name: "multi_board_face_save")
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
