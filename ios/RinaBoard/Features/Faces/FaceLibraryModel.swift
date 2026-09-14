import Foundation
import RinaCore

enum FaceLibraryLocation: String, CaseIterable, Codable, Hashable, Identifiable {
    case local
    case board

    var id: Self { self }
    var title: String {
        switch self {
        case .local: NSLocalizedString("本机", comment: "device face library location")
        case .board: NSLocalizedString("当前面板", comment: "connected board face library location")
        }
    }
}

struct FaceEditRequest: Identifiable, Equatable {
    let id: UInt64
    let face: SavedFace
    let location: FaceLibraryLocation
    let asCopy: Bool
    let boardID: String?
    let boardGeneration: UUID?
}

struct FaceBatchResult: Equatable {
    var succeededIDs: [String] = []
    var failures: [String: String] = [:]

    var succeededCount: Int { succeededIDs.count }
    var failedCount: Int { failures.count }
}

struct BoardFaceSaveSource: Equatable {
    let boardID: String?
    let generation: UUID?
}

private struct LocalDeletion {
    let faces: [SavedFace]
}

/// App-scoped state for the independent device library and the face document
/// belonging to the current board connection.
@Observable
@MainActor
final class FaceLibraryModel {
    /// Kept under its original name for existing Control and Control Center
    /// call sites. This document is always the current board's library.
    var faceDocument = FaceDocument()
    private(set) var localDocument = FaceDocument()
    /// Stable identity of the physical board that supplied `faceDocument`.
    /// Unlike `boardGeneration`, this survives a reconnect to the same board.
    private(set) var boardID: String?
    private(set) var boardGeneration: UUID?

    var isLoading = false
    var isSaving = false
    private(set) var isLocalLoading = false
    private(set) var isLocalLoaded = false
    var renamingFace: SavedFace?
    var renameText = ""
    var errorMessage: String?
    var operationMessage: String?
    var pendingEditRequest: FaceEditRequest?

    private let localStore: any LocalFaceStoring
    private var localDeletion: LocalDeletion?
    private var nextEditRequestID: UInt64 = 1
    private var localLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var boardLoadRevision: UInt64 = 0

    init(localStore: any LocalFaceStoring = LocalFaceStore()) {
        self.localStore = localStore
    }

    enum SaveOutcome: Equatable {
        case saved(id: String?)
        case failed
    }

    var defaultFaces: [SavedFace] { defaultFaces(in: .board) }
    var userFaces: [SavedFace] { userFaces(in: .board) }
    var canUndoLocalDelete: Bool { localDeletion != nil }

    func faces(in location: FaceLibraryLocation) -> [SavedFace] {
        document(in: location).sortedFaces
    }

    func defaultFaces(in location: FaceLibraryLocation) -> [SavedFace] {
        faces(in: location).filter { $0.type == .default }
    }

    func userFaces(in location: FaceLibraryLocation) -> [SavedFace] {
        faces(in: location).filter { $0.type != .default }
    }

    func face(id: String, in location: FaceLibraryLocation) -> SavedFace? {
        document(in: location).faces.first { $0.id == id }
    }

    func isProtected(_ face: SavedFace) -> Bool {
        face.type == .default || face.locked == true || face.editable == false
    }

    func canDelete(_ face: SavedFace) -> Bool {
        !isProtected(face) && face.deletable != false
    }

    // MARK: Loading and connection identity

