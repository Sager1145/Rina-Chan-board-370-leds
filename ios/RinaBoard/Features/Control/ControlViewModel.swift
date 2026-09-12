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

    private(set) var draftFrame = PackedFrame()
    /// True while the draft is exactly the composition of `selectedCall`; a
    /// raw LED edit clears it, because the frame no longer matches the parts.
    private(set) var fromParts = false
    var selectedCall = PartsCall.defaultCall

    /// Whether the draft has unsent changes relative to the last Send.
    var hasUnsentChanges: Bool { draftFrame != lastSentFrame }

    /// The state a revert returns to: the draft as it was when last loaded,
    /// saved, or freshly composed.
    private var baselineFrame = PackedFrame()
    private var baselineFromParts = false
    private var baselineCall = PartsCall.defaultCall
    var canRevert: Bool { draftFrame != baselineFrame }
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

    // MARK: Save target

    var editingFaceId: String?
    var saveName = "parts_face"

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
        captureBaseline()
    }

    private func captureBaseline() {
        baselineFrame = draftFrame
        baselineFromParts = fromParts
        baselineCall = selectedCall
    }

    /// Discards edits made since the draft was last loaded, saved or reset.
    func revertToBaseline(connection: BoardConnection) {
        draftFrame = baselineFrame
        fromParts = baselineFromParts
        selectedCall = baselineCall
        pushLiveIfNeeded(connection: connection)
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
            selectedCall[.reye] = mirrored
            recompose(library: library, connection: connection)
            return
        }

        guard let eyeTopology else { return }
        var changed = false
        for pair in eyeTopology.leftToRightPairs where draftFrame[pair.right] != draftFrame[pair.left] {
            draftFrame[pair.right] = draftFrame[pair.left]
            changed = true
        }
        guard changed else { return }
        userHasEdited = true
        // The frame no longer matches the selected parts once pixels moved.
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    // MARK: Direct LED editing (§16)

    /// Toggles one physically valid LED. Invalid positions never reach here —
    /// hit testing rejects them (§17).
    func toggle(led: Int, connection: BoardConnection) {
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

    /// §18.4: all editable LEDs off.
    func clear(connection: BoardConnection) {
        userHasEdited = true
        draftFrame.clearAll()
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    /// §18.5: every physically valid LED on. `PackedFrame.fill` sets exactly
    /// the 370 real LEDs, so no nonexistent coordinate is ever filled.
    func fill(connection: BoardConnection) {
        userHasEdited = true
        draftFrame.fill()
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    func invert(connection: BoardConnection) {
        userHasEdited = true
        draftFrame.invert()
        fromParts = false
        pushLiveIfNeeded(connection: connection)
    }

    // MARK: Face-part composition (§19, §48)

    func selectPart(group: PartGroup, id: String, connection: BoardConnection) {
        guard let library else { return }
        selectedCall[group] = id
        if syncEyes, group == .leye || group == .reye,
           let mirrored = library.mirroredEyeId(id) {
            selectedCall[group == .leye ? .reye : .leye] = mirrored
        }
        recompose(library: library, connection: connection)
    }

    func randomizeParts(connection: BoardConnection) {
        guard let library else { return }
        var generator = SystemRandomNumberGenerator()
        selectedCall = syncEyes
            ? library.randomSymmetricCall(using: &generator)
            : library.randomCall(using: &generator)
        recompose(library: library, connection: connection)
    }

    func resetPartsToDefault(connection: BoardConnection) {
        guard let library else { return }
        selectedCall = .defaultCall
        recompose(library: library, connection: connection)
    }

    private func recompose(library: PartsLibrary, connection: BoardConnection) {
        userHasEdited = true
        draftFrame = library.compose(call: selectedCall)
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
        do {
            _ = try await connection.setFrame(frame, playback: .idle, reason: "custom_face_send")
            lastSentFrame = frame
        } catch {
            errorMessage = String(format: NSLocalizedString("发送失败：%@", comment: "frame send failed"),
                                  error.localizedDescription)
        }
    }

    private func pushLiveIfNeeded(connection: BoardConnection) {
        guard livePreview, connection.connectionState == .connected else { return }
        let frame = draftFrame
        Task { [weak self] in
            do {
                _ = try await connection.setFrame(frame, playback: .idle, reason: "custom_live_send")
                self?.lastSentFrame = frame
            } catch is CancellationError {
            } catch RatePumpError.dropped {
                // Superseded by a newer frame; the latest edit always wins.
            } catch {
                // A failed live push leaves the draft marked unsent, which is
                // the honest state — the board did not accept this frame.
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
        lastSentFrame = frame
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
        captureBaseline()
    }

    func startNewFace() {
        editingFaceId = nil
        saveName = "parts_face"
    }

    /// After a successful library save, keep tracking whatever id the board
    /// assigned, and make this the state a revert returns to.
    ///
    /// Deliberately does **not** touch `lastSentFrame`: saving a face to the
    /// board's library is a different operation from transmitting the frame to
    /// the board's display, so a save must never clear the "unsent" badge on a
    /// frame that was never sent (§37).
    func didSave(as id: String?) {
        if let id { editingFaceId = id }
        captureBaseline()
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
        captureBaseline()
    }
}
