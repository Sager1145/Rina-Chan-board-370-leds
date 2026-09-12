import Foundation
import RinaCore

/// The saved-face library ("Saves", design guide §11).
///
/// Saves are board-global — they belong to the Control Center and are
/// reachable regardless of which tab is selected — so this model is created
/// once at app scope rather than per screen. The board owns the document;
/// every mutation goes through an incremental `face_*` command and the local
/// copy is only patched when the firmware's generation counter confirms no
/// concurrent change, otherwise the whole document is refetched.
@Observable
@MainActor
final class FaceLibraryModel {
    var faceDocument = FaceDocument()
    var isLoading = false
    var isSaving = false
    var renamingFace: SavedFace?
    var renameText = ""
    var errorMessage: String?

    /// Result of a save. `.saved` carries the id the face ended up with, which
    /// is `nil` only when the board assigned one we couldn't match back — it is
    /// never used to signal failure, so callers can't mistake one for the other.
    enum SaveOutcome: Equatable {
        case saved(id: String?)
        case failed
    }

    var defaultFaces: [SavedFace] { faceDocument.sortedFaces.filter { $0.type == .default } }
    var userFaces: [SavedFace] { faceDocument.sortedFaces.filter { $0.type != .default } }

    // MARK: Load

    func reload(connection: BoardConnection, bundle: Bundle = .main) async {
        isLoading = true
        defer { isLoading = false }
        faceDocument = await connection.loadFaceDocument(bundle: bundle)
    }

    // MARK: Apply (tap a save → load it onto the board)

