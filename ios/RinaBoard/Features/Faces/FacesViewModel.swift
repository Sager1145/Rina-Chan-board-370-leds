import Foundation
import UIKit
import RinaCore

/// State + logic for the Faces tab (FEATURE_INVENTORY §B): pixel editor,
/// parts composer, packed-frame text I/O, save/library management and
/// import/export. `BoardConnection.setFrame` already applies the D6 frame
/// rate limit (>=20ms apart, depth 6, drop-oldest via its internal
/// `RatePump`), so live-mode sends simply call it directly per edit.
@Observable
@MainActor
final class FacesViewModel {
    // MARK: Editor state

    var editFrame = PackedFrame()
    var fromParts = false
    var liveMode = true
    var symmetryOn = false
    var selectedCall = PartsCall.defaultCall
    var editingFaceId: String?
    var saveName = "parts_face"
    var errorMessage: String?
    var importText = ""

    private var baselineFrame = PackedFrame()
    private var baselineFromParts = false
    private var baselineCall = PartsCall.defaultCall

    // MARK: Library state

    var faceDocument = FaceDocument()
    var isLoadingLibrary = false
    var isSaving = false
    var renamingFace: SavedFace?
    var renameText = ""

    // MARK: Resources

    let library: PartsLibrary?
    private let loadError: String?

    init(bundle: Bundle = .main) {
        do {
            let lib = try RinaResources.partsLibrary(bundle: bundle)
            self.library = lib
            self.loadError = nil
            self.selectedCall = PartsCall.defaultCall
            self.editFrame = lib.compose(call: selectedCall)
            self.fromParts = true
        } catch {
            self.library = nil
            self.loadError = "无法加载部件库：\(error.localizedDescription)"
        }
        captureBaseline()
    }

    var hex94: String { editFrame.hex94 }

    private func captureBaseline() {
        baselineFrame = editFrame
        baselineFromParts = fromParts
        baselineCall = selectedCall
    }

    // MARK: B1 pixel editor

    func toggle(_ led: Int, connection: BoardConnection) {
        editFrame.toggle(led)
        fromParts = false
        sendLiveIfNeeded(connection: connection)
    }

    func clearAll(connection: BoardConnection) {
        editFrame.clearAll()
        fromParts = false
        sendLiveIfNeeded(connection: connection)
    }

    func fillAll(connection: BoardConnection) {
        editFrame.fill()
        fromParts = false
        sendLiveIfNeeded(connection: connection)
    }

    func invertAll(connection: BoardConnection) {
        editFrame.invert()
        fromParts = false
        sendLiveIfNeeded(connection: connection)
    }

    // MARK: B2/B3 send

    func sendFrame(connection: BoardConnection) async {
        guard connection.connectionState == .connected else { return }
        do {
            try await connection.setFrame(editFrame, playback: .idle, reason: "custom_face_send")
        } catch {
            errorMessage = "发送失败：\(error.localizedDescription)"
        }
    }

    private func sendLiveIfNeeded(connection: BoardConnection) {
        guard liveMode, connection.connectionState == .connected else { return }
        let frame = editFrame
        Task {
            try? await connection.setFrame(frame, playback: .idle, reason: "custom_live_send")
        }
    }

    // MARK: B4-B7 parts composer

    func selectPart(group: PartGroup, id: String, connection: BoardConnection) {
        guard let library else { return }
        selectedCall[group] = id
        if symmetryOn, group == .leye || group == .reye, let mirrored = library.mirroredEyeId(id) {
            selectedCall[group == .leye ? .reye : .leye] = mirrored
        }
        editFrame = library.compose(call: selectedCall)
        fromParts = true
        sendLiveIfNeeded(connection: connection)
    }

    func randomize(connection: BoardConnection) {
        guard let library else { return }
        var rng = SystemRandomNumberGenerator()
        selectedCall = symmetryOn ? library.randomSymmetricCall(using: &rng) : library.randomCall(using: &rng)
        editFrame = library.compose(call: selectedCall)
        fromParts = true
        sendLiveIfNeeded(connection: connection)
    }

    func resetToDefault(connection: BoardConnection) {
        guard let library else { return }
        selectedCall = .defaultCall
        editFrame = library.compose(call: selectedCall)
        fromParts = true
        sendLiveIfNeeded(connection: connection)
    }

