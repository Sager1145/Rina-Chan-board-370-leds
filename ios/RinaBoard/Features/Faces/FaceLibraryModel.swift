import Foundation
import CryptoKit
import RinaCore

enum FaceLibraryLocation: String, CaseIterable, Codable, Hashable, Identifiable {
    case local
    case board

    var id: Self { self }
    var title: String {
        switch self {
        case .local: NSLocalizedString("本机", comment: "device face library location")
        case .board: NSLocalizedString("板上表情", comment: "connected board face library location")
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
    var expectedBootId: String? = nil
    var expectedGen: Int? = nil
}

struct FaceBatchResult: Equatable {
    var succeededIDs: [String] = []
    var failures: [String: String] = [:]

    var succeededCount: Int { succeededIDs.count }
    var failedCount: Int { failures.count }
}

struct BoardFaceSaveSource: Equatable, Codable {
    let boardID: String?
    let generation: UUID?
    var expectedBootId: String? = nil
    var expectedGen: Int? = nil
}

private struct LocalDeletion {
    let faces: [SavedFace]
}

/// The current board's confirmed library, with isolated legacy-store helpers
/// retained for explicit migration and compatibility. Drafts live separately.
@Observable
@MainActor
final class FaceLibraryModel {
    /// Kept under its original name for existing Control and Control Center
    /// call sites. This document is always the current board's library.
    var faceDocument = FaceDocument() {
        didSet { cachedBoardSortedFaces = faceDocument.sortedFaces }
    }
    private(set) var localDocument = FaceDocument() {
        didSet { cachedLocalSortedFaces = localDocument.sortedFaces }
    }
    /// `faceDocument.sortedFaces` / `localDocument.sortedFaces`, recomputed
    /// once per document mutation (via the `didSet`s above) instead of on
    /// every `faces(in:)`/`defaultFaces`/`userFaces` access.
    private var cachedBoardSortedFaces: [SavedFace] = []
    private var cachedLocalSortedFaces: [SavedFace] = []
    /// Stable identity of the physical board that supplied `faceDocument`.
    /// Unlike `boardGeneration`, this survives a reconnect to the same board.
    private(set) var boardID: String?
    private(set) var boardGeneration: UUID?
    private(set) var boardBootId: String?
    private(set) var boardFacesGen: Int?
    /// Only an explicitly confirmed rename in this app may advance an editor baseline.
    private var confirmedRenames: [String: (before: FaceExpectation, after: FaceExpectation, bootId: String?, gen: Int?)] = [:]
    private var boardSaveBusy = false

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
    /// Link the latest `boardLoadRevision` bump was made for. A refresh of the
    /// same board bumps the revision too, so a board op that raced one uses
    /// this to tell "still my board, re-read it" from "the model moved on".
    private var boardLoadTargetGeneration: UUID?

    // Every local read-modify-write must acquire this FIFO gate BEFORE
    // reading `localDocument`, not merely serialize their final disk write:
    // otherwise two operations can both snapshot `localDocument`, then race
    // each other's `await localStore.save`, and the loser's write silently
    // discards the winner's change.
    private var localMutationBusy = false
    private var localMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(localStore: any LocalFaceStoring = LocalFaceStore()) {
        self.localStore = localStore
    }

    private func beginLocalMutation() async {
        if localMutationBusy {
            await withCheckedContinuation { localMutationWaiters.append($0) }
        } else {
            localMutationBusy = true
        }
    }

    private func endLocalMutation() {
        if localMutationWaiters.isEmpty {
            localMutationBusy = false
        } else {
            localMutationWaiters.removeFirst().resume()
        }
    }

    enum SaveOutcome: Equatable {
        case saved(id: String?)
        case pending(id: String)
        case failed
    }

    var defaultFaces: [SavedFace] { defaultFaces(in: .board) }
    var userFaces: [SavedFace] { userFaces(in: .board) }
    var canUndoLocalDelete: Bool { localDeletion != nil }

    func faces(in location: FaceLibraryLocation) -> [SavedFace] {
        location == .local ? cachedLocalSortedFaces : cachedBoardSortedFaces
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

    /// Localized display name for a built-in preset face (`PresetNames.xcstrings`,
    /// keyed `"face." + id`), or the face's own stored name unchanged if `face`
    /// isn't a built-in default or the user has renamed it — a user-created or
    /// user-renamed name is never translated. Applies equally to the board's
    /// library and the local one: both share the same built-in ids (the
    /// firmware's `saved_faces.json` uses the same `face_NN_...` ids).
    func displayName(for face: SavedFace, bundle: Bundle = .main) -> String {
        guard let original = bundledDefaults(bundle: bundle).faces.first(where: { $0.id == face.id })?.name,
              original == face.name else {
            return face.name
        }
        return bundle.localizedString(forKey: "face." + face.id, value: face.name, table: "PresetNames")
    }

    func canDelete(_ face: SavedFace) -> Bool {
        !isProtected(face) && face.deletable != false
    }

    /// Board-group control fan-out helper (`GroupControlFanOut`): resolves a
    /// group control primary's `apply_saved_face`/B1/B2 reply to the actual
    /// frame it applied, purely from this model's already-cached board face
    /// list — never a network round trip (face libraries aren't synced
    /// across group members, so a sink must receive the resolved bitmap, not
    /// the primary's face id/index). Returns nil (falls back to replaying
    /// the command verbatim) unless `generation` still matches the cache
    /// this model loaded for the primary (`boardGeneration`), since a stale
    /// cache could resolve to the wrong board's face. Prefers `id`
    /// (`CommandReply.autoFaceId`) over `index` (`autoFaceIndex`) since ids
    /// are stable across reorders.
    func boardFaceFrame(id: String?, index: Int?, generation: UUID) -> PackedFrame? {
        guard boardGeneration == generation else { return nil }
        if let id, let face = cachedBoardSortedFaces.first(where: { $0.id == id }) {
            return face.packedFrame
        }
        if let index, cachedBoardSortedFaces.indices.contains(index) {
            return cachedBoardSortedFaces[index].packedFrame
        }
        return nil
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
        // Set before the gate (not after) so a second concurrent first-caller
        // that arrives while this call is suspended on `beginLocalMutation()`
        // sees `isLocalLoading` already true and becomes a waiter instead of
        // redundantly loading too.
        isLocalLoading = true
        // Every caller reaches this first load either directly or through
        // `loadLocalForMutation()`, which always completes (and releases
        // this gate) before its caller acquires it again for the mutation
        // itself — so acquiring it here cannot deadlock against any
        // `beginLocalMutation()` site in this file.
        await beginLocalMutation()
        defer {
            isLocalLoading = false
            endLocalMutation()
            let waiters = localLoadWaiters
            localLoadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        do {
            if var stored = try await localStore.load() {
                normalize(&stored, requireDefault: false)
                let candidate = mergedWithBundledDefaults(stored, bundle: bundle)
                localDocument = candidate
            } else {
                let candidate = bundledDefaults(bundle: bundle)
                localDocument = candidate
            }
            isLocalLoaded = true
        } catch let LocalFaceStoreError.partiallyUnreadable(document, skippedCount) {
            var partial = document
            normalize(&partial, requireDefault: false)
            localDocument = mergedWithBundledDefaults(partial, bundle: bundle)
            // The partial parse is safe to display, but it is not a complete
            // read of the file. Keep persistence blocked so a later edit
            // cannot overwrite the still-recoverable local_faces.json with a
            // library that is missing whatever failed to parse. Also drop any
            // pending undo record: `undoLocalDelete()` would otherwise be
            // able to write over this damaged file once the load-gate below
            // clears, restoring faces on top of a document that was never
            // fully read.
            isLocalLoaded = false
            localDeletion = nil
            errorMessage = String(
                format: NSLocalizedString(
                    "本机表情库有 %lld 个表情无法解析，为保护原文件已禁止保存",
                    comment: "local face library partially unreadable, saving disabled"
                ),
                Int64(skippedCount)
            )
        } catch {
            localDocument = bundledDefaults(bundle: bundle)
            // Defaults are safe to display, but they are not a successfully
            // loaded backing document. Keep persistence blocked so a later
            // edit cannot overwrite an unreadable (and potentially
            // recoverable) local_faces.json with this fallback library.
            isLocalLoaded = false
            errorMessage = String(
                format: NSLocalizedString("无法读取本机表情库：%@", comment: "local face library load failed"),
                error.localizedDescription
            )
        }
    }

    /// Forces a fresh read of the local library from disk — used by the
    /// saved-list sheet's pull-to-refresh / 「刷新」 action on the local
    /// library. Deliberately does not route through `loadLocalIfNeeded`: a
    /// failed re-read must never replace a previously loaded
    /// `localDocument` with bundled defaults (that fallback only applies to
    /// the very first load, when nothing was loaded before). On most failures
    /// the in-memory document and `isLocalLoaded` are left exactly as they
    /// were, and only `errorMessage` reports the failure — except when the
    /// file on disk is now known to be partially unreadable (some entries
    /// failed to parse): that case does flip `isLocalLoaded` back to false
    /// and replaces `localDocument` with the partial result, since the prior
    /// in-memory document can no longer be trusted as a faithful copy of a
    /// file now known to be damaged.
    func reloadLocal(bundle: Bundle = .main) async {
        await beginLocalMutation()
        defer { endLocalMutation() }
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
                let candidate = mergedWithBundledDefaults(stored, bundle: bundle)
                localDocument = candidate
            } else {
                let candidate = bundledDefaults(bundle: bundle)
                localDocument = candidate
            }
            isLocalLoaded = true
            errorMessage = nil
        } catch let LocalFaceStoreError.partiallyUnreadable(document, skippedCount) {
            var partial = document
            normalize(&partial, requireDefault: false)
            localDocument = mergedWithBundledDefaults(partial, bundle: bundle)
            // Unlike other reload failures, this one *does* flip a previously
            // loaded library back to unloaded: the file on disk is now known
            // to be damaged (some entries didn't parse), so treating the
            // prior in-memory document as still trustworthy would let a later
            // edit persist over that damaged file without ever having read
            // it fully. Show what parsed and block saves until it's fixed.
            // Also drop any pending undo record: `undoLocalDelete()` would
            // otherwise be able to write over this damaged file once the
            // load-gate below clears, restoring faces on top of a document
            // that was never fully read.
            isLocalLoaded = false
            localDeletion = nil
            errorMessage = String(
                format: NSLocalizedString(
                    "本机表情库有 %lld 个表情无法解析，为保护原文件已禁止保存",
                    comment: "local face library partially unreadable, saving disabled"
                ),
                Int64(skippedCount)
            )
        } catch {
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
        boardLoadTargetGeneration = generation
        isLoading = false
        faceDocument = FaceDocument()
        boardGeneration = nil
        confirmedRenames.removeAll()
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
        boardLoadTargetGeneration = generation
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
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["category"] as? String == FaceDocument.expectedCategory,
                  envelope["faces"] is [[String: Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let parsed = try FaceDocument.decodedForImport(jsonData: data)
            guard parsed.skippedFaceCount == 0,
                  parsed.document.faces.allSatisfy({ $0.packedFrame != nil }),
                  Set(parsed.document.faces.map(\.id)).count == parsed.document.faces.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            faceDocument = parsed.document
            boardID = currentBoardID
            boardGeneration = generation
            boardBootId = connection.bootId
            boardFacesGen = connection.currentFacesGeneration
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
            boardGeneration: location == .board ? connectionGeneration : nil,
            expectedBootId: location == .board ? boardBootId : nil,
            expectedGen: location == .board ? boardFacesGen : nil
        )
    }

    func consumePendingEditRequest(id: UInt64) {
        guard pendingEditRequest?.id == id else { return }
        pendingEditRequest = nil
    }

    // MARK: Apply

    @discardableResult
    func apply(_ face: SavedFace, from location: FaceLibraryLocation, connection: BoardConnection) async -> Bool {
        errorMessage = nil
        operationMessage = nil
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法应用表情", comment: "cannot apply face while disconnected")
            return false
        }
        do {
            switch location {
            case .local:
                guard let frame = face.packedFrame else {
                    errorMessage = NSLocalizedString("此表情的帧数据无效", comment: "saved face frame invalid")
                    return false
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
                    return false
                }
                guard let index = cachedBoardSortedFaces.firstIndex(where: { $0.id == face.id }) else {
                    errorMessage = NSLocalizedString("表情已不存在，请刷新列表", comment: "saved face no longer exists")
                    return false
                }
                let session = connection.output.begin(.manual)
                _ = try await connection.withOutput(session) {
                    try await connection.applySavedFace(index: index, id: face.id)
                }
            }
            operationMessage = NSLocalizedString("已发送表情", comment: "saved face applied successfully")
            return true
        } catch is CancellationError {
            return false
        } catch {
            // A 404 here means the id/index this apply targeted is already
            // gone from the board's list (another client deleted or
            // reordered it): reload the stale list and surface the board's
            // own message, same as every other face op's stale-state error.
            if let linkError = error as? RinaLinkError, linkError.code == 404 {
                await handleFaceOpError(error, connection: connection)
                return false
            }
            errorMessage = String(
                format: NSLocalizedString("应用失败：%@", comment: "apply saved face failed"),
                error.localizedDescription
            )
            return false
        }
    }

    // MARK: Save / update

    private struct PendingCreate: Codable {
        var payload: FaceUpsertPayload
        var source: BoardFaceSaveSource
    }
    private let pendingCreateStorage = DraftStorage.shared

    /// Direct list operations (duplicate/copy) use the same durable identity
    /// rule as the editor. A repeated explicit action first reconciles its
    /// prior snapshot instead of issuing another unidentified creation.
    @discardableResult
    func save(_ payload: FaceUpsertPayload, source: BoardFaceSaveSource? = nil,
              createOnly: Bool = false, connection: BoardConnection) async -> SaveOutcome {
        guard !boardSaveBusy else {
            errorMessage = NSLocalizedString("正在保存，请稍候", comment: "face write already active")
            return .failed
        }
        boardSaveBusy = true
        defer { boardSaveBusy = false }
        guard payload.id == nil else {
            return await saveBoardPayload(payload, source: source, createOnly: createOnly, connection: connection)
        }
        guard connection.connectionState == .connected else { return .failed }
        if connection.supportsConditionalFaceWrites && connection.currentFacesGeneration == nil {
            guard await reload(connection: connection) else { return .failed }
        }
        let target = source ?? BoardFaceSaveSource(boardID: connection.boardKey,
                                                   generation: connection.connectionGeneration,
                                                   expectedBootId: connection.bootId,
                                                   expectedGen: connection.currentFacesGeneration)
        do {
            let data = try await pendingCreateStorage.read("board_face_creates")
            var pending = try data.map { try JSONDecoder().decode([PendingCreate].self, from: $0) } ?? []
            // A pending create that this board's loaded list already shows is
            // confirmed. Retire it here: once its copy is visible the next copy
            // gets another name, so it would never be matched again.
            if boardDocumentBelongs(to: connection) {
                let count = pending.count
                pending.removeAll {
                    Self.sameBoard(sourceBoardID: $0.source.boardID, sourceGeneration: $0.source.generation,
                                   currentBoardID: connection.boardKey, currentGeneration: connection.connectionGeneration)
                        && matchesSavedPayload($0.payload)
                }
                if pending.count != count {
                    try await pendingCreateStorage.write(JSONEncoder().encode(pending), name: "board_face_creates")
                }
            }
            let existing = pending.firstIndex {
                Self.sameBoard(sourceBoardID: $0.source.boardID, sourceGeneration: $0.source.generation,
                               currentBoardID: connection.boardKey, currentGeneration: connection.connectionGeneration)
                    && $0.payload.name == cleanName(payload.name) && $0.payload.frameHex == payload.frameHex
                    && $0.payload.type == payload.type && Self.callsEqual($0.payload.call, payload.call)
            }
            var operation: PendingCreate
            if let existing {
                operation = pending[existing]
                guard operation.payload.id != nil else { throw CocoaError(.fileReadCorruptFile) }
                guard await reload(connection: connection) else { return .pending(id: operation.payload.id!) }
                if matchesSavedPayload(operation.payload) {
                    pending.remove(at: existing)
                    try await pendingCreateStorage.write(JSONEncoder().encode(pending), name: "board_face_creates")
                    return .saved(id: operation.payload.id)
                }
                guard face(id: operation.payload.id!, in: .board) == nil,
                      connection.supportsConditionalFaceWrites else {
                    errorMessage = NSLocalizedString("结果待确认或目标已改变：请检查板上表情", comment: "direct create needs reconciliation")
                    return .pending(id: operation.payload.id!)
                }
                operation.source = BoardFaceSaveSource(boardID: connection.boardKey,
                                                       generation: connection.connectionGeneration,
                                                       expectedBootId: connection.bootId,
                                                       expectedGen: connection.currentFacesGeneration)
                pending[existing] = operation
            } else {
                var submitted = payload
                submitted.id = "user_" + UUID().uuidString.lowercased()
                submitted.name = cleanName(submitted.name)
                operation = PendingCreate(payload: submitted, source: target)
                pending.append(operation)
            }
            try await pendingCreateStorage.write(JSONEncoder().encode(pending), name: "board_face_creates")
            let result = await saveBoardPayload(operation.payload, source: operation.source,
                                                createOnly: true, connection: connection)
            if case .saved = result {
                pending.removeAll { $0.payload.id == operation.payload.id }
                try await pendingCreateStorage.write(JSONEncoder().encode(pending), name: "board_face_creates")
            }
            return result
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    @discardableResult
    private func saveBoardPayload(_ payload: FaceUpsertPayload, source: BoardFaceSaveSource? = nil,
              createOnly: Bool = false, connection: BoardConnection) async -> SaveOutcome {
        errorMessage = nil
        var payload = payload
        // Enforce the firmware's byte limit at the final wire boundary too;
        // callers normally arrive through the name builders below, but this
        // method is also used directly by copy/import-adjacent flows.
        payload.name = cleanName(payload.name)
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
        if payload.id == nil { payload.id = "user_" + UUID().uuidString.lowercased() }
        guard let targetID = payload.id else { return .failed }
        let order = faceDocument.faces.first(where: { $0.id == targetID })?.order
            ?? (createOnly && boardGeneration == connection.connectionGeneration
                ? (faceDocument.faces.map(\.order).max() ?? 0) + 1 : nil)
        isSaving = true
        defer { isSaving = false }
        let generation = connection.connectionGeneration
        let revision = boardLoadRevision
        do {
            let reply = try await connection.faceUpsert(payload, createOnly: createOnly,
                                                        expectedBootId: source?.expectedBootId,
                                                        expectedGen: source?.expectedGen)
            guard connection.connectionGeneration == generation,
                  boardStillShown(connection, since: revision) else { return .pending(id: targetID) }
            if let gen = continuesShownLibrary(reply, connection, since: revision),
               let stored = reply.face, stored.id == targetID, stored.packedFrame != nil {
                var document = faceDocument
                if let index = document.faces.firstIndex(where: { $0.id == targetID }) {
                    document.faces[index] = stored
                } else {
                    document.faces.append(stored)
                }
                faceDocument = document
                boardFacesGen = gen
            } else {
                guard await reload(connection: connection) else {
                    errorMessage = NSLocalizedString("结果待确认：请连接原面板后再次保存以核对", comment: "face save needs readback")
                    return .pending(id: targetID)
                }
            }
            guard matchesSavedPayload(payload, expectedOrder: order) else {
                errorMessage = NSLocalizedString("保存核对失败：板上内容与提交不同，请重新载入或另存", comment: "face save readback conflict")
                return .pending(id: targetID)
            }
            return .saved(id: targetID)
        } catch {
            guard generation == connection.connectionGeneration,
                  boardStillShown(connection, since: revision) else { return .pending(id: targetID) }
            if let linkError = error as? RinaLinkError,
               let code = linkError.code, [400, 404, 409].contains(code) {
                await handleFaceOpError(error, connection: connection)
                if matchesSavedPayload(payload, expectedOrder: order) {
                    errorMessage = nil
                    return .saved(id: targetID)
                }
                return .failed
            }
            errorMessage = NSLocalizedString("结果待确认：请连接原面板后再次保存以核对", comment: "face save needs readback")
            return .pending(id: targetID)
        }
    }

    /// Readback checks what the user saved: name, pixels and position. Type
    /// and parts metadata are the board's storage choice (a parts face whose
    /// pixels no longer match its call is stored as custom).
    func matchesSavedPayload(_ payload: FaceUpsertPayload, expectedOrder: Int? = nil) -> Bool {
        guard let face = faceDocument.faces.first(where: { $0.id == payload.id }) else { return false }
        return face.name == payload.name
            && face.packedFrame?.hex94 == payload.frameHex
            && (expectedOrder == nil || face.order == expectedOrder)
    }

    func confirmedRenameBaseline(id: String, from baseline: FaceExpectation) -> FaceExpectation? {
        guard let rename = confirmedRenames[id], rename.before == baseline,
              rename.bootId == boardBootId, rename.gen == boardFacesGen,
              let current = face(id: id, in: .board),
              current.name == rename.after.name, current.packedFrame?.hex94 == rename.after.frameHex else { return nil }
        return rename.after
    }

    /// Treats `nil` and an all-empty `CallIds` as equal: `face_upsert`
    /// payloads for a non-parts face carry `call: nil`, but a round trip
    /// through the board's stored document can come back as an explicit
    /// empty object instead.
    private static func callsEqual(_ a: SavedFace.CallIds?, _ b: SavedFace.CallIds?) -> Bool {
        func isEmpty(_ c: SavedFace.CallIds?) -> Bool {
            guard let c else { return true }
            return c.leye == nil && c.reye == nil && c.mouth == nil && c.cheek == nil
        }
        if isEmpty(a) && isEmpty(b) { return true }
        return a == b
    }

    @discardableResult
    func saveLocal(_ payload: FaceUpsertPayload, replacingID: String? = nil) async -> SaveOutcome {
        errorMessage = nil
        guard let frame = PackedFrame(hex94: payload.frameHex) else {
            errorMessage = NSLocalizedString("帧数据无效，无法保存到本机", comment: "cannot save invalid face locally")
            return .failed
        }
        guard await loadLocalForMutation() else { return .failed }
        await beginLocalMutation()
        defer { endLocalMutation() }
        // An overwrite target that no longer exists in the local library
        // (deleted, or from a different library entirely) must fail loudly
        // instead of silently falling through to a brand-new face.
        if let replacingID, !localDocument.faces.contains(where: { $0.id == replacingID }) {
            errorMessage = NSLocalizedString("原表情已不存在，请另存为新表情", comment: "local overwrite target no longer exists")
            return .failed
        }
        if let replacingID, let expect = payload.expect,
           let current = localDocument.faces.first(where: { $0.id == replacingID }) {
            let currentFrameHex = current.packedFrame?.hex94
            if current.name != expect.name || currentFrameHex != expect.frameHex {
                errorMessage = NSLocalizedString(
                    "此表情已在别处被修改：请另存为新表情，或重新载入该表情后再改",
                    comment: "local overwrite target changed since it was loaded"
                )
                return .failed
            }
        }
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

    func boardUpsertPayload(editingFaceId: String?, canOverwrite: Bool,
                            name: String, frame: PackedFrame,
                            fromParts: Bool, call: PartsCall,
                            expect: FaceExpectation? = nil) -> FaceUpsertPayload {
        let overwriteID = canOverwrite ? editingFaceId : nil
        let isCopy = overwriteID == nil && editingFaceId != nil
        let payload = FaceUpsertPayload(
            id: overwriteID,
            name: isCopy ? fittedName(name, suffix: "_copy") : cleanName(name),
            type: (fromParts ? SavedFace.Kind.parts : .custom).rawValue,
            frameHex: frame.hex94,
            call: fromParts
                ? SavedFace.CallIds(leye: call.leye, reye: call.reye, mouth: call.mouth, cheek: call.cheek)
                : nil,
            expect: overwriteID != nil ? expect : nil
        )
        return payload
    }

    // MARK: Rename / duplicate / copy

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
            guard await loadLocalForMutation() else { return false }
            await beginLocalMutation()
            defer { endLocalMutation() }
            var candidate = localDocument
            guard let index = candidate.faces.firstIndex(where: { $0.id == face.id }) else { return false }
            candidate.faces[index].name = clean
            candidate.faces[index].updatedAt = timestamp()
            return await commitLocal(candidate)
        case .board:
            guard await validateBoard(connection) else { return false }
            guard let current = self.face(id: face.id, in: .board),
                  current.name == face.name, current.packedFrame == face.packedFrame else {
                errorMessage = NSLocalizedString("此表情已在别处被修改：请重新载入后再操作", comment: "stale face action")
                return false
            }
            // Captured after `validateBoard`'s own possible reload (R07): the
            // signal for "did the board change under us" is a bump that
            // happens strictly after this point.
            let revision = boardLoadRevision
            do {
                let reply = try await connection.faceRename(id: face.id, name: clean)
                guard boardStillShown(connection, since: revision) else { return true }
                if let gen = continuesShownLibrary(reply, connection, since: revision),
                   let index = faceDocument.faces.firstIndex(where: { $0.id == face.id }) {
                    faceDocument.faces[index].name = clean
                    faceDocument.faces[index].updatedAt = timestamp()
                    boardFacesGen = gen
                } else {
                    await reload(connection: connection)
                }
                guard let confirmed = faceDocument.faces.first(where: { $0.id == face.id }),
                      confirmed.name == clean, confirmed.packedFrame == face.packedFrame,
                      let frame = face.packedFrame else { return false }
                confirmedRenames[face.id] = (FaceExpectation(name: face.name, frameHex: frame.hex94),
                                             FaceExpectation(name: clean, frameHex: frame.hex94),
                                             boardBootId, boardFacesGen)
                return true
            } catch {
                guard boardStillShown(connection, since: revision) else { return false }
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
            name: copyName(for: displayName(for: face), in: destination),
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
            case .pending, .failed:
                result.failures[face.id] = errorMessage
                    ?? NSLocalizedString("复制失败", comment: "saved face copy failed")
            }
        }
        report(result, action: .copy)
        return result
    }

    // MARK: Delete and undo

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
            guard let current = self.face(id: face.id, in: .board),
                  current.name == face.name, current.packedFrame == face.packedFrame else {
                errorMessage = NSLocalizedString("此表情已在别处被修改：请重新载入后再操作", comment: "stale face action")
                return false
            }
            let revision = boardLoadRevision
            do {
                let reply = try await connection.faceDelete(id: face.id)
                guard boardStillShown(connection, since: revision) else { return true }
                if let gen = continuesShownLibrary(reply, connection, since: revision) {
                    faceDocument.faces.removeAll { $0.id == face.id }
                    boardFacesGen = gen
                } else {
                    await reload(connection: connection)
                }
                return true
            } catch {
                guard boardStillShown(connection, since: revision) else { return false }
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
        // Does not call `loadLocalForMutation()` first, unlike every other
        // local mutation: `localDeletion` can only be non-nil after a gated
        // `deleteLocal` already required a successful load, but a later
        // `reloadLocal` (e.g. pull-to-refresh) can hit a partially unreadable
        // file and flip `isLocalLoaded` back to false while leaving
        // `localDeletion` set. The explicit gate below covers that case:
        // without it, this would happily write the restored faces (plus
        // whatever partial document that reload produced) over a
        // local_faces.json that was never fully read, destroying the entries
        // that failed to parse.
        await beginLocalMutation()
        defer { endLocalMutation() }
        guard isLocalLoaded else {
            errorMessage = errorMessage
                ?? NSLocalizedString("无法读取本机表情库", comment: "local face library unavailable")
            return false
        }
        // Read the current undo record only after acquiring the same gate as
        // deletion. A queued delete may replace the record while this undo is
        // waiting, and consuming a snapshot captured before the gate would
        // restore the wrong faces and clear the newer record.
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
        guard await loadLocalForMutation() else {
            var result = FaceBatchResult()
            let message = errorMessage
                ?? NSLocalizedString("无法读取本机表情库", comment: "local face library unavailable")
            for face in faces { result.failures[face.id] = message }
            report(result, action: .delete)
            return result
        }
        await beginLocalMutation()
        defer { endLocalMutation() }
        let requestedIDs = Set(faces.map(\.id))
        // Use the authoritative objects in the document at transaction time.
        // The caller's snapshots may have been renamed, protected, or replaced
        // while this operation waited for the mutation gate.
        let deletable = localDocument.faces.filter { requestedIDs.contains($0.id) && canDelete($0) }
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
    func reorderUserFaces(_ newUserOrder: [SavedFace], in location: FaceLibraryLocation,
                          connection: BoardConnection) async -> Bool {
        errorMessage = nil
        switch location {
        case .local:
            guard await loadLocalForMutation() else { return false }
            await beginLocalMutation()
            defer { endLocalMutation() }
            let confirmedIDs = Set(userFaces(in: .local).map(\.id))
            guard Set(newUserOrder.map(\.id)) == confirmedIDs,
                  newUserOrder.count == confirmedIDs.count else {
                errorMessage = NSLocalizedString("排序列表已发生变化，请取消后重试", comment: "face reorder draft is stale")
                return false
            }
            var candidate = localDocument
            assignOrders(defaults: defaultFaces(in: .local), users: newUserOrder, in: &candidate)
            return await commitLocal(candidate)
        case .board:
            let confirmedIDs = Set(userFaces(in: .board).map(\.id))
            guard Set(newUserOrder.map(\.id)) == confirmedIDs,
                  newUserOrder.count == confirmedIDs.count else {
                errorMessage = NSLocalizedString("排序列表已发生变化，请取消后重试", comment: "face reorder draft is stale")
                return false
            }
            guard await validateBoard(connection) else { return false }
            let ids = (defaultFaces + newUserOrder).map(\.id)
            let revision = boardLoadRevision
            do {
                let reply = try await connection.faceReorder(ids: ids)
                guard boardStillShown(connection, since: revision) else { return true }
                if let gen = continuesShownLibrary(reply, connection, since: revision) {
                    assignOrders(defaults: defaultFaces, users: newUserOrder, in: &faceDocument)
                    boardFacesGen = gen
                } else {
                    return await reload(connection: connection)
                }
                return true
            } catch {
                guard boardStillShown(connection, since: revision) else { return false }
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
        let revision = boardLoadRevision
        do {
            let reply = try await connection.faceReorder(ids: newOrder.map(\.id))
            guard boardStillShown(connection, since: revision) else { return true }
            if let gen = continuesShownLibrary(reply, connection, since: revision) {
                assignOrders(defaults: [], users: newOrder, in: &faceDocument)
                boardFacesGen = gen
            } else {
                return await reload(connection: connection)
            }
            return true
        } catch {
            guard boardStillShown(connection, since: revision) else { return false }
            await handleFaceOpError(error, connection: connection)
            return false
        }
    }

    /// Whole-library ordering for either store: presets and user faces may
    /// interleave freely, and `newOrder` must be a full permutation of every
    /// id currently in `location` — ids never change.
    @discardableResult
    func reorderFaces(_ newOrder: [SavedFace], in location: FaceLibraryLocation,
                      connection: BoardConnection) async -> Bool {
        if location == .board {
            return await reorderFaces(newOrder, connection: connection)
        }
        errorMessage = nil
        guard await loadLocalForMutation() else { return false }
        await beginLocalMutation()
        defer { endLocalMutation() }
        let confirmed = localDocument.faces.map(\.id)
        let proposed = newOrder.map(\.id)
        guard proposed.count == confirmed.count,
              Set(proposed).count == proposed.count,
              Set(proposed) == Set(confirmed) else {
            errorMessage = NSLocalizedString("排序列表已发生变化，请取消后重试", comment: "face reorder draft is stale")
            return false
        }
        var candidate = localDocument
        // Modify only order. Do not write stale names/frames from the draft.
        assignOrders(defaults: [], users: newOrder, in: &candidate)
        return await commitLocal(candidate)
    }

    // MARK: Import / export

    func exportData(faces: [SavedFace], from location: FaceLibraryLocation) -> Data? {
        var selected = FaceDocument(format: document(in: location).format,
                                    version: document(in: location).version,
                                    matrix: document(in: location).matrix,
                                    faces: faces,
                                    category: document(in: location).category,
                                    startupDefaultId: document(in: location).startupDefaultId)
        // `normalize` nils `startupDefaultId` back out if `faces` didn't
        // include that face.
        normalize(&selected, requireDefault: false)
        return try? selected.encoded()
    }

    /// The file picker could not read the chosen file at all; previously this
    /// returned silently and looked like nothing had happened.
    func reportImportUnreadable() {
        errorMessage = NSLocalizedString("导入失败：无法读取所选文件",
                                         comment: "face document import unreadable file")
    }

    func importDocument(from data: Data, to location: FaceLibraryLocation,
                        connection: BoardConnection) async {
        errorMessage = nil
        // The lenient decoder drops entries it cannot parse. That is right when
        // reading data we already own, but an import is uploaded as a whole
        // document replacement, so a partial parse would silently discard the
        // user's faces. Refuse instead, and say how many entries were bad.
        guard let parsed = try? FaceDocument.decodedForImport(jsonData: data) else {
            errorMessage = NSLocalizedString("导入失败：文件格式无效", comment: "face document import invalid")
            return
        }
        if parsed.skippedFaceCount > 0 {
            errorMessage = String(
                format: NSLocalizedString("导入失败：文件中有 %d 个表情无法解析，未做任何改动",
                                          comment: "face document import skipped entries"),
                parsed.skippedFaceCount
            )
            return
        }
        var decoded = parsed.document
        // A missing `category` already defaults to `expectedCategory` on
        // decode; only a present-but-different value (or a whole-document
        // shape the firmware doesn't recognize as a face library) is refused —
        // the firmware's `validateSavedFaces` rejects any upload otherwise.
        guard decoded.category == FaceDocument.expectedCategory,
              !decoded.faces.isEmpty,
              decoded.faces.allSatisfy({ $0.packedFrame != nil }) else {
            errorMessage = NSLocalizedString("导入失败：文件格式无效", comment: "face document import invalid")
            return
        }
        normalize(&decoded, requireDefault: location == .board)
        switch location {
        case .local:
            guard await loadLocalForMutation() else { return }
            await beginLocalMutation()
            defer { endLocalMutation() }
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
            let revision = boardLoadRevision
            do {
                try await connection.saveFaces(document: decoded)
                guard boardStillShown(connection, since: revision) else { return }
                await reload(connection: connection)
            } catch {
                guard boardStillShown(connection, since: revision) else { return }
                errorMessage = String(
                    format: NSLocalizedString("同步失败：%@", comment: "face library sync failed"),
                    error.localizedDescription
                )
            }
        }
    }

    /// Reads the original legacy store for explicit migration only. No seeding,
    /// normalization or writes can alter the source file.
    func legacyMigrationFaces() async -> [SavedFace] {
        do {
            return try await localStore.load()?.sortedFaces.filter {
                $0.type != .default && $0.packedFrame != nil
            } ?? []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    @discardableResult
    func migrateLegacyFaces(_ sources: [SavedFace], to target: BoardFaceSaveSource,
                            connection: BoardConnection) async -> FaceBatchResult {
        var result = FaceBatchResult()
        guard let physicalID = target.boardID, connection.supportsConditionalFaceWrites else {
            errorMessage = NSLocalizedString("请连接支持条件写入的面板后复制旧表情", comment: "legacy migration needs verified conditional board")
            return result
        }
        // The selected value snapshots are fixed by the migration sheet. Each
        // snapshot has a deterministic target UUID equivalent, including board
        // identity, so cancelling or relaunching never creates another copy.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for source in sources {
            guard connection.connectionState == .connected,
                  connection.boardKey == physicalID,
                  connection.connectionGeneration == target.generation else {
                result.failures[source.id] = NSLocalizedString("连接已改变，复制已停止", comment: "migration connection changed")
                break
            }
            guard let frame = source.packedFrame, let encoded = try? encoder.encode(source) else { continue }
            var key = Data(physicalID.utf8)
            key.append(0)
            key.append(encoded)
            let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
            let id = "migrated_" + String(digest.prefix(32))
            let payload = FaceUpsertPayload(id: id, name: cleanName(source.name),
                                            type: source.type == .parts ? "parts" : "custom",
                                            frameHex: frame.hex94,
                                            call: source.type == .parts ? source.call : nil)
            guard await reload(connection: connection) else {
                result.failures[source.id] = errorMessage ?? "Read failed"
                break
            }
            if matchesSavedPayload(payload) {
                result.succeededIDs.append(source.id)
                continue
            }
            guard face(id: id, in: .board) == nil else {
                result.failures[source.id] = NSLocalizedString("目标表情已改变，请先检查板上内容", comment: "migration target conflict")
                continue
            }
            let cursor = BoardFaceSaveSource(boardID: physicalID,
                                              generation: connection.connectionGeneration,
                                              expectedBootId: connection.bootId,
                                              expectedGen: connection.currentFacesGeneration)
            switch await save(payload, source: cursor, createOnly: true, connection: connection) {
            case .saved: result.succeededIDs.append(source.id)
            case .pending, .failed:
                result.failures[source.id] = errorMessage ?? NSLocalizedString("结果待确认", comment: "migration save pending")
                // Keep the same deterministic target on the next explicit run.
                report(result, action: .copy)
                return result
            }
        }
        report(result, action: .copy)
        return result
    }

    // MARK: Helpers

    /// A physical identity takes precedence over a link session. When either
    /// side lacks that identity, only the exact session is safe: an unknown
    /// board after reconnect must not inherit an old face id. `board:<id>`
    /// and `ble:<peripheral UUID>` are bound to one device; `wifi:<host>` is
    /// only an address that another board can answer on after a reconnect
    /// (DHCP reuse, a shared mDNS name), so it never crosses a generation.
    nonisolated static func sameBoard(sourceBoardID: String?, sourceGeneration: UUID?,
                                      currentBoardID: String?, currentGeneration: UUID) -> Bool {
        let sourcePhysical = sourceBoardID.flatMap(physicalIdentity)
        let currentPhysical = currentBoardID.flatMap(physicalIdentity)
        if sourcePhysical != nil || currentPhysical != nil {
            return sourcePhysical != nil && sourcePhysical == currentPhysical
        }
        guard sourceBoardID == currentBoardID else { return false }
        return sourceGeneration != nil && sourceGeneration == currentGeneration
    }

    nonisolated private static func physicalIdentity(_ boardKey: String) -> String? {
        boardKey.hasPrefix("wifi:") ? nil : boardKey
    }

    /// False once the model has been pointed at another link since `revision`
    /// was captured: the op's result then belongs to a board that is no longer
    /// shown and must not touch shared state. A refresh of the same link also
    /// moves the revision; callers then skip the in-place patch and re-read,
    /// because that refresh's GET_FACES may predate the op.
    private func boardStillShown(_ connection: BoardConnection, since revision: UInt64) -> Bool {
        revision == boardLoadRevision
            || boardLoadTargetGeneration == connection.connectionGeneration
    }

    /// The one rule for applying a face write locally instead of reading the
    /// library back: the reply's generation is the next one after the
    /// generation this model shows, on the same boot. Then no other writer —
    /// another client, or another model on this connection — changed anything
    /// in between. Returns that generation.
    private func continuesShownLibrary(_ reply: FaceOpReply, _ connection: BoardConnection,
                                       since revision: UInt64) -> Int? {
        guard revision == boardLoadRevision, boardDocumentBelongs(to: connection),
              boardBootId == connection.bootId,
              let gen = reply.gen, let shown = boardFacesGen, gen == shown + 1 else { return nil }
        return gen
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

    private func loadLocalForMutation() async -> Bool {
        await loadLocalIfNeeded()
        return isLocalLoaded
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

    /// Refreshes preset *content* from the bundle while keeping the
    /// persisted interleaving of presets and user faces: a straight
    /// `defaults + users` concatenation (the previous implementation) would
    /// silently reset any drag reorder that mixed the two on every launch. A
    /// newly shipped preset that the stored document has never seen is
    /// appended once instead of resetting every existing face's rank.
    private func mergedWithBundledDefaults(_ stored: FaceDocument, bundle: Bundle) -> FaceDocument {
        let latest = bundledDefaults(bundle: bundle).faces.filter { $0.type == .default }
        var remaining = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [SavedFace] = []
        for face in stored.sortedFaces {
            if face.type == .default {
                if let refreshed = remaining.removeValue(forKey: face.id) { ordered.append(refreshed) }
            } else {
                ordered.append(face)
            }
        }
        for face in latest where remaining[face.id] != nil { ordered.append(face) }
        for index in ordered.indices { ordered[index].order = index + 1 }
        var result = FaceDocument(format: stored.format, version: stored.version,
                                  matrix: stored.matrix, faces: ordered,
                                  category: stored.category, startupDefaultId: stored.startupDefaultId)
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
        // A subset that dropped the referenced face (an export selection, a
        // local copy, etc.) must not point `startupDefaultId` at an id that
        // no longer exists in this document.
        if let startupID = document.startupDefaultId,
           !document.faces.contains(where: { $0.id == startupID }) {
            document.startupDefaultId = nil
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
            // The firmware's 409 wording ("face changed since it was
            // loaded…") is an internal protocol message, not UI copy; show
            // the same localized guidance `saveLocal` gives for the
            // equivalent local conflict.
            let originalMessage = (code == 409 && linkError.error.contains("face changed since it was loaded"))
                ? NSLocalizedString(
                    "此表情已在别处被修改：请另存为新表情，或重新载入该表情后再改",
                    comment: "board overwrite target changed since it was loaded"
                )
                : linkError.error
            await reload(connection: connection)
            // `reload` clears `errorMessage` at entry and may set its own on
            // failure. The original rejection reason must not disappear
            // behind a successful (or differently-worded failed) refresh.
            if let refreshError = errorMessage {
                errorMessage = originalMessage + "\n" + refreshError
            } else {
                errorMessage = originalMessage
            }
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
        let format = NSLocalizedString("%@ 副本", comment: "saved face copy name")
        var ordinal = 1
        while true {
            let ordinalSuffix = ordinal == 1 ? "" : " \(ordinal)"
            let candidate = fittedName(name) { base in
                String(format: format, base) + ordinalSuffix
            }
            if !names.contains(candidate.localizedLowercase) { return candidate }
            ordinal += 1
        }
    }

    /// Truncates to at most 64 UTF-8 bytes (the protocol's own limit) on a
    /// `Character` boundary, never splitting a multi-byte grapheme in half —
    /// `.prefix(64)` truncates by *character* count, which is a different
    /// (and looser) limit.
    private func cleanName(_ name: String) -> String {
        fittedName(name, suffix: "")
    }

    /// Fits a base plus a fixed suffix into the 64-byte protocol field while
    /// preserving whole extended grapheme clusters from the base.
    private func fittedName(_ name: String, suffix: String) -> String {
        fittedName(name) { $0 + suffix }
    }

    /// Fits names whose localized affix may appear before or after the base.
    /// Re-evaluating the formatter also accounts for numbered-copy suffixes.
    private func fittedName(_ name: String, transform: (String) -> String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "face" : trimmed
        var base = source
        while !base.isEmpty {
            let candidate = transform(base)
            if candidate.utf8.count <= 64 { return candidate }
            base.removeLast()
        }
        // Localized affixes are expected to be short. This final clamp makes
        // the wire invariant unconditional even for a malformed translation.
        var candidate = transform("")
        while candidate.utf8.count > 64 { candidate.removeLast() }
        return candidate.isEmpty ? "face" : candidate
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