    func loadLocalIfNeeded(bundle: Bundle = .main) async {
        guard !isLocalLoaded else { return }
        if isLocalLoading {
            await withCheckedContinuation { continuation in
                localLoadWaiters.append(continuation)
            }
            return
        }
        isLocalLoading = true
        defer {
            isLocalLoading = false
            let waiters = localLoadWaiters
            localLoadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        do {
            if var stored = try await localStore.load() {
                normalize(&stored, requireDefault: false)
                localDocument = mergedWithBundledDefaults(stored, bundle: bundle)
            } else {
                localDocument = bundledDefaults(bundle: bundle)
                try await localStore.save(localDocument)
            }
            isLocalLoaded = true
        } catch {
            localDocument = bundledDefaults(bundle: bundle)
            isLocalLoaded = true
            errorMessage = String(
                format: NSLocalizedString("无法读取本机表情库：%@", comment: "local face library load failed"),
                error.localizedDescription
            )
        }
    }

    /// Invalidates session-owned board data. `boardID` deliberately survives:
    /// it identifies the physical source of an editor save target across a
    /// reconnect, while `boardGeneration` gates replies from the retired link.
    func synchronizeBoardGeneration(_ generation: UUID) {
        guard boardGeneration != generation else { return }
        boardLoadRevision &+= 1
        isLoading = false
        faceDocument = FaceDocument()
        boardGeneration = nil
    }

    @discardableResult
    func reload(connection: BoardConnection, bundle: Bundle = .main) async -> Bool {
        _ = bundle // Source-compatible with older callers and test bundles.
        errorMessage = nil
        guard connection.connectionState == .connected else {
            synchronizeBoardGeneration(connection.connectionGeneration)
            return false
        }
        let generation = connection.connectionGeneration
        let currentBoardID = connection.boardKey
        boardLoadRevision &+= 1
        let revision = boardLoadRevision
        if boardGeneration != generation || boardID != currentBoardID {
            faceDocument = FaceDocument()
        }
        isLoading = true
        defer {
            if revision == boardLoadRevision { isLoading = false }
        }
        do {
            let data = try await connection.getFaces()
            guard generation == connection.connectionGeneration,
                  revision == boardLoadRevision else { return false }
            faceDocument = try FaceDocument(jsonData: data)
            boardID = currentBoardID
            boardGeneration = generation
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == connection.connectionGeneration,
                  revision == boardLoadRevision else { return false }
            errorMessage = String(
                format: NSLocalizedString("读取面板表情失败：%@", comment: "board face library load failed"),
                error.localizedDescription
            )
            return false
        }
    }

    // MARK: Editor handoff

    func requestEdit(_ face: SavedFace,
                     location: FaceLibraryLocation,
                     asCopy: Bool = false,
                     connectionGeneration: UUID? = nil) {
        let requestID = nextEditRequestID
        nextEditRequestID &+= 1
        pendingEditRequest = FaceEditRequest(
            id: requestID,
            face: face,
            location: location,
            asCopy: asCopy || isProtected(face),
            boardID: location == .board ? boardID : nil,
            boardGeneration: location == .board ? connectionGeneration : nil
        )
    }

    func consumePendingEditRequest(id: UInt64) {
        guard pendingEditRequest?.id == id else { return }
        pendingEditRequest = nil
    }

    // MARK: Apply

    func apply(_ face: SavedFace, connection: BoardConnection) async {
        await apply(face, from: .board, connection: connection)
    }

    func apply(_ face: SavedFace, from location: FaceLibraryLocation, connection: BoardConnection) async {
        errorMessage = nil
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法应用表情", comment: "cannot apply face while disconnected")
            return
        }
        do {
            switch location {
            case .local:
                guard let frame = face.packedFrame else {
                    errorMessage = NSLocalizedString("此表情的帧数据无效", comment: "saved face frame invalid")
                    return
                }
                let session = connection.output.begin(.manual)
                _ = try await connection.withOutput(session) {
                    try await connection.setFrame(frame, playback: .idle,
                                                  reason: "local_saved_face",
                                                  outputSession: session)
                }
            case .board:
                guard boardGeneration == connection.connectionGeneration else {
                    await reload(connection: connection)
                    errorMessage = NSLocalizedString("面板已更换，请重新选择表情", comment: "saved face belongs to another board")
                    return
                }
                guard let index = faceDocument.sortedFaces.firstIndex(where: { $0.id == face.id }) else { return }
                let session = connection.output.begin(.manual)
                _ = try await connection.withOutput(session) {
                    try await connection.applySavedFace(index: index)
                }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = String(
                format: NSLocalizedString("应用失败：%@", comment: "apply saved face failed"),
                error.localizedDescription
            )
        }
    }

    // MARK: Save / update

    @discardableResult
    func save(_ payload: FaceUpsertPayload, source: BoardFaceSaveSource? = nil,
              connection: BoardConnection) async -> SaveOutcome {
        errorMessage = nil
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法保存到面板", comment: "cannot save face to disconnected board")
            return .failed
        }
        if payload.id != nil {
            let targetMatches = source.map {
                Self.sameBoard(sourceBoardID: $0.boardID,
                               sourceGeneration: $0.generation,
                               currentBoardID: connection.boardKey,
                               currentGeneration: connection.connectionGeneration)
            } ?? boardDocumentBelongs(to: connection)
            guard targetMatches else {
                errorMessage = NSLocalizedString("面板已更换，请重新选择表情", comment: "saved face belongs to another board")
                return .failed
            }
        }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await connection.faceUpsert(payload)
            let savedFrame = PackedFrame(hex94: payload.frameHex)
            if let id = payload.id, connection.lastFaceOpGenMatchedExpectation,
               let frame = savedFrame,
               let index = faceDocument.faces.firstIndex(where: { $0.id == id }) {
                faceDocument.faces[index].name = payload.name
                faceDocument.faces[index].type = SavedFace.Kind(rawValue: payload.type) ?? .custom
                faceDocument.faces[index].frameBytes = frame.bytes.map(Int.init)
                faceDocument.faces[index].updatedAt = timestamp()
                faceDocument.faces[index].call = payload.call
                boardID = connection.boardKey
                boardGeneration = connection.connectionGeneration
                return .saved(id: id)
            }
            await reload(connection: connection)
            if payload.id == nil, let frame = savedFrame {
                let bytes = frame.bytes.map(Int.init)
                let matched = faceDocument.faces.last { $0.name == payload.name && $0.frameBytes == bytes }
                return .saved(id: matched?.id)
            }
            return .saved(id: payload.id)
        } catch {
            await handleFaceOpError(error, connection: connection)
            return .failed
        }
    }

    @discardableResult
    func saveLocal(_ payload: FaceUpsertPayload, replacingID: String? = nil) async -> SaveOutcome {
        errorMessage = nil
        guard let frame = PackedFrame(hex94: payload.frameHex) else {
            errorMessage = NSLocalizedString("帧数据无效，无法保存到本机", comment: "cannot save invalid face locally")
            return .failed
        }
        await loadLocalIfNeeded()
        let existingIndex = replacingID.flatMap { id in
            localDocument.faces.firstIndex { $0.id == id && !isProtected($0) }
        }
        let now = timestamp()
        let id = existingIndex.map { localDocument.faces[$0].id } ?? makeLocalID()
        let order = existingIndex.map { localDocument.faces[$0].order }
            ?? ((localDocument.faces.map(\.order).max() ?? 0) + 1)
        let saved = SavedFace(
            id: id,
            name: cleanName(payload.name),
            type: SavedFace.Kind(rawValue: payload.type) ?? .custom,
            frameBytes: frame.bytes.map(Int.init),
            order: order,
            editable: true,
            deletable: true,
            locked: false,
            savedAt: existingIndex.map { localDocument.faces[$0].savedAt } ?? now,
            updatedAt: now,
            call: payload.call
        )
        var candidate = localDocument
        if let existingIndex { candidate.faces[existingIndex] = saved } else { candidate.faces.append(saved) }
        guard await commitLocal(candidate) else { return .failed }
        return .saved(id: id)
    }

    func upsertPayload(editingFaceId: String?, name: String, frame: PackedFrame,
                       fromParts: Bool, call: PartsCall) -> FaceUpsertPayload {
        upsertPayload(editingFaceId: editingFaceId, location: .board,
                      name: name, frame: frame, fromParts: fromParts, call: call)
    }

    func upsertPayload(editingFaceId: String?, location: FaceLibraryLocation,
                       name: String, frame: PackedFrame, fromParts: Bool,
                       call: PartsCall) -> FaceUpsertPayload {
        let existing = editingFaceId.flatMap { face(id: $0, in: location) }
        let overwriteID = (existing != nil && !isProtected(existing!)) ? existing?.id : nil
        let clean = cleanName(name)
        return FaceUpsertPayload(
            id: location == .board ? overwriteID : nil,
            name: overwriteID == nil && editingFaceId != nil ? "\(clean)_copy" : clean,
            type: (fromParts ? SavedFace.Kind.parts : .custom).rawValue,
            frameHex: frame.hex94,
            call: fromParts
                ? SavedFace.CallIds(leye: call.leye, reye: call.reye, mouth: call.mouth, cheek: call.cheek)
                : nil
        )
    }

    func boardUpsertPayload(editingFaceId: String?, canOverwrite: Bool,
                            name: String, frame: PackedFrame,
                            fromParts: Bool, call: PartsCall) -> FaceUpsertPayload {
        let clean = cleanName(name)
        let overwriteID = canOverwrite ? editingFaceId : nil
        let payload = FaceUpsertPayload(
            id: overwriteID,
            name: overwriteID == nil && editingFaceId != nil ? "\(clean)_copy" : clean,
            type: (fromParts ? SavedFace.Kind.parts : .custom).rawValue,
            frameHex: frame.hex94,
            call: fromParts
                ? SavedFace.CallIds(leye: call.leye, reye: call.reye, mouth: call.mouth, cheek: call.cheek)
                : nil
        )
        return payload
    }

    // MARK: Rename / duplicate / copy

    func rename(_ face: SavedFace, to newName: String, connection: BoardConnection) async {
        await rename(face, to: newName, in: .board, connection: connection)
    }

    @discardableResult
    func rename(_ face: SavedFace, to newName: String, in location: FaceLibraryLocation,
                connection: BoardConnection) async -> Bool {
        errorMessage = nil
        guard !isProtected(face) else {
            errorMessage = NSLocalizedString("默认或锁定表情不可重命名，可先创建副本", comment: "protected face rename denied")
            return false
        }
        let clean = cleanName(newName)
        switch location {
        case .local:
            await loadLocalIfNeeded()
            var candidate = localDocument
            guard let index = candidate.faces.firstIndex(where: { $0.id == face.id }) else { return false }
            candidate.faces[index].name = clean
            candidate.faces[index].updatedAt = timestamp()
            return await commitLocal(candidate)
        case .board:
            guard await validateBoard(connection) else { return false }
            do {
                _ = try await connection.faceRename(id: face.id, name: clean)
                if connection.lastFaceOpGenMatchedExpectation,
                   let index = faceDocument.faces.firstIndex(where: { $0.id == face.id }) {
                    faceDocument.faces[index].name = clean
                    faceDocument.faces[index].updatedAt = timestamp()
                } else {
                    await reload(connection: connection)
                }
                return true
            } catch {
                await handleFaceOpError(error, connection: connection)
                return false
            }
        }
    }

    @discardableResult
    func duplicate(_ face: SavedFace, from location: FaceLibraryLocation,
                   connection: BoardConnection) async -> SaveOutcome {
        await copy(face, from: location, to: location, connection: connection)
    }

    @discardableResult
    func copy(_ face: SavedFace, from source: FaceLibraryLocation, to destination: FaceLibraryLocation,
              connection: BoardConnection) async -> SaveOutcome {
        if destination == .local { await loadLocalIfNeeded() }
        guard let frame = face.packedFrame else {
            errorMessage = NSLocalizedString("此表情的帧数据无效", comment: "saved face frame invalid")
            return .failed
        }
        let payload = FaceUpsertPayload(
            name: copyName(for: face.name, in: destination),
            type: (face.type == .parts ? SavedFace.Kind.parts : .custom).rawValue,
            frameHex: frame.hex94,
            call: face.type == .parts ? face.call : nil
        )
        switch destination {
        case .local: return await saveLocal(payload)
        case .board: return await save(payload, connection: connection)
        }
    }

    func copy(_ faces: [SavedFace], from source: FaceLibraryLocation, to destination: FaceLibraryLocation,
              connection: BoardConnection) async -> FaceBatchResult {
        var result = FaceBatchResult()
        for face in faces {
            switch await copy(face, from: source, to: destination, connection: connection) {
            case .saved: result.succeededIDs.append(face.id)
            case .failed:
                result.failures[face.id] = errorMessage
                    ?? NSLocalizedString("复制失败", comment: "saved face copy failed")
            }
        }
        report(result, action: .copy)
        return result
    }

    // MARK: Delete and undo

    func delete(_ face: SavedFace, connection: BoardConnection) async {
        _ = await delete(face, from: .board, connection: connection)
    }

    @discardableResult
    func delete(_ face: SavedFace, from location: FaceLibraryLocation,
                connection: BoardConnection) async -> Bool {
        errorMessage = nil
        guard canDelete(face) else {
            errorMessage = NSLocalizedString("默认或锁定表情不可删除", comment: "protected face deletion denied")
            return false
        }
        switch location {
        case .local:
            return await deleteLocal([face]).failedCount == 0
        case .board:
            guard await validateBoard(connection) else { return false }
            do {
                _ = try await connection.faceDelete(id: face.id)
                if connection.lastFaceOpGenMatchedExpectation {
                    faceDocument.faces.removeAll { $0.id == face.id }
                } else {
                    await reload(connection: connection)
                }
                return true
            } catch {
                await handleFaceOpError(error, connection: connection)
                return false
            }
        }
    }

    func delete(_ faces: [SavedFace], from location: FaceLibraryLocation,
                connection: BoardConnection) async -> FaceBatchResult {
        if location == .local { return await deleteLocal(faces) }
        var result = FaceBatchResult()
        for face in faces {
            if await delete(face, from: .board, connection: connection) {
                result.succeededIDs.append(face.id)
            } else {
                result.failures[face.id] = errorMessage
                    ?? NSLocalizedString("删除失败", comment: "saved face deletion failed")
            }
        }
        report(result, action: .delete)
        return result
    }

    @discardableResult
    func undoLocalDelete() async -> Bool {
        guard let deletion = localDeletion else { return false }
        var candidate = localDocument
        for face in deletion.faces where !candidate.faces.contains(where: { $0.id == face.id }) {
            candidate.faces.append(face)
        }
        normalize(&candidate, requireDefault: false)
        guard await commitLocal(candidate) else { return false }
        localDeletion = nil
        operationMessage = String(
            format: NSLocalizedString("已恢复 %lld 个本机表情", comment: "local face deletion undo count"),
            Int64(deletion.faces.count)
        )
        return true
    }

    private func deleteLocal(_ faces: [SavedFace]) async -> FaceBatchResult {
        await loadLocalIfNeeded()
        let deletable = faces.filter(canDelete)
        var result = FaceBatchResult()
        for face in faces where !deletable.contains(where: { $0.id == face.id }) {
            result.failures[face.id] = NSLocalizedString("默认或锁定表情不可删除", comment: "protected face deletion denied")
        }
        guard !deletable.isEmpty else {
            report(result, action: .delete)
            return result
        }
        var candidate = localDocument
        let ids = Set(deletable.map(\.id))
        candidate.faces.removeAll { ids.contains($0.id) }
        if await commitLocal(candidate) {
            result.succeededIDs = deletable.map(\.id)
            localDeletion = LocalDeletion(faces: deletable)
        } else {
            for face in deletable {
                result.failures[face.id] = errorMessage
                    ?? NSLocalizedString("删除失败", comment: "saved face deletion failed")
            }
        }
        report(result, action: .delete)
        return result
    }

    // MARK: Reorder

    @discardableResult
    func reorderUserFaces(_ newUserOrder: [SavedFace], connection: BoardConnection) async -> Bool {
        await reorderUserFaces(newUserOrder, in: .board, connection: connection)
    }

    @discardableResult
    func reorderUserFaces(_ newUserOrder: [SavedFace], in location: FaceLibraryLocation,
                          connection: BoardConnection) async -> Bool {
        errorMessage = nil
        if location == .local { await loadLocalIfNeeded() }
        let confirmedIDs = Set(userFaces(in: location).map(\.id))
        guard Set(newUserOrder.map(\.id)) == confirmedIDs,
              newUserOrder.count == confirmedIDs.count else {
            errorMessage = NSLocalizedString("排序列表已发生变化，请取消后重试", comment: "face reorder draft is stale")
            return false
        }
        switch location {
        case .local:
            var candidate = localDocument
            assignOrders(defaults: defaultFaces(in: .local), users: newUserOrder, in: &candidate)
            return await commitLocal(candidate)
        case .board:
            guard await validateBoard(connection) else { return false }
            let ids = (defaultFaces + newUserOrder).map(\.id)
            do {
                _ = try await connection.faceReorder(ids: ids)
                if connection.lastFaceOpGenMatchedExpectation {
                    assignOrders(defaults: defaultFaces, users: newUserOrder, in: &faceDocument)
                } else {
                    return await reload(connection: connection)
                }
                return true
            } catch {
                await handleFaceOpError(error, connection: connection)
                return false
            }
        }
    }

    /// Reorders the whole board library, presets included — `face_reorder`
    /// accepts any permutation of every face on the board.
    @discardableResult
    func reorderFaces(_ newOrder: [SavedFace], connection: BoardConnection) async -> Bool {
        errorMessage = nil
        let confirmedIDs = Set(faceDocument.faces.map(\.id))
        guard Set(newOrder.map(\.id)) == confirmedIDs,
              newOrder.count == confirmedIDs.count else {
            errorMessage = NSLocalizedString("排序列表已发生变化，请取消后重试", comment: "face reorder draft is stale")
            return false
        }
        guard await validateBoard(connection) else { return false }
        do {
            _ = try await connection.faceReorder(ids: newOrder.map(\.id))
            if connection.lastFaceOpGenMatchedExpectation {
                assignOrders(defaults: [], users: newOrder, in: &faceDocument)
            } else {
                return await reload(connection: connection)
            }
            return true
        } catch {
            await handleFaceOpError(error, connection: connection)
            return false
        }
    }

    // MARK: Import / export

    func exportData() -> Data? { try? faceDocument.encoded() }

    func exportData(faces: [SavedFace], from location: FaceLibraryLocation) -> Data? {
        var selected = FaceDocument(format: document(in: location).format,
                                    version: document(in: location).version,
                                    matrix: document(in: location).matrix,
                                    faces: faces)
        normalize(&selected, requireDefault: false)
        return try? selected.encoded()
    }

    func importDocument(from data: Data, connection: BoardConnection) async {
        await importDocument(from: data, to: .board, connection: connection)
    }

    func importDocument(from data: Data, to location: FaceLibraryLocation,
                        connection: BoardConnection) async {
        errorMessage = nil
        guard var decoded = try? FaceDocument(jsonData: data),
              !decoded.faces.isEmpty,
              decoded.faces.allSatisfy({ $0.packedFrame != nil }) else {
            errorMessage = NSLocalizedString("导入失败：文件格式无效", comment: "face document import invalid")
            return
        }
        normalize(&decoded, requireDefault: location == .board)
        switch location {
        case .local:
            await loadLocalIfNeeded()
            var candidate = localDocument
            for source in decoded.faces {
                guard let frame = source.packedFrame else { continue }
                candidate.faces.append(localCopy(of: source, frame: frame,
                                                 order: (candidate.faces.map(\.order).max() ?? 0) + 1))
            }
            _ = await commitLocal(candidate)
        case .board:
            guard connection.connectionState == .connected else {
                errorMessage = NSLocalizedString("未连接，无法同步到面板", comment: "cannot sync faces while disconnected")
                return
            }
            do {
                try await connection.saveFaces(document: decoded)
                await reload(connection: connection)
            } catch {
                errorMessage = String(
                    format: NSLocalizedString("同步失败：%@", comment: "face library sync failed"),
                    error.localizedDescription
                )
            }
        }
    }

    // MARK: Helpers

    /// A physical identity takes precedence over a link session. When either
    /// side lacks that identity, only the exact session is safe: an unknown
    /// board after reconnect must not inherit an old face id.
    nonisolated static func sameBoard(sourceBoardID: String?, sourceGeneration: UUID?,
                                      currentBoardID: String?, currentGeneration: UUID) -> Bool {
        if sourceBoardID != nil || currentBoardID != nil {
            return sourceBoardID != nil && sourceBoardID == currentBoardID
        }
        return sourceGeneration != nil && sourceGeneration == currentGeneration
    }

    private func boardDocumentBelongs(to connection: BoardConnection) -> Bool {
        Self.sameBoard(sourceBoardID: boardID,
                       sourceGeneration: boardGeneration,
                       currentBoardID: connection.boardKey,
                       currentGeneration: connection.connectionGeneration)
    }

    private func document(in location: FaceLibraryLocation) -> FaceDocument {
        location == .local ? localDocument : faceDocument
    }

    private func bundledDefaults(bundle: Bundle) -> FaceDocument {
        var document = (try? RinaResources.defaultFaces(bundle: bundle)) ?? FaceDocument()
        for index in document.faces.indices where document.faces[index].type == .default {
            document.faces[index].editable = false
            document.faces[index].deletable = false
            document.faces[index].locked = true
        }
        normalize(&document, requireDefault: false)
        return document
    }

    private func mergedWithBundledDefaults(_ stored: FaceDocument, bundle: Bundle) -> FaceDocument {
        let defaults = bundledDefaults(bundle: bundle).faces.filter { $0.type == .default }
        let users = stored.sortedFaces.filter { $0.type != .default }
        var result = FaceDocument(format: stored.format, version: stored.version,
                                  matrix: stored.matrix, faces: defaults + users)
        normalize(&result, requireDefault: false)
        return result
    }

    private func normalize(_ document: inout FaceDocument, requireDefault: Bool) {
        var seen = Set<String>()
        for index in document.faces.indices {
            if document.faces[index].id.isEmpty || seen.contains(document.faces[index].id) {
                document.faces[index].id = makeLocalID()
            }
            seen.insert(document.faces[index].id)
        }
        let sorted = document.sortedFaces
        for (rank, face) in sorted.enumerated() {
            if let index = document.faces.firstIndex(where: { $0.id == face.id }) {
                document.faces[index].order = rank + 1
            }
        }
        if requireDefault, !document.faces.contains(where: { $0.type == .default }),
           let first = document.faces.indices.first {
            document.faces[first].type = .default
            document.faces[first].editable = false
            document.faces[first].deletable = false
            document.faces[first].locked = true
        }
    }

    private func assignOrders(defaults: [SavedFace], users: [SavedFace], in document: inout FaceDocument) {
        for (rank, id) in (defaults + users).map(\.id).enumerated() {
            if let index = document.faces.firstIndex(where: { $0.id == id }) {
                document.faces[index].order = rank + 1
            }
        }
    }

    private func commitLocal(_ candidate: FaceDocument) async -> Bool {
        do {
            try await localStore.save(candidate)
            localDocument = candidate
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(
                format: NSLocalizedString("无法保存本机表情库：%@", comment: "local face library save failed"),
                error.localizedDescription
            )
            return false
        }
    }

    private func validateBoard(_ connection: BoardConnection) async -> Bool {
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法同步到面板", comment: "cannot sync faces while disconnected")
            return false
        }
        guard boardGeneration == connection.connectionGeneration else {
            await reload(connection: connection)
            errorMessage = NSLocalizedString("面板已更换，请重新选择表情", comment: "saved face belongs to another board")
            return false
        }
        return true
    }

    private func handleFaceOpError(_ error: Error, connection: BoardConnection) async {
        if let linkError = error as? RinaLinkError, let code = linkError.code,
           [400, 404, 409].contains(code) {
            errorMessage = linkError.error
            await reload(connection: connection)
        } else {
            errorMessage = String(
                format: NSLocalizedString("同步失败：%@", comment: "face library sync failed"),
                error.localizedDescription
            )
        }
    }

    private func localCopy(of face: SavedFace, frame: PackedFrame, order: Int) -> SavedFace {
        let now = timestamp()
        return SavedFace(id: makeLocalID(), name: face.name,
                         type: face.type == .parts ? .parts : .custom,
                         frameBytes: frame.bytes.map(Int.init), order: order,
                         editable: true, deletable: true, locked: false,
                         savedAt: now, updatedAt: now,
                         call: face.type == .parts ? face.call : nil)
    }

    private func copyName(for name: String, in destination: FaceLibraryLocation) -> String {
        let names = Set(faces(in: destination).map { $0.name.localizedLowercase })
        let base = String(
            format: NSLocalizedString("%@ 副本", comment: "saved face copy name"),
            cleanName(name)
        )
        guard names.contains(base.localizedLowercase) else { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)".localizedLowercase) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func cleanName(_ name: String) -> String {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        return value.isEmpty ? "face" : value
    }

    private func makeLocalID() -> String { "local_\(UUID().uuidString.lowercased())" }
    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    private enum BatchAction { case copy, delete }

    private func report(_ result: FaceBatchResult, action: BatchAction) {
        let succeeded = Int64(result.succeededCount)
        let failed = Int64(result.failedCount)
        switch (action, result.failedCount == 0) {
        case (.copy, true):
            operationMessage = String(format: NSLocalizedString("已复制 %lld 个表情", comment: "face batch copy succeeded"), succeeded)
        case (.copy, false):
            operationMessage = String(format: NSLocalizedString("已复制 %lld 个，%lld 个失败", comment: "face batch copy partial result"), succeeded, failed)
        case (.delete, true):
            operationMessage = String(format: NSLocalizedString("已删除 %lld 个表情", comment: "face batch delete succeeded"), succeeded)
        case (.delete, false):
            operationMessage = String(format: NSLocalizedString("已删除 %lld 个，%lld 个失败", comment: "face batch delete partial result"), succeeded, failed)
        }
        if result.failedCount > 0 {
            errorMessage = result.failures.values.sorted().joined(separator: "\n")
        }
    }
}