    func revertEdit(connection: BoardConnection) {
        editFrame = baselineFrame
        fromParts = baselineFromParts
        selectedCall = baselineCall
        sendLiveIfNeeded(connection: connection)
    }

    // MARK: B8 packed-frame text I/O

    func copyHex() {
        UIPasteboard.general.string = editFrame.hex94
    }

    func importFrame(from text: String, connection: BoardConnection) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "请输入内容"
            return
        }
        if let frame = PackedFrame(hex94: trimmed) {
            apply(imported: frame, connection: connection)
            return
        }
        if let frame = PackedFrame(base64: trimmed) {
            apply(imported: frame, connection: connection)
            return
        }
        if let data = trimmed.data(using: .utf8),
           let ints = try? JSONDecoder().decode([Int].self, from: data),
           ints.count == PackedFrame.byteCount {
            let bytes = ints.map { UInt8(clamping: $0) }
            if let frame = PackedFrame(bytes: bytes) {
                apply(imported: frame, connection: connection)
                return
            }
            errorMessage = "帧数据无效（尾部位必须为 0）"
            return
        }
        errorMessage = "无法识别的格式：需要 94 位十六进制 / 47 整数 JSON 数组 / base64"
    }

    private func apply(imported frame: PackedFrame, connection: BoardConnection) {
        editFrame = frame
        fromParts = false
        errorMessage = nil
        sendLiveIfNeeded(connection: connection)
    }

    // MARK: B9 save to library (incremental `face_upsert`, §7.2)

    func save(connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = "未连接，无法保存到面板"
            return
        }
        isSaving = true
        defer { isSaving = false }

        let cleanName = {
            let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = String(trimmed.prefix(64))
            return truncated.isEmpty ? "face" : truncated
        }()
        let savedType: SavedFace.Kind = fromParts ? .parts : .custom
        let call = fromParts ? SavedFace.CallIds(leye: selectedCall.leye, reye: selectedCall.reye, mouth: selectedCall.mouth, cheek: selectedCall.cheek) : nil
        let frameHex = editFrame.hex94

        // Defaults/locked faces are never overwritten; save as a new copy instead.
        let existing = editingFaceId.flatMap { id in faceDocument.faces.first { $0.id == id } }
        let overwriteId: String? = (existing != nil && existing?.type != .default && existing?.locked != true) ? existing?.id : nil
        let nameToSend = overwriteId == nil && editingFaceId != nil ? "\(cleanName)_copy" : cleanName

        let payload = FaceUpsertPayload(id: overwriteId, name: nameToSend, type: savedType.rawValue, frameHex: frameHex, call: call)

        do {
            try await connection.faceUpsert(payload)
            if let overwriteId, connection.lastFaceOpGenMatchedExpectation,
               let idx = faceDocument.faces.firstIndex(where: { $0.id == overwriteId }) {
                faceDocument.faces[idx].name = nameToSend
                faceDocument.faces[idx].type = savedType
                faceDocument.faces[idx].frameBytes = editFrame.bytes.map { Int($0) }
                faceDocument.faces[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
                faceDocument.faces[idx].call = call
            } else {
                // New face (server assigns the id) or a concurrent-mutation
                // gen mismatch: refetch the whole document to learn it.
                await reloadLibrary(connection: connection)
                if overwriteId == nil {
                    let frameBytes = editFrame.bytes.map { Int($0) }
                    editingFaceId = faceDocument.faces.first { $0.name == nameToSend && $0.frameBytes == frameBytes }?.id
                }
            }
            captureBaseline()
        } catch {
            await handleFaceOpError(error, connection: connection)
        }
    }

    // MARK: B10 library

    func reloadLibrary(connection: BoardConnection, bundle: Bundle = .main) async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        faceDocument = await connection.loadFaceDocument(bundle: bundle)
    }

    func loadForEditing(_ face: SavedFace) {
        guard let frame = face.packedFrame else {
            errorMessage = "此表情的帧数据无效"
            return
        }
        editFrame = frame
        editingFaceId = face.id
        saveName = face.name
        if face.type == .parts, let call = face.call {
            selectedCall = PartsCall(
                leye: call.leye ?? PartsCall.defaultCall.leye,
                reye: call.reye ?? PartsCall.defaultCall.reye,
                mouth: call.mouth ?? PartsCall.defaultCall.mouth,
                cheek: call.cheek ?? PartsCall.defaultCall.cheek
            )
            fromParts = true
        } else {
            fromParts = false
        }
        captureBaseline()
    }

    func startNewFace() {
        editingFaceId = nil
        saveName = "parts_face"
    }

    func apply(_ face: SavedFace, connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = "未连接，无法应用表情"
            return
        }
        let sorted = faceDocument.sortedFaces
        guard let index = sorted.firstIndex(where: { $0.id == face.id }) else { return }
        do {
            try await connection.applySavedFace(index: index)
        } catch {
            errorMessage = "应用失败：\(error.localizedDescription)"
        }
    }

    func rename(_ face: SavedFace, to newName: String, connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = "未连接，无法同步到面板"
            return
        }
        let clean = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !clean.isEmpty else { return }
        do {
            try await connection.faceRename(id: face.id, name: clean)
            if connection.lastFaceOpGenMatchedExpectation,
               let idx = faceDocument.faces.firstIndex(where: { $0.id == face.id }) {
                faceDocument.faces[idx].name = clean
                faceDocument.faces[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
            } else {
                await reloadLibrary(connection: connection)
            }
        } catch {
            await handleFaceOpError(error, connection: connection)
        }
    }

    func delete(_ face: SavedFace, connection: BoardConnection) async {
        guard face.type != .default else {
            errorMessage = "默认表情不可删除"
            return
        }
        guard connection.connectionState == .connected else {
            errorMessage = "未连接，无法同步到面板"
            return
        }
        do {
            try await connection.faceDelete(id: face.id)
            if connection.lastFaceOpGenMatchedExpectation {
                faceDocument.faces.removeAll { $0.id == face.id }
                if editingFaceId == face.id { editingFaceId = nil }
            } else {
                await reloadLibrary(connection: connection)
            }
        } catch {
            await handleFaceOpError(error, connection: connection)
        }
    }

    /// Reassigns sequential 1-based `order` across the whole document after a
    /// drag reorder within the "我的表情" section: default faces keep their
    /// existing relative order first, followed by `newUserOrder`.
    func reorderUserFaces(_ newUserOrder: [SavedFace], connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = "未连接，无法同步到面板"
            return
        }
        let sortedDefaults = faceDocument.sortedFaces.filter { $0.type == .default }
        let combined = sortedDefaults + newUserOrder
        let ids = combined.map(\.id)
        do {
            try await connection.faceReorder(ids: ids)
            if connection.lastFaceOpGenMatchedExpectation {
                for (i, id) in ids.enumerated() {
                    if let idx = faceDocument.faces.firstIndex(where: { $0.id == id }) {
                        faceDocument.faces[idx].order = i + 1
                    }
                }
            } else {
                await reloadLibrary(connection: connection)
            }
        } catch {
            await handleFaceOpError(error, connection: connection)
        }
    }

    /// 400/404/409 face-op error replies: surface the message and reload the
    /// document from the board so the UI never drifts from the on-board state.
    private func handleFaceOpError(_ error: Error, connection: BoardConnection) async {
        if let linkError = error as? RinaLinkError, let code = linkError.code, [400, 404, 409].contains(code) {
            errorMessage = linkError.error
            await reloadLibrary(connection: connection)
        } else {
            errorMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    private func persistLibrary(connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = "未连接，无法同步到面板"
            return
        }
        do {
            try await connection.saveFaces(document: faceDocument)
        } catch {
            errorMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    // MARK: B11 import / export

    func exportData() -> Data? {
        try? faceDocument.encoded()
    }

    func importDocument(from data: Data, connection: BoardConnection) async {
        guard var decoded = try? FaceDocument(jsonData: data) else {
            errorMessage = "导入失败：文件格式无效"
            return
        }
        normalize(&decoded)
        faceDocument = decoded
        await persistLibrary(connection: connection)
    }

    /// Ensures every face has a non-empty id/order and that at least one
    /// `default` face survives, mirroring the WebUI's `normalizeFace` guard.
    private func normalize(_ document: inout FaceDocument) {
        var hasDefault = document.faces.contains { $0.type == .default }
        for i in document.faces.indices {
            if document.faces[i].id.isEmpty {
                document.faces[i].id = "custom_\(String(Int(Date().timeIntervalSince1970 * 1000) + i, radix: 36))"
            }
            if document.faces[i].order == 0 {
                document.faces[i].order = i + 1
            }
        }
        if !hasDefault, let first = document.faces.indices.first {
            document.faces[first].type = .default
            document.faces[first].deletable = false
            hasDefault = true
        }
    }
}
