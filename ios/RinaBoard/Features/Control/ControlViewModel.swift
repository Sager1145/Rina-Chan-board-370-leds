import Foundation
import RinaCore

/// Control tab state (design guide §15, §63): direct LED editing, live
/// preview, eye sync, clear/full and face-part composition.
///
/// Board-global controls (brightness, colour, prev/next, auto mode, saves)
/// deliberately do **not** live here — they moved to the Control Center.
///
/// The draft frame is local user state and is kept distinct from what the
/// board has confirmed (§37): with Live Preview off, edits stay local until
/// Send; with it on, each edit is pushed through `BoardConnection.setFrame`,
/// which already coalesces frames (≥20 ms apart, depth 6, drop-oldest), so a
/// fast series of taps can never flood the link (§39).
@Observable
@MainActor
final class ControlViewModel {
    // MARK: Draft state

    private(set) var draftFrame = PackedFrame() { didSet { scheduleDraftSave() } }
    /// True while the draft is exactly the composition of `selectedCall`; a
    /// raw LED edit clears it, because the frame no longer matches the parts.
    private(set) var fromParts = false
    var selectedCall = PartsCall.defaultCall

    /// Whether the draft has unsent changes relative to the last Send.
    var hasUnsentChanges: Bool { draftFrame != lastSentFrame }

    // MARK: Undo
    //
    // Two levels. A *checkpoint* is a part choice, a random roll or a clear;
    // undoing one returns to the state before it. Between checkpoints every
    // hand edit — a tap, a whole drag stroke, an invert — is one undo step,
    // and those steps stop at the checkpoint they were drawn on. Choosing a
    // new part drops them: undoing that choice goes back to the previous
    // part choice itself, not to the drawing that was on top of it.

    private struct EditorSnapshot: Equatable {
        var frame: PackedFrame
        var fromParts: Bool
        var call: PartsCall
    }

    private static let undoLimit = 100
    /// States before each checkpoint, oldest first.
    private var checkpointHistory: [EditorSnapshot] = []
    /// States before each hand edit since the last checkpoint, oldest first.
    /// Element 0 is the state those edits were drawn on — the last checkpoint,
    /// or wherever an undo landed before drawing resumed.
    private var editHistory: [EditorSnapshot] = []
    /// A drag stroke has already recorded its undo step.
    private var strokeIsOpen = false
    var canUndo: Bool { !editHistory.isEmpty || !checkpointHistory.isEmpty }
    private var lastSentFrame = PackedFrame()
    /// Whether the user has touched the editor at all this launch. The
    /// initial default parts composition is *not* user content, so a first
    /// connection is still allowed to populate the preview from the board.
    private var userHasEdited = false

    // MARK: Command row (§18)

    /// §18.2: defaults to on.
    var livePreview = true
    /// §18.3: mirrors edits between the two eyes through an explicit,
    /// verified topology. Set through `setSyncEyes(_:connection:)` so that
    /// enabling it also aligns the eyes that are already selected.
    private(set) var syncEyes = false
    /// §18.5: what a drag across the preview writes. `true` lights the LEDs
    /// the finger crosses, `false` puts them out. Painting an explicit value —
    /// rather than toggling each LED — is what makes dragging usable: a
    /// stroke that crosses its own path must not undo the cells it just
    /// drew. Taps ignore it and always toggle (`toggle(led:connection:)`).
    var brushOn = true

    // MARK: Save target

    var editingFaceId: String?
    var editingLocation: FaceLibraryLocation = .local
    var editingBoardGeneration: UUID?
    var draftStorageError: String?
    private var restoringDraft = false
    private var draftSaveTask: Task<Void, Never>?
    private var sentGeneration: UUID?
    private var sendTask: Task<Void, Never>?

    private struct Draft: Codable {
        var version = 1
        var frame: String
        var name: String
        var fromParts: Bool
        var call: PartsCall
        var localFaceID: String?
    }