    func apply(_ face: SavedFace, connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法应用表情", comment: "apply face while disconnected")
            return
        }
        let sorted = faceDocument.sortedFaces
        guard let index = sorted.firstIndex(where: { $0.id == face.id }) else { return }
        do {
            _ = try await connection.applySavedFace(index: index)
        } catch {
            errorMessage = String(format: NSLocalizedString("应用失败：%@", comment: "apply face failed"),
                                  error.localizedDescription)
        }
    }

    // MARK: Save / update

    /// Upserts the caller's current draft. Returns the id the face ended up
    /// with, so the editor can keep tracking it.
    @discardableResult
    func save(_ payload: FaceUpsertPayload, connection: BoardConnection) async -> SaveOutcome {
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法保存到面板", comment: "save face while disconnected")
            return .failed
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
                faceDocument.faces[index].updatedAt = ISO8601DateFormatter().string(from: Date())
                faceDocument.faces[index].call = payload.call
                return .saved(id: id)
            }
            // New face (the board assigns the id), a generation mismatch, or a
            // frame we couldn't decode to patch locally: refetch so the local
            // document can never drift from the board's.
            await reload(connection: connection)
            if payload.id == nil, let frame = savedFrame {
                let bytes = frame.bytes.map(Int.init)
                let matched = faceDocument.faces.first { $0.name == payload.name && $0.frameBytes == bytes }
                return .saved(id: matched?.id)
            }
            return .saved(id: payload.id)
        } catch {
            await handleFaceOpError(error, connection: connection)
            return .failed
        }
    }

    /// Builds the upsert payload for an edited existing face, honouring the
    /// rule that default/locked faces are never overwritten — they are saved
    /// as a copy instead.
    func upsertPayload(
        editingFaceId: String?,
        name: String,
        frame: PackedFrame,
        fromParts: Bool,
        call: PartsCall
    ) -> FaceUpsertPayload {
        let cleanName: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = String(trimmed.prefix(64))
            return truncated.isEmpty ? "face" : truncated
        }()
        let existing = editingFaceId.flatMap { id in faceDocument.faces.first { $0.id == id } }
        let overwriteId: String? = (existing != nil && existing?.type != .default && existing?.locked != true)
            ? existing?.id
            : nil
        let nameToSend = (overwriteId == nil && editingFaceId != nil) ? "\(cleanName)_copy" : cleanName
        return FaceUpsertPayload(
            id: overwriteId,
            name: nameToSend,
            type: (fromParts ? SavedFace.Kind.parts : .custom).rawValue,
            frameHex: frame.hex94,
            call: fromParts
                ? SavedFace.CallIds(leye: call.leye, reye: call.reye, mouth: call.mouth, cheek: call.cheek)
                : nil
        )
    }

    // MARK: Rename / delete / reorder

    func rename(_ face: SavedFace, to newName: String, connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法同步到面板", comment: "face sync while disconnected")
            return
        }
        let clean = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !clean.isEmpty else { return }
        do {
            _ = try await connection.faceRename(id: face.id, name: clean)
            if connection.lastFaceOpGenMatchedExpectation,
               let index = faceDocument.faces.firstIndex(where: { $0.id == face.id }) {
                faceDocument.faces[index].name = clean
                faceDocument.faces[index].updatedAt = ISO8601DateFormatter().string(from: Date())
            } else {
                await reload(connection: connection)
            }
        } catch {
            await handleFaceOpError(error, connection: connection)
        }
    }

    func delete(_ face: SavedFace, connection: BoardConnection) async {
        guard face.type != .default else {
            errorMessage = NSLocalizedString("默认表情不可删除", comment: "default face is not deletable")
            return
        }
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法同步到面板", comment: "face sync while disconnected")
            return
        }
        do {
            _ = try await connection.faceDelete(id: face.id)
            if connection.lastFaceOpGenMatchedExpectation {
                faceDocument.faces.removeAll { $0.id == face.id }
            } else {
                await reload(connection: connection)
            }
        } catch {
            await handleFaceOpError(error, connection: connection)
        }
    }

    /// Reassigns sequential 1-based `order` across the whole document after a
    /// drag reorder of the user section: default faces keep their existing
    /// relative order first, followed by `newUserOrder`.
    func reorderUserFaces(_ newUserOrder: [SavedFace], connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法同步到面板", comment: "face sync while disconnected")
            return
        }
        let ids = (defaultFaces + newUserOrder).map(\.id)
        do {
            _ = try await connection.faceReorder(ids: ids)
            if connection.lastFaceOpGenMatchedExpectation {
                for (rank, id) in ids.enumerated() {
                    if let index = faceDocument.faces.firstIndex(where: { $0.id == id }) {
                        faceDocument.faces[index].order = rank + 1
                    }
                }
            } else {
                await reload(connection: connection)
            }
        } catch {
            await handleFaceOpError(error, connection: connection)
        }
    }

    // MARK: Import / export

    func exportData() -> Data? {
        try? faceDocument.encoded()
    }

    func importDocument(from data: Data, connection: BoardConnection) async {
        guard var decoded = try? FaceDocument(jsonData: data) else {
            errorMessage = NSLocalizedString("导入失败：文件格式无效", comment: "face import invalid file")
            return
        }
        normalize(&decoded)
        faceDocument = decoded
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("未连接，无法同步到面板", comment: "face sync while disconnected")
            return
        }
        do {
            try await connection.saveFaces(document: faceDocument)
        } catch {
            errorMessage = String(format: NSLocalizedString("同步失败：%@", comment: "face sync failed"),
                                  error.localizedDescription)
        }
    }

    /// Ensures every face has a non-empty id/order and that at least one
    /// `default` face survives, mirroring the WebUI's `normalizeFace` guard.
    private func normalize(_ document: inout FaceDocument) {
        for i in document.faces.indices where document.faces[i].id.isEmpty {
            document.faces[i].id = "custom_\(String(Int(Date().timeIntervalSince1970 * 1000) + i, radix: 36))"
        }
        let orderedIndices = document.faces.indices.sorted { a, b in
            let orderA = document.faces[a].order
            let orderB = document.faces[b].order
            return orderA != orderB ? orderA < orderB : a < b
        }
        for (rank, index) in orderedIndices.enumerated() {
            document.faces[index].order = rank + 1
        }
        if !document.faces.contains(where: { $0.type == .default }), let first = document.faces.indices.first {
            document.faces[first].type = .default
            document.faces[first].deletable = false
        }
    }

    /// 400/404/409 face-op replies: surface the message and refetch from the
    /// board so the UI never drifts from on-board state.
    private func handleFaceOpError(_ error: Error, connection: BoardConnection) async {
        if let linkError = error as? RinaLinkError, let code = linkError.code, [400, 404, 409].contains(code) {
            errorMessage = linkError.error
            await reload(connection: connection)
        } else {
            errorMessage = String(format: NSLocalizedString("同步失败：%@", comment: "face sync failed"),
                                  error.localizedDescription)
        }
    }
}
