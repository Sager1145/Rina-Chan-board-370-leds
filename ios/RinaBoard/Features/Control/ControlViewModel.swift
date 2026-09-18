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
/// Send; with it on, each edit is submitted to a `LatestValueSender`, which
/// coalesces them so that only the newest draft is sent once the previous
/// send finishes — `BoardConnection.setFrame` still spaces frames ≥ 20 ms
/// apart (depth 6, drop-oldest) on top of that. In-flight frames are never
/// cancelled by a newer edit, so a fast series of taps can never flood the
/// link, and a superseded edit never allocates or quarantines a sequence
/// number (§39).
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

    /// Starts on so edits reach a connected board immediately.
    var livePreview = true
    /// §18.3, parts row "镜像": keeps the two eye *parts* mirrored — picking
    /// one eye selects the mirrored part for the other, and 随机 draws a
    /// symmetric pair. It never touches hand-drawn pixels; that is
    /// `mirrorDrawing`. Set through `setSyncEyes(_:connection:)` so that
    /// enabling it also aligns the eye parts that are already selected.
    private(set) var syncEyes = false
    /// Drawing row "镜像": every tap and stroke is also written to the LED
    /// mirrored across the face's vertical centre line. Parts are unaffected.
    var mirrorDrawing = false
    /// §18.5: what a drag across the preview writes. `true` lights the LEDs
    /// the finger crosses, `false` puts them out. Painting an explicit value —
    /// rather than toggling each LED — is what makes dragging usable: a
    /// stroke that crosses its own path must not undo the cells it just
    /// drew. Taps ignore it and always toggle (`toggle(led:connection:)`).
    var brushOn = true

    // MARK: Save target

    var editingFaceId: String?
    var editingLocation: FaceLibraryLocation = .local
    /// Physical board that owns `editingFaceId`. This remains stable across a
    /// reconnect even though `editingBoardGeneration` changes.
    private(set) var editingBoardID: String?
    var editingBoardGeneration: UUID?
    private var editingFaceCanOverwrite = false
    /// True when「保存」has a real choice to offer: overwrite the face being
    /// edited, or save the draft as a new one.
    var canOverwriteEditingFace: Bool { editingFaceId != nil && editingFaceCanOverwrite }
    /// Latest link session observed by RootTabView. It is only an identity
    /// fallback for firmware/transports that cannot identify the board.
    private var currentBoardGeneration: UUID?
    var boardFaceSaveSource: BoardFaceSaveSource? {
        guard editingFaceId != nil else { return nil }
        return BoardFaceSaveSource(boardID: editingBoardID,
                                   generation: editingBoardGeneration)
    }
    var draftStorageError: String?
    private var restoringDraft = false
    /// Prevents a board preview received during launch from being persisted
    /// over the on-disk draft before `restoreDraft()` has read it.
    private var draftRestoreCompleted = false
    private var draftSaveTask: Task<Void, Never>?
    private var sentGeneration: UUID?
    @ObservationIgnored private var liveSender: LatestValueSender<LiveFrameSubmission>?
    /// Mirrors the Apple Pencil hover to the board, newest LED only: a pencil
    /// sweeping the board crosses LEDs far faster than commands round-trip.
    @ObservationIgnored private var hintSender: LatestValueSender<HintSubmission>?
    /// The LED the pencil hovers over in the editor, whether or not the board
    /// is shown it — kept so a change in 即时预览, in who owns the board's
    /// output, or in which board is active can re-decide without waiting for
    /// the pencil to move.
    @ObservationIgnored private var hoveredLED: Int?
    /// What the board holding the hint was last asked to show, and which
    /// board and link that is. `boardHintUncertain` is set when a send failed
    /// without the board saying no: it may or may not have taken it, so the
    /// next change must be sent even if it looks like a repeat.
    @ObservationIgnored private var boardHintLED: HintTarget?
    @ObservationIgnored private weak var boardHintConnection: BoardConnection?
    @ObservationIgnored private var boardHintGeneration: UUID?
    @ObservationIgnored private var boardHintUncertain = false
    /// Links whose firmware predates `set_hint_led`: stop asking them.
    @ObservationIgnored private var hintUnsupportedGenerations: Set<UUID> = []

    /// One hint as the board shows it: the hovered LED and, while the eyes
    /// are edited as a pair, the other eye's LED.
    private struct HintTarget: Equatable, Sendable {
        let led: Int
        let mirror: Int?
    }

    private struct HintSubmission: Sendable {
        let target: HintTarget?
        let generation: UUID
        let connection: BoardConnection
    }
    /// The board this draft was drawn for, as `RootTabView` identifies the
    /// current link. Nil until the editor first sees a connected board.
    private(set) var draftBoardID: String?

    /// One live edit as handed to `liveSender`: everything `sendLive` needs to
    /// validate and send it, captured at edit time so a later edit or board
    /// switch can never retroactively change what an in-flight send does.
    private struct LiveFrameSubmission: Sendable {
        let frame: PackedFrame
        let owner: String?
        let token: UUID
        let generation: UUID
        let connection: BoardConnection
    }

    private struct Draft: Codable {
        var version = 1
        var frame: String
        var name: String
        var fromParts: Bool
        var call: PartsCall
        var localFaceID: String?
        var boardID: String?
    }

    func restoreDraft() async {
        guard !draftRestoreCompleted else { return }
        restoringDraft = true
        defer {
            restoringDraft = false
            draftRestoreCompleted = true
            if userHasEdited { scheduleDraftSave() }
        }
        do {
            guard let data = try await draftStorage.read("face"), !userHasEdited else { return }
            let draft = try JSONDecoder().decode(Draft.self, from: data)
            guard draft.version == 1, let frame = PackedFrame(hex94: draft.frame) else { return }
            draftFrame = frame; saveName = draft.name; fromParts = draft.fromParts
            selectedCall = draft.call; userHasEdited = true
            editingLocation = .local; editingFaceId = draft.localFaceID
            draftBoardID = draft.boardID
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
        guard !restoringDraft, draftRestoreCompleted || userHasEdited else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.persistDraft()
        }
    }

    func persistDraft() async {
        guard draftRestoreCompleted || userHasEdited else { return }
        let draft = Draft(frame: draftFrame.hex94, name: saveName, fromParts: fromParts,
                          call: selectedCall, localFaceID: editingLocation == .local ? editingFaceId : nil,
                          boardID: draftBoardID)
        do {
            let data = try JSONEncoder().encode(draft)
            try await draftStorage.write(data, name: "face")
            draftStorageError = nil
        } catch {
            draftStorageError = String(
                format: NSLocalizedString("将草稿保存到本机失败：%@", comment: "face draft persistence failed"),
                error.localizedDescription
            )
        }
    }

    func releaseOutput() { liveSender?.cancel() }
    func connectionChanged(generation: UUID? = nil) {
        clearSendConfirmation()
        currentBoardGeneration = generation
        sentGeneration = nil
        modeSynchronizedGeneration = nil
        releaseOutput()
    }

    /// The link on which RootTabView has resolved the board to Control mode
    /// and switched to this tab. Until then the preview does not follow the
    /// board: the mode is synchronized first, the preview after it.
    private var modeSynchronizedGeneration: UUID?

    func boardModeSynchronized(generation: UUID) {
        modeSynchronizedGeneration = generation
        // Wake a running refresh loop immediately: this is the moment
        // `boardIsInControlMode` can flip true without any status event.
        displayRefreshTrigger?.yield()
    }

    /// An unsaved drawing never follows the user to another board: when a
    /// different board becomes current, the editor starts over as if never
    /// touched, so that board's display can populate it (user decision,
    /// 2026-09-13). Reconnecting to the same board keeps the draft, and a
    /// draft drawn before any board was seen belongs to the first one.
    func boardDidChange(to boardID: String) {
        guard draftBoardID != boardID else { return }
        guard draftBoardID != nil else {
            draftBoardID = boardID
            if userHasEdited { scheduleDraftSave() }
            return
        }
        discardDraft(newBoardID: boardID)
    }

    /// Board-group control fan-out addendum: when `GroupControlFanOut`
    /// auto-promotes a group's control primary to the next online member
    /// (the old primary disconnected), the new primary is a genuinely
    /// different physical board — but the user decision behind this promotion
    /// is that it must not discard the in-progress Faces draft the way an
    /// ordinary board switch does. Called *before* `BoardSessionStore.select`
    /// so that the next `boardDidChange(to:)` this promotion triggers (via
    /// `BoardSyncCoordinator`) sees `draftBoardID` already matching and is a
    /// no-op, instead of retagging the draft directly here (which would race
    /// a concurrent user edit changing `draftBoardID` first).
    func retagDraftForGroupPromotion(to boardID: String) {
        guard draftBoardID != nil, draftBoardID != boardID else { return }
        draftBoardID = boardID
    }

    private func discardDraft(newBoardID: String) {
        releaseOutput()
        let fresh = library?.compose(call: .defaultCall) ?? PackedFrame()
        draftBoardID = newBoardID
        selectedCall = .defaultCall
        fromParts = library != nil
        draftFrame = fresh
        lastSentFrame = fresh
        saveName = "parts_face"
        userHasEdited = false
        editingFaceId = nil
        editingLocation = .local
        editingBoardID = nil
        editingBoardGeneration = nil
        editingFaceCanOverwrite = false
        sentGeneration = nil
        errorMessage = nil
        resetUndoHistory()
        // The assignments above scheduled a save of the blank editor; a
        // relaunch must find no draft at all, not an "edited" empty one.
        draftSaveTask?.cancel()
        draftSaveTask = nil
        let storage = draftStorage
        Task { [weak self] in
            do {
                try await storage.remove("face")
            } catch {
                // Never leave the old board's drawing on disk: overwrite it
                // with the blank editor instead.
                await self?.persistDraft()
            }
        }
    }

    /// Checked right before anything is sent, so an edit in the moment
    /// between a board switch and `RootTabView`'s synchronization cannot
    /// carry the old board's drawing to the new one.
    private func draftBelongs(to connection: BoardConnection) -> Bool {
        guard let key = connection.boardKey else { return true }
        let owner = draftBoardID
        boardDidChange(to: key)
        return owner == nil || owner == key
    }
    func wasSent(in connection: BoardConnection) -> Bool {
        sentGeneration == connection.connectionGeneration && !hasUnsentChanges
    }

    func loadForEditing(_ request: FaceEditRequest) {
        loadForEditing(request.face)
        editingLocation = request.location
        editingBoardID = request.boardID
        editingBoardGeneration = request.boardGeneration
        if request.location != .board || request.asCopy {
            editingFaceCanOverwrite = false
        }
        scheduleDraftSave()
    }
    var saveName = "parts_face" { didSet { scheduleDraftSave() } }

    var errorMessage: String?
    var isSending = false
    /// A brief secondary caption shown once `send(connection:)`'s awaited
    /// `setFrame` call has actually returned success — never set on enqueue,
    /// and never set by the live-preview coalesced sender. Cleared a few
    /// seconds later so it never lingers as stale chrome.
    var sendConfirmationMessage: String?
    @ObservationIgnored private var sendConfirmationClearTask: Task<Void, Never>?

    // MARK: Resources

    let library: PartsLibrary?
    let loadError: String?
    private let draftStorage: DraftStorage

    var canSyncEyes: Bool { library != nil }

    init(bundle: Bundle = .main, draftStorage: DraftStorage = .shared) {
        self.draftStorage = draftStorage
        do {
            let library = try RinaResources.partsLibrary(bundle: bundle)
            self.library = library
            self.loadError = nil
            self.selectedCall = .defaultCall
            self.draftFrame = library.compose(call: .defaultCall)
            self.fromParts = true
        } catch {
            self.library = nil
            self.loadError = String(format: NSLocalizedString("无法加载部件库：%@", comment: "parts library load failed"),
                                    error.localizedDescription)
        }
        lastSentFrame = draftFrame
        liveSender = LatestValueSender(minInterval: 0) { [weak self] submission in
            await self?.sendLive(submission)
        }
        hintSender = LatestValueSender(minInterval: 0) { [weak self] submission in
            await self?.sendHint(submission)
        }
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
        clearSendConfirmation()
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
        clearSendConfirmation()
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

    /// Turns eye-part mirroring on or off. Enabling it on a parts-composed
    /// draft selects the part mirrored from the **left** eye for the right
    /// one immediately, so the two are never left mismatched.
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
        }
    }

    /// The LED mirrored across the face's vertical centre line, or nil when
    /// `led` lies on it. Every row is centred with an even length, so the
    /// mirrored position always exists.
    private func drawingMirror(of led: Int) -> Int? {
        guard mirrorDrawing, let position = MatrixGeometry.xy(ofLed: led),
              let mirrored = MatrixGeometry.ledIndex(x: MatrixGeometry.cols - 1 - position.x, y: position.y),
              mirrored != led else { return nil }
        return mirrored
    }

    // MARK: Direct LED editing (§16)

    /// A tap: flips one physically valid LED, whatever the brush is set to.
    /// Invalid positions never reach here — hit testing rejects them (§17).
    func toggle(led: Int, connection: BoardConnection) {
        recordEdit(snapshot)
        userHasEdited = true
        draftFrame.toggle(led)
        if let mirrored = drawingMirror(of: led) {
            // Mirror the resulting *state*, not another toggle, so repeated
            // edits can't desynchronise the two halves.
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
        // the centre line can't desynchronise the two halves.
        let mirrored = drawingMirror(of: led)
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
        guard draftBelongs(to: connection) else { return }
        clearSendConfirmation()
        isSending = true
        defer { isSending = false }
        let frame = draftFrame
        let owner = draftBoardID
        let token = connection.output.begin(.manual)
        do {
            _ = try await connection.setFrame(frame, playback: .idle, reason: "custom_face_send", outputSession: token)
            // A board switch during the send discarded this draft.
            guard draftBoardID == owner else { return }
            lastSentFrame = frame
            sentGeneration = connection.connectionGeneration
            errorMessage = nil
            showSendConfirmation()
        } catch is CancellationError {
        } catch {
            errorMessage = String(format: NSLocalizedString("发送失败：%@", comment: "frame send failed"),
                                  error.localizedDescription)
        }
    }

    /// The caption only describes the send that just succeeded: any edit,
    /// a new send attempt or a connection change retires it at once.
    private func clearSendConfirmation() {
        sendConfirmationClearTask?.cancel()
        sendConfirmationClearTask = nil
        sendConfirmationMessage = nil
    }

    private func showSendConfirmation() {
        sendConfirmationMessage = NSLocalizedString("表情已发送", comment: "secondary caption shown once the board confirms a face send")
        sendConfirmationClearTask?.cancel()
        sendConfirmationClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.sendConfirmationMessage = nil
        }
    }

    private func pushLiveIfNeeded(connection: BoardConnection) {
        guard livePreview, connection.connectionState == .connected,
              draftBelongs(to: connection) else { return }
        let frame = draftFrame
        let owner = draftBoardID
        let token = connection.output.claim(.manual)
        liveSender?.submit(LiveFrameSubmission(frame: frame, owner: owner, token: token,
                                               generation: connection.connectionGeneration,
                                               connection: connection))
    }

    /// Drains one coalesced live edit. Re-validates everything at send time —
    /// the connection, its generation, the output token and the draft's
    /// owner — because an in-flight send is never cancelled by a newer edit
    /// and time may have passed since `pushLiveIfNeeded` captured this value.
    private func sendLive(_ s: LiveFrameSubmission) async {
        let connection = s.connection
        guard connection.connectionState == .connected,
              connection.connectionGeneration == s.generation,
              connection.output.isCurrent(s.token),
              draftBoardID == s.owner else { return }
        let signpostState = RinaPerf.signposter.beginInterval("ControlLiveSend")
        defer { RinaPerf.signposter.endInterval("ControlLiveSend", signpostState) }
        do {
            _ = try await connection.setFrame(s.frame, playback: .idle, reason: "custom_live_send", outputSession: s.token)
            guard draftBoardID == s.owner, connection.connectionGeneration == s.generation else { return }
            lastSentFrame = s.frame
            sentGeneration = connection.connectionGeneration
            errorMessage = nil
        } catch is CancellationError {
        } catch RatePumpError.dropped {
            // Evicted from the frame pump by other traffic; `hasUnsentChanges`
            // stays true, and the next edit or Send resends the draft.
        } catch {
            errorMessage = String(
                format: NSLocalizedString("实时同步失败：%@", comment: "live face sync failed"),
                error.localizedDescription
            )
        }
    }

    // MARK: Apple Pencil hover

    /// The LED to hover with `led` while drawing is mirrored — the one an
    /// edit there would also change.
    func pencilHoverMirror(of led: Int) -> Int? {
        drawingMirror(of: led)
    }

    /// The LED an Apple Pencil hovers over on the editor, or `nil` once it
    /// hovers over none. The preview already draws it at half brightness; with
    /// 即时预览 on, the board shows the same LED at half brightness too (and
    /// its partner, while the eyes are edited as a pair), and loses it the
    /// moment the pencil leaves.
    func pencilHover(led: Int?, connection: BoardConnection) {
        hoveredLED = led
        syncBoardHint(connection: connection)
    }

    /// Re-decides what the board should show for the current hover. Called on
    /// every hover change, and by the editor whenever 即时预览, the board's
    /// output owner or the active board changes, so a pencil held still never
    /// leaves a stale hint behind.
    func syncBoardHint(connection: BoardConnection) {
        let generation = connection.connectionGeneration
        // The hint lives on another board (or an earlier link to this one):
        // put that one out explicitly — the coalescing sender below serves the
        // current board only, and could drop a clear queued behind it.
        if boardHintConnection !== connection || boardHintGeneration != generation {
            if let previous = boardHintConnection, let previousGeneration = boardHintGeneration,
               boardHintLED != nil || boardHintUncertain,
               previous.connectionState == .connected, previous.connectionGeneration == previousGeneration,
               !hintUnsupportedGenerations.contains(previousGeneration) {
                Task { _ = try? await previous.command(.setHintLED(led: nil)) }
            }
            boardHintConnection = connection
            boardHintGeneration = generation
            // A new link starts clear: the board drops a hint with its client.
            boardHintLED = nil
            boardHintUncertain = false
        }

        var target = hoveredLED.map { HintTarget(led: $0, mirror: pencilHoverMirror(of: $0)) }
        if target != nil, !(livePreview
                            && connection.connectionState == .connected
                            && draftBelongs(to: connection)
                            // Not over another feature's output (a scroll, a
                            // performance) that the board is showing instead.
                            && (connection.output.source ?? .manual) == .manual) {
            target = nil
        }
        guard !hintUnsupportedGenerations.contains(generation),
              connection.connectionState == .connected,
              target != boardHintLED || boardHintUncertain else { return }
        boardHintLED = target
        boardHintUncertain = false
        hintSender?.submit(HintSubmission(target: target, generation: generation, connection: connection))
    }

    private func sendHint(_ s: HintSubmission) async {
        let connection = s.connection
        guard connection.connectionState == .connected,
              connection.connectionGeneration == s.generation,
              !hintUnsupportedGenerations.contains(s.generation) else { return }
        do {
            _ = try await connection.command(.setHintLED(led: s.target?.led, mirror: s.target?.mirror))
        } catch let error as RinaLinkError where error.code == 400 && error.error.hasPrefix("unknown command") {
            // Firmware without the hint LED: it lit nothing, and the hover is
            // a courtesy never worth an alert. Stop asking this link.
            hintUnsupportedGenerations.insert(s.generation)
            if boardHintGeneration == s.generation { boardHintLED = nil }
        } catch {
            // Timed out or lost on the way: the board may or may not show it.
            // Leave the record alone and make the next change go out anyway.
            if boardHintGeneration == s.generation { boardHintUncertain = true }
        }
    }

    // MARK: Saves hand-off (§11)

    func upsertPayload(using library: FaceLibraryModel) -> FaceUpsertPayload {
        // A newly-created face belongs to the board that is current now. An
        // existing face keeps its original source so `save` can reject a
        // different board instead of overwriting a coincidentally equal id.
        if editingFaceId == nil {
            editingBoardID = draftBoardID
            editingBoardGeneration = currentBoardGeneration
        }
        return library.boardUpsertPayload(editingFaceId: editingFaceId,
                                          canOverwrite: editingFaceCanOverwrite,
                                          name: saveName, frame: draftFrame,
                                          fromParts: fromParts, call: selectedCall)
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
        editingLocation = .board
        editingBoardID = draftBoardID
        editingBoardGeneration = currentBoardGeneration
        editingFaceCanOverwrite = face.type != .default
            && face.locked != true
            && face.editable != false
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
        editingBoardID = nil
        editingBoardGeneration = nil
        editingFaceCanOverwrite = false
        saveName = "parts_face"
    }

    /// After a successful library save, keep tracking whatever id the board
    /// assigned. The undo history survives: saving is not an edit.
    ///
    /// Deliberately does **not** touch `lastSentFrame`: saving a face to the
    /// board's library is a different operation from transmitting the frame to
    /// the board's display, so a save must never clear the "unsent" badge on a
    /// frame that was never sent (§37).
    func didSave(as id: String?, on destination: BoardFaceSaveSource) {
        if let id {
            editingFaceId = id
            editingLocation = .board
            editingBoardID = destination.boardID
            editingBoardGeneration = destination.generation
            editingFaceCanOverwrite = true
        }
    }

    // MARK: Board display synchronization

    /// A local edit or output handoff during the read makes that response
    /// obsolete — see the guards below and `adoptBoardFrameIfUntouched`.
    ///
    /// This preview only mirrors a board in Control mode. Text, lip-sync,
    /// performance and video frames belong to their own tabs' previews.
    ///
    /// Runs inline in the caller's own task — never wrapped in a detached
    /// `Task {}` — so cancelling that caller (e.g. `.task(id:)` tearing down
    /// when the app backgrounds) cancels the wire request the normal way,
    /// and the post-fetch guard below still runs: a reply that lands after
    /// teardown is ignored rather than clobbering the draft.
    ///
    /// Deliberately *not* single-flighted across callers: the event-driven
    /// loop, the legacy poll, and `BoardSyncCoordinator`'s direct call each
    /// call this independently, with no coordination between them. The loop
    /// serialises its own fetches (one `AsyncStream` consumer that awaits
    /// each fetch before pulling the next trigger, coalescing a burst via
    /// `.bufferingNewest(1)` — see `runEventDrivenDisplayRefreshLoop`) and
    /// the legacy poll runs in that same task before the loop ever starts
    /// (see `runDisplayRefreshLoop`), so neither can race itself or the
    /// other. A loop fetch racing `BoardSyncCoordinator`'s direct call is the
    /// same harmless overlap the pre-PR-12 200 ms poll always allowed: a
    /// redundant or stale `getFrame()` lands as a no-op rather than a
    /// correctness risk (see the stale-adopt window note on
    /// `runEventDrivenDisplayRefreshLoop`).
    func refreshBoardDisplay(connection: BoardConnection) async {
        guard connection.connectionState == .connected, !hasUnsentChanges, !isSending,
              boardIsInControlMode(connection) else { return }
        let before = snapshot
        do {
            let frame = try await connection.getFrame()
            guard !Task.isCancelled, snapshot == before, !hasUnsentChanges, !isSending,
                  boardIsInControlMode(connection) else { return }
            adoptBoardFrameIfUntouched(frame)
        } catch {
            // A missed preview sample is retried by the next polling tick.
        }
    }

    private func boardIsInControlMode(_ connection: BoardConnection) -> Bool {
        guard modeSynchronizedGeneration == connection.connectionGeneration,
              let status = connection.status else { return false }
        return BoardResumeMode.resolve(status: status, preview: connection.preview) == .control
    }

    // MARK: Event-driven refresh (perf PR-12)
    //
    // Firmware broadcasts EV_STATUS with a bumped `v`/`version` to every
    // connected client (including the sender) whenever the board's display
    // changes in Control mode, so a status-version change is treated as "the
    // frame is stale, fetch it" instead of polling on a fixed clock. A 1 Hz
    // reconciliation tick is kept as a fallback for anything that changes the
    // board without a version bump reaching us, and older firmware that never
    // reports a version keeps the previous 200 ms poll verbatim.

    /// Injectable timings so tests can shrink the reconciliation interval
    /// instead of waiting on real wall-clock seconds. Production code never
    /// overrides this.
    struct RefreshTiming {
        var reconciliationInterval: Duration = .seconds(1)
        var legacyPollInterval: Duration = .milliseconds(200)
    }

    // `refreshTiming` is an internal mutable seam whose only consumer is the
    // test suite; it is not mutated in production, so it is not writable (or
    // visible to `@testable` mutation) outside DEBUG builds.
    #if DEBUG
    @ObservationIgnored var refreshTiming = RefreshTiming()
    #else
    @ObservationIgnored private let refreshTiming = RefreshTiming()
    #endif
    /// Set while the event-driven loop below is running, so an out-of-band
    /// mode flip (`boardModeSynchronized`) can wake it immediately instead of
    /// waiting for the next version bump or reconciliation tick. Guarded by
    /// `displayRefreshRunToken` so a loop that is cancelled and unwinding
    /// (e.g. `.task(id:)` restarting) can never clear a newer loop's trigger.
    @ObservationIgnored private var displayRefreshTrigger: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var displayRefreshRunToken: UUID?

    private static func statusVersion(_ connection: BoardConnection) -> Int? {
        connection.status?.v ?? connection.status?.version
    }

    /// Drives `refreshBoardDisplay(connection:)` for as long as the caller
    /// keeps awaiting it (§lifetime unchanged: `ControlView` only awaits this
    /// while connected and the scene is active, and cancels it otherwise).
    ///
    /// A board whose status has no version yet (the setup GET_STATUS read
    /// timed out, or genuinely old firmware) polls every `legacyPollInterval`
    /// until either a version appears — at which point this switches to the
    /// event-driven loop below without ever running both at once — or the
    /// caller cancels.
    func runDisplayRefreshLoop(connection: BoardConnection) async {
        if Self.statusVersion(connection) == nil {
            guard await legacyPollUntilVersionAppears(connection: connection) else { return }
        }
        await runEventDrivenDisplayRefreshLoop(connection: connection)
    }

    /// Polls at `legacyPollInterval` while the board's status carries no
    /// version. Returns `true` the moment a version appears (so the caller
    /// can switch to the event-driven loop), or `false` if cancelled first.
    private func legacyPollUntilVersionAppears(connection: BoardConnection) async -> Bool {
        while !Task.isCancelled {
            if Self.statusVersion(connection) != nil { return true }
            await refreshBoardDisplay(connection: connection)
            do { try await Task.sleep(for: refreshTiming.legacyPollInterval) }
            catch { return false }
        }
        return false
    }

    /// Replaces the fixed 200 ms poll with an event-driven refresh: a status
    /// version change or a control-mode transition triggers an immediate
    /// fetch, backed by a 1 Hz reconciliation fallback and one fetch right on
    /// entry. This loop serialises itself — the consumer below awaits each
    /// `refreshBoardDisplay` before pulling the next trigger — and the
    /// trigger channel's `.bufferingNewest(1)` policy coalesces a burst that
    /// arrives while a fetch is in flight into exactly one more fetch
    /// afterward. It does not coordinate with other callers of
    /// `refreshBoardDisplay` (e.g. `BoardSyncCoordinator`'s direct call); see
    /// that function's doc comment for why.
    ///
    /// That lack of coordination widens (but does not introduce) a stale-adopt
    /// window: draft mirrors `F0`; this loop issues a fetch that will read
    /// `F1`; the board flips back to `F0`; `BoardSyncCoordinator`'s fetch
    /// reads that `F0` and lands first as a same-frame no-op, so `snapshot ==
    /// before` still holds when this loop's fetch lands with the now-stale
    /// `F1`, and it gets adopted. Pre-PR-12, the 200 ms poll made the same
    /// race self-heal within ≤200 ms; the 1 Hz reconciliation tick now heals
    /// it within ≤1 s instead — still comfortably inside INV-4's 3 s
    /// convergence budget (`docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md`). It can
    /// never touch undo history or `editingFaceId`, because every path that
    /// would (a real edit, a save, loading a face) sets `userHasEdited` first,
    /// and `adoptBoardFrameIfUntouched` refuses once that's set. This is
    /// accepted, expected behavior — not a bug to rediscover.
    private func runEventDrivenDisplayRefreshLoop(connection: BoardConnection) async {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        displayRefreshRunToken = token
        displayRefreshTrigger = continuation
        defer {
            // Only retract this run's own trigger: a `.task(id:)` restart can
            // start a newer run before this one finishes unwinding.
            if displayRefreshRunToken == token {
                displayRefreshRunToken = nil
                displayRefreshTrigger = nil
            }
            continuation.finish()
        }
        continuation.yield() // immediate refresh on entry (page appear / connect / active / mode sync)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                var lastVersion = Self.statusVersion(connection)
                var wasInControlMode = self.boardIsInControlMode(connection)
                for await event in connection.events() {
                    if Task.isCancelled { return }
                    guard case .status = event else { continue }
                    let currentVersion = Self.statusVersion(connection)
                    let isInControlMode = self.boardIsInControlMode(connection)
                    if currentVersion != lastVersion || (isInControlMode && !wasInControlMode) {
                        continuation.yield()
                    }
                    lastVersion = currentVersion
                    wasInControlMode = isInControlMode
                }
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: self.refreshTiming.reconciliationInterval) }
                    catch { return }
                    continuation.yield()
                }
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                for await _ in stream {
                    if Task.isCancelled { return }
                    await self.refreshBoardDisplay(connection: connection)
                }
            }
        }
    }

    /// Populate only a never-edited editor from the board. A restored or sent
    /// draft remains user-owned even when it has no unsent changes: the board
    /// may be showing text, automatic faces, or another producer's frame.
    func adoptBoardFrameIfUntouched(_ frame: PackedFrame) {
        guard !userHasEdited, !hasUnsentChanges else { return }
        let changed = draftFrame != frame
        if changed {
            draftFrame = frame
            lastSentFrame = frame
            editingFaceId = nil
            editingBoardID = nil
            editingBoardGeneration = nil
            editingFaceCanOverwrite = false
            sentGeneration = nil
            resetUndoHistory()
        }
        if !fromParts || library?.compose(call: selectedCall) != frame {
            if let call = library?.matchingCall(for: frame) {
                selectedCall = call
                fromParts = true
            } else {
                fromParts = false
            }
        }
    }
}