    func restoreDraft() async {
        do {
            guard let data = try await DraftStorage.shared.read("face"), !userHasEdited else { return }
            let draft = try JSONDecoder().decode(Draft.self, from: data)
            guard draft.version == 1, let frame = PackedFrame(hex94: draft.frame) else { return }
            restoringDraft = true
            defer { restoringDraft = false }
            draftFrame = frame; saveName = draft.name; fromParts = draft.fromParts
            selectedCall = draft.call; userHasEdited = true
            editingLocation = .local; editingFaceId = draft.localFaceID
            lastSentFrame = PackedFrame()
            resetUndoHistory()
        } catch {
            draftStorageError = String(
                format: NSLocalizedString("无法恢复草稿：%@", comment: "face draft restore failed"),
                error.localizedDescription
            )
        }
    }

    private func scheduleDraftSave() {
        guard !restoringDraft else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.persistDraft()
        }
    }

    func persistDraft() async {
        let draft = Draft(frame: draftFrame.hex94, name: saveName, fromParts: fromParts,
                          call: selectedCall, localFaceID: editingLocation == .local ? editingFaceId : nil)
        do {
            let data = try JSONEncoder().encode(draft)
            try await DraftStorage.shared.write(data, name: "face")
            draftStorageError = nil
        } catch {
            draftStorageError = String(
                format: NSLocalizedString("草稿尚未保存到本机：%@", comment: "face draft persistence failed"),
                error.localizedDescription
            )
        }
    }

    func releaseOutput() { sendTask?.cancel(); sendTask = nil }
    func connectionChanged() { sentGeneration = nil; releaseOutput() }
    func wasSent(in connection: BoardConnection) -> Bool {
        sentGeneration == connection.connectionGeneration && !hasUnsentChanges
    }

    func loadForEditing(_ request: FaceEditRequest) {
        loadForEditing(request.face)
        editingLocation = request.location
        editingBoardGeneration = request.boardGeneration
        if request.asCopy { editingFaceId = nil }
        scheduleDraftSave()
    }
    var saveName = "parts_face" { didSet { scheduleDraftSave() } }

    var errorMessage: String?
    var isSending = false

    // MARK: Resources

    let library: PartsLibrary?
    let loadError: String?
    /// Nil when the shipped part data doesn't match the derived eye mapping,
    /// in which case LED-level eye sync is unavailable.
    let eyeTopology: EyeTopology?

    var canSyncEyes: Bool { eyeTopology != nil }

    init(bundle: Bundle = .main) {
        do {
            let library = try RinaResources.partsLibrary(bundle: bundle)
            self.library = library
            self.loadError = nil
            self.eyeTopology = EyeTopology.make(from: library)
            self.selectedCall = .defaultCall
            self.draftFrame = library.compose(call: .defaultCall)
            self.fromParts = true
        } catch {
            self.library = nil
            self.eyeTopology = nil
            self.loadError = String(format: NSLocalizedString("无法加载部件库：%@", comment: "parts library load failed"),
                                    error.localizedDescription)
        }
        lastSentFrame = draftFrame
    }

    private var snapshot: EditorSnapshot {
        EditorSnapshot(frame: draftFrame, fromParts: fromParts, call: selectedCall)
    }

    /// Steps back one hand edit, or — with none left since the last
    /// checkpoint — to the state before that checkpoint.
    func undo(connection: BoardConnection) {
        strokeIsOpen = false
        guard let previous = editHistory.popLast() ?? checkpointHistory.popLast() else { return }
        userHasEdited = true
        draftFrame = previous.frame
        fromParts = previous.fromParts
        selectedCall = previous.call
        pushLiveIfNeeded(connection: connection)
    }

    /// The finger that was drawing has lifted: the next stroke is a new step.
    func endStroke() { strokeIsOpen = false }

    /// A new draft identity (loaded, restored, adopted) starts a fresh history.
    private func resetUndoHistory() {
        checkpointHistory.removeAll()
        editHistory.removeAll()
        strokeIsOpen = false
    }

    private func recordEdit(_ before: EditorSnapshot) {
        strokeIsOpen = false
        editHistory.append(before)
        // Trim from index 1: element 0 is the checkpoint state, still needed
        // by the next checkpoint.
        if editHistory.count > Self.undoLimit { editHistory.remove(at: 1) }
    }

    /// - Parameter keepingEdits: `true` for a clear, whose undo brings the
    ///   erased drawing back and then keeps stepping through the edits that
    ///   drew it; `false` for a part choice, whose undo returns to the
    ///   previous part choice without the drawing on top of it.
    private func recordCheckpoint(keepingEdits: Bool) {
        strokeIsOpen = false
        if keepingEdits {
            checkpointHistory.append(contentsOf: editHistory)
            checkpointHistory.append(snapshot)
        } else {
            checkpointHistory.append(editHistory.first ?? snapshot)
        }
        editHistory.removeAll()
        if checkpointHistory.count > Self.undoLimit {
            checkpointHistory.removeFirst(checkpointHistory.count - Self.undoLimit)
        }
    }

    /// Turns eye sync on or off. Enabling it projects the **left** eye onto
    /// the right immediately, so the two eyes are never left mismatched
    /// until the next edit happens to touch them.
    func setSyncEyes(_ enabled: Bool, connection: BoardConnection) {
        guard syncEyes != enabled else { return }
        syncEyes = enabled
        guard enabled else { return }

        // A parts-composed draft syncs at the part level, which keeps
        // `fromParts` (and therefore the part rows) meaningful.
        if fromParts, let library,
           let mirrored = library.mirroredEyeId(selectedCall[.leye]),
           selectedCall[.reye] != mirrored {
            var call = selectedCall
            call[.reye] = mirrored
            applyCall(call, library: library, connection: connection)
            return
        }

        guard let eyeTopology else { return }
        let before = snapshot
        var changed = false
        for pair in eyeTopology.leftToRightPairs where draftFrame[pair.right] != draftFrame[pair.left] {
            draftFrame[pair.right] = draftFrame[pair.left]
            changed = true
        }
        guard changed else { return }
        recordEdit(before)
        userHasEdited = true
        // The frame no longer matches the selected parts once pixels moved.
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    // MARK: Direct LED editing (§16)

    /// A tap: flips one physically valid LED, whatever the brush is set to.
    /// Invalid positions never reach here — hit testing rejects them (§17).
    func toggle(led: Int, connection: BoardConnection) {
        recordEdit(snapshot)
        userHasEdited = true
        draftFrame.toggle(led)
        if syncEyes, let mirrored = eyeTopology?.mirroredLED(of: led), mirrored != led {
            // Mirror the resulting *state*, not another toggle, so repeated
            // edits can't desynchronise the two eyes.
            draftFrame[mirrored] = draftFrame[led]
        }
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    /// One LED of a drag stroke: writes the current brush value to one
    /// physically valid LED. Invalid positions never reach here (§17).
    ///
    /// Returns whether the draft actually changed, so a stroke that runs over
    /// LEDs already in the brush's state neither pushes a redundant frame nor
    /// fires feedback for an edit that did not happen.
    @discardableResult
    func paint(led: Int, connection: BoardConnection) -> Bool {
        let on = brushOn
        // Mirror the brush *value*, not a toggle, so a stroke that crosses
        // both eyes can't desynchronise them.
        let mirrored = syncEyes ? eyeTopology?.mirroredLED(of: led).flatMap { $0 == led ? nil : $0 } : nil
        guard draftFrame[led] != on || mirrored.map({ draftFrame[$0] != on }) == true else { return false }

        // One undo step per stroke, recorded at its first real change;
        // `endStroke()` closes it when the finger lifts.
        if !strokeIsOpen {
            recordEdit(snapshot)
            strokeIsOpen = true
        }
        userHasEdited = true
        draftFrame[led] = on
        if let mirrored { draftFrame[mirrored] = on }
        fromParts = false
        pushLiveIfNeeded(connection: connection)
        return true
    }

    /// §18.4: all editable LEDs off.
    func clear(connection: BoardConnection) {
        var cleared = draftFrame
        cleared.clearAll()
        if snapshot != EditorSnapshot(frame: cleared, fromParts: false, call: selectedCall) {
            recordCheckpoint(keepingEdits: true)
        }
        userHasEdited = true
        draftFrame = cleared
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    func invert(connection: BoardConnection) {
        recordEdit(snapshot)
        userHasEdited = true
        draftFrame.invert()
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    // MARK: Face-part composition (§19, §48)

    func selectPart(group: PartGroup, id: String, connection: BoardConnection) {
        guard let library else { return }
        var call = selectedCall
        call[group] = id
        if syncEyes, group == .leye || group == .reye,
           let mirrored = library.mirroredEyeId(id) {
            call[group == .leye ? .reye : .leye] = mirrored
        }
        applyCall(call, library: library, connection: connection)
    }

    func randomizeParts(connection: BoardConnection) {
        guard let library else { return }
        var generator = SystemRandomNumberGenerator()
        let call = syncEyes
            ? library.randomSymmetricCall(using: &generator)
            : library.randomCall(using: &generator)
        applyCall(call, library: library, connection: connection)
    }

    func resetPartsToDefault(connection: BoardConnection) {
        guard let library else { return }
        applyCall(.defaultCall, library: library, connection: connection)
    }

    /// Every part-level change lands here, so each one is an undo checkpoint.
    private func applyCall(_ call: PartsCall, library: PartsLibrary, connection: BoardConnection) {
        let frame = library.compose(call: call)
        if snapshot != EditorSnapshot(frame: frame, fromParts: true, call: call) {
            recordCheckpoint(keepingEdits: false)
        }
        userHasEdited = true
        selectedCall = call
        draftFrame = frame
        fromParts = true
        pushLiveIfNeeded(connection: connection)
    }

    /// The variant currently selected in a part row, as a display index.
    func selectedIndex(in group: PartGroup) -> Int {
        library?.displayIndex(of: selectedCall[group], in: group) ?? 0
    }

    // MARK: Sending (§18.1)

    func send(connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = NSLocalizedString("设备未连接", comment: "not connected")
            return
        }
        isSending = true
        defer { isSending = false }
        let frame = draftFrame
        let token = connection.output.begin(.manual)
        do {
            _ = try await connection.setFrame(frame, playback: .idle, reason: "custom_face_send", outputSession: token)
            lastSentFrame = frame
            sentGeneration = connection.connectionGeneration
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = String(format: NSLocalizedString("发送失败：%@", comment: "frame send failed"),
                                  error.localizedDescription)
        }
    }

    private func pushLiveIfNeeded(connection: BoardConnection) {
        guard livePreview, connection.connectionState == .connected else { return }
        let frame = draftFrame
        let token = connection.output.claim(.manual)
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            do {
                _ = try await connection.setFrame(frame, playback: .idle, reason: "custom_live_send", outputSession: token)
                self?.lastSentFrame = frame
                self?.sentGeneration = connection.connectionGeneration
                self?.errorMessage = nil
            } catch is CancellationError {
            } catch RatePumpError.dropped {
                // Superseded by a newer frame; the latest edit always wins.
            } catch {
                self?.errorMessage = String(
                    format: NSLocalizedString("实时同步失败：%@", comment: "live face sync failed"),
                    error.localizedDescription
                )
            }
        }
    }

    // MARK: Saves hand-off (§11)

    func upsertPayload(using library: FaceLibraryModel) -> FaceUpsertPayload {
        library.upsertPayload(editingFaceId: editingFaceId,
                              name: saveName,
                              frame: draftFrame,
                              fromParts: fromParts,
                              call: selectedCall)
    }

    /// Pulls a saved face into the editor (Control Center → Control tab).
    func loadForEditing(_ face: SavedFace) {
        guard let frame = face.packedFrame else {
            errorMessage = NSLocalizedString("此表情的帧数据无效", comment: "saved face has invalid frame data")
            return
        }
        draftFrame = frame
        sentGeneration = nil
        userHasEdited = true
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
        resetUndoHistory()
    }

    func startNewFace() {
        editingFaceId = nil
        saveName = "parts_face"
    }

    /// After a successful library save, keep tracking whatever id the board
    /// assigned. The undo history survives: saving is not an edit.
    ///
    /// Deliberately does **not** touch `lastSentFrame`: saving a face to the
    /// board's library is a different operation from transmitting the frame to
    /// the board's display, so a save must never clear the "unsent" badge on a
    /// frame that was never sent (§37).
    func didSave(as id: String?) {
        if let id { editingFaceId = id }
    }

    // MARK: Reconnect (§40)

    /// Populates the editor from the board's current frame after a
    /// (re)connection (§49). A draft the user has actually worked on is
    /// authoritative and is never overwritten (§40) — only the untouched
    /// initial composition gives way.
    func adoptBoardFrameIfUntouched(_ frame: PackedFrame) {
        guard !userHasEdited, !hasUnsentChanges else { return }
        draftFrame = frame
        lastSentFrame = frame
        fromParts = false
        resetUndoHistory()
    }
}
