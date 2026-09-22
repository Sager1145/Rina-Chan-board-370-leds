import Foundation
import RinaCore

/// Drives synchronized auto face cycling for a board group's control target
/// (user requirement: "自动轮播表情必须同步"). Firmware `auto` mode is
/// per-board free-running, so two boards cannot be trusted to land on the
/// same saved face at the same moment; while a group is the control target,
/// turning "自动" on must not send `set_mode auto` to any board. Instead the
/// phone keeps every member in `manual` mode and this type steps through the
/// primary's saved-face list on its own timer, sending each frame via the
/// primary's `setFrame` — `GroupControlFanOut.dispatchFrame` already mirrors
/// that call to every sink, so all boards change on the same tick.
///
/// Ordering matches the firmware's own auto-cycle order exactly: every saved
/// face (defaults included) sorted by `order` ascending, ties by JSON index
/// — see `esp32s3_firmware/src/storage.cpp`'s `loadSavedFaces`, mirrored on
/// this side by `FaceLibraryModel.faces(in:)` (`FaceDocument.sortedFaces`).
///
/// Stops itself (via `BoardPlaybackCoordinator.register(.automatic:)`) the
/// instant any other output source claims the primary's lease — a manual
/// face/frame send, Live/lip sync/video, or the Text tab — so it never fights
/// another feature for the board. `isRunning` is the single source of truth
/// a group-mode UI should read for "auto" state, since the primary's own
/// firmware `renderer.mode` never leaves `manual` while this runs.
@Observable
@MainActor
final class GroupAutoCycler {
    private let fanOut: GroupControlFanOut
    private let faceLibrary: FaceLibraryModel
    private let intervalProvider: () -> Double
    private let sleeper: (Double) async -> Void

    private(set) var isRunning = false
    /// The user's own "auto should be on" intent, independent of `isRunning`:
    /// stays true across an app-backgrounding pause (`suspendForBackground()`
    /// stops the loop but leaves this set, so `resumeForForeground()` restarts
    /// it), and is cleared by every real stop condition (`stop()`, target →
    /// single, another source claiming the primary).
    private(set) var wantsRunning = false
    private(set) var currentIndex = 0

    /// Identifies the output ownership registration. It changes only when a
    /// cycle starts or ends; resetting the timer must not invalidate the stop
    /// handler registered for this ownership.
    private var ownershipRunID = 0
    /// Identifies the current timer task. Manual stepping bumps this without
    /// claiming a new output lease.
    private var timerRevision = 0
    private var task: Task<Void, Never>?
    private var observedConnection: BoardConnection?
    private var outputSession: UUID?
    /// Stable identity of the last face whose send actually completed while
    /// this cycle still owned the board.
    private var displayedFaceID: String?

    init(
        fanOut: GroupControlFanOut,
        faceLibrary: FaceLibraryModel,
        intervalProvider: @escaping () -> Double,
        sleeper: @escaping (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.fanOut = fanOut
        self.faceLibrary = faceLibrary
        self.intervalProvider = intervalProvider
        self.sleeper = sleeper
        observePrimary()
    }

    // MARK: - Start / stop

    /// Turns synced auto cycling on. No-op — and leaves `wantsRunning`
    /// `false` — if there is no current primary (target isn't a group, or
    /// every member is offline): a caller must read the `false` return (or a
    /// transient message) rather than assume this silently queues itself to
    /// start once a primary later appears (H2) — the caller should fall back
    /// to ordinary single-board auto in that case.
    @discardableResult
    func start() -> Bool {
        let began = beginIfPossible()
        if began { wantsRunning = true }
        return began
    }

    /// Turns synced auto cycling off — a real stop, not the background pause:
    /// clears `wantsRunning`, so a later foreground doesn't resume it.
    func stop() {
        wantsRunning = false
        endLoop()
    }

    /// Prev/next while a group is targeted: steps the shared index and sends
    /// that frame via the primary (mirrored to every sink), whether or not
    /// the cycle is currently running, so the boards stay identical either
    /// way. Does not itself start or stop the timer loop.
    func step(direction: Int) async {
        guard let connection = fanOut.primaryConnection else { return }
        let faces = faceLibrary.faces(in: .board)
        guard !faces.isEmpty else { return }
        if isRunning {
            guard let session = outputSession else { return }
            let runID = ownershipRunID
            // Stop the current timer before the step suspends. Otherwise a
            // scheduled tick can wake and race this manual send.
            timerRevision += 1
            let stepRevision = timerRevision
            task?.cancel()
            task = nil
            let generation = connection.connectionGeneration
            let candidate = steppedIndex(in: faces, direction: direction)
            guard await sendFace(
                faces[candidate],
                connection: connection,
                session: session,
                generation: generation
            ) else {
                if ownershipRunID == runID,
                   timerRevision == stepRevision,
                   isRunning {
                    endLoop()
                }
                return
            }
            // Main-actor reentrancy: every piece of ownership state may have
            // changed while the transport was awaiting its reply.
            guard ownershipRunID == runID,
                  timerRevision == stepRevision,
                  isRunning, wantsRunning,
                  observedConnection === connection,
                  fanOut.primaryConnection === connection,
                  connection.connectionGeneration == generation,
                  connection.output.isCurrent(session) else { return }
            confirmDisplayed(faces[candidate], at: candidate)
            // Restart the sleep window from now, so a manual step doesn't
            // leave a short remainder before the next automatic tick; the
            // fresh loop must not re-send the face above
            // already delivered (L1).
            restartTimer(connection: connection, session: session, runID: runID)
        } else {
            // L3: not running — this is an ordinary manual face send, not an
            // auto-cycle tick, so it must not claim the `.automatic` output
            // source (which would misreport the mode row as "auto" and could
            // fight a real auto-cycle start racing in). Goes through the
            // primary's own normal manual send path, which self-claims
            // `.manual` and still mirrors to every sink via
            // `GroupControlFanOut.dispatchFrame`.
            let candidate = steppedIndex(in: faces, direction: direction)
            let face = faces[candidate]
            guard let frame = face.packedFrame else { return }
            let generation = connection.connectionGeneration
            do {
                _ = try await connection.setFrame(frame, playback: .idle, reason: "group_auto_cycle")
                guard fanOut.primaryConnection === connection,
                      connection.connectionGeneration == generation else { return }
                confirmDisplayed(face, at: candidate)
            } catch {
                return
            }
        }
    }

    /// App-lifecycle pause (BOARD_GROUP_SPEC's "app backgrounded" stop
    /// condition): stops the loop but keeps `wantsRunning`, so
    /// `resumeForForeground()` restarts it if it's still the group's target.
    func suspendForBackground() {
        guard isRunning else { return }
        endLoop(clearWantsRunning: false)
    }

    /// Resumes after `suspendForBackground()`, only if the user's auto
    /// intent is still on.
    func resumeForForeground() {
        guard wantsRunning, !isRunning else { return }
        _ = beginIfPossible()
    }

    // MARK: - Primary tracking (M1)

    /// Only ever one observation chain armed at a time — see
    /// `GroupControlFanOut.reconcileEpoch` for the identical pattern this
    /// mirrors.
    private var observeEpoch = 0

    /// Re-arms itself via `withObservationTracking` on `fanOut.primaryID`
    /// (and, transitively, `fanOut.primaryConnection`), so a primary
    /// promotion (the established primary disconnects and
    /// `GroupControlFanOut` adopts the next online member) is noticed the
    /// instant it happens rather than only on this loop's own next tick.
    private func observePrimary() {
        observeEpoch += 1
        let epoch = observeEpoch
        withObservationTracking {
            _ = fanOut.primaryID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, epoch == self.observeEpoch else { return }
                self.handlePrimaryChange()
            }
        }
    }

    /// User decision: the cycler keeps running across a primary promotion —
    /// ends the loop on the stale primary without touching `wantsRunning`
    /// and immediately re-begins on whatever `fanOut.primaryConnection` now
    /// is (nil if the whole group went offline, in which case this simply
    /// stays stopped until a member reconnects and this fires again).
    private func handlePrimaryChange() {
        observePrimary()
        let newConnection = fanOut.primaryConnection
        guard newConnection !== observedConnection else { return }
        if isRunning { endLoop(clearWantsRunning: false) }
        if wantsRunning { _ = beginIfPossible() }
    }

    // MARK: - Loop

    @discardableResult
    private func beginIfPossible() -> Bool {
        guard !isRunning, let connection = fanOut.primaryConnection else { return false }
        isRunning = true
        ownershipRunID += 1
        timerRevision += 1
        let runID = ownershipRunID
        let revision = timerRevision
        observedConnection = connection
        // Fires the moment another source (manual face send, Live, lip sync,
        // video, Text tab…) claims this board's output lease out from under
        // the cycle — the "another output source claims the primary" stop
        // condition.
        connection.output.register(.automatic) { [weak self, weak connection] in
            guard let self, self.ownershipRunID == runID else { return }
            // A disconnect also invalidates the lease (BoardConnection's
            // connectionState didSet), and that is not the user turning auto
            // off: keep the intent so the promoted primary picks it up (M1).
            let lostLink = connection?.connectionState != .connected
            self.endLoop(clearWantsRunning: !lostLink, callerAlreadySuperseded: true)
        }
        let session = connection.output.claim(.automatic)
        outputSession = session
        task = Task { [weak self] in
            await self?.run(runID: runID, timerRevision: revision, session: session, connection: connection)
        }
        return true
    }

    private func restartTimer(connection: BoardConnection, session: UUID, runID: Int) {
        timerRevision += 1
        let revision = timerRevision
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(
                runID: runID,
                timerRevision: revision,
                session: session,
                connection: connection,
                sleepBeforeFirstSend: true
            )
        }
    }

    /// Clears the stop-handler registration this loop's own `.automatic`
    /// source held on `connection` (L3): otherwise a stale closure — keyed
    /// to an ownership run that can never match again once this loop has ended
    /// or moved to a new primary — sits registered on that connection's
    /// `BoardPlaybackCoordinator` indefinitely.
    private func clearStopHandler(on connection: BoardConnection?) {
        connection?.output.register(.automatic) {}
    }

    private func endLoop(clearWantsRunning: Bool = true, callerAlreadySuperseded: Bool = false) {
        guard isRunning else {
            if clearWantsRunning { wantsRunning = false }
            return
        }
        ownershipRunID += 1
        timerRevision += 1
        task?.cancel()
        task = nil
        isRunning = false
        if clearWantsRunning { wantsRunning = false }
        if !callerAlreadySuperseded, let connection = observedConnection, connection.output.source == .automatic {
            connection.output.invalidate()
        }
        clearStopHandler(on: observedConnection)
        observedConnection = nil
        outputSession = nil
    }

    /// A primary promotion is normally caught proactively by
    /// `handlePrimaryChange` (M1); the `fanOut.primaryConnection === connection`
    /// check here is a synchronous safety net for the narrow window before
    /// that observation callback runs. On a mismatch this simply returns
    /// without calling `endLoop` itself — `handlePrimaryChange` (whether it
    /// already ran or runs right after) is solely responsible for the
    /// actual teardown/restart, so `wantsRunning` is never touched by a
    /// promotion that's still in flight. `connection.output.isCurrent(session)`
    /// going false is the genuine "another source claims the primary" stop
    /// condition (normally caught synchronously by the `register(.automatic:)`
    /// handler already); this is likewise just its safety net.
    private func run(
        runID: Int,
        timerRevision revision: Int,
        session: UUID,
        connection: BoardConnection,
        sleepBeforeFirstSend: Bool = false
    ) async {
        var skipSend = sleepBeforeFirstSend
        while ownershipRunID == runID, timerRevision == revision, !Task.isCancelled {
            guard fanOut.primaryConnection === connection else { return }
            guard connection.output.isCurrent(session) else {
                endLoop()
                return
            }
            if skipSend {
                skipSend = false
            } else {
                let faces = faceLibrary.faces(in: .board)
                if !faces.isEmpty {
                    let candidate = automaticCandidateIndex(in: faces)
                    let generation = connection.connectionGeneration
                    guard await sendFace(
                        faces[candidate],
                        connection: connection,
                        session: session,
                        generation: generation
                    ) else {
                        // A timer reset or ownership change deliberately
                        // cancelled this stale send. A genuine failure of the
                        // still-current run must stop the cycle instead of
                        // leaving `isRunning` true with no timer task.
                        if ownershipRunID == runID,
                           timerRevision == revision,
                           isRunning {
                            endLoop()
                        }
                        return
                    }
                    guard ownershipRunID == runID,
                          timerRevision == revision,
                          isRunning, wantsRunning,
                          observedConnection === connection,
                          fanOut.primaryConnection === connection,
                          connection.connectionGeneration == generation,
                          connection.output.isCurrent(session) else { return }
                    confirmDisplayed(faces[candidate], at: candidate)
                }
            }
            await sleeper(max(0.05, intervalProvider()))
        }
    }

    private func sendFace(
        _ face: SavedFace,
        connection: BoardConnection,
        session: UUID,
        generation: UUID
    ) async -> Bool {
        guard let frame = face.packedFrame else { return false }
        do {
            _ = try await connection.withOutput(session) {
                try await connection.setFrame(frame, playback: .idle, reason: "group_auto_cycle", outputSession: session)
            }
            return connection.connectionGeneration == generation && connection.output.isCurrent(session)
        } catch {
            return false
        }
    }

    private func automaticCandidateIndex(in faces: [SavedFace]) -> Int {
        guard let displayedFaceID,
              let displayed = faces.firstIndex(where: { $0.id == displayedFaceID }) else {
            return min(currentIndex, faces.count - 1)
        }
        return (displayed + 1) % faces.count
    }

    private func steppedIndex(in faces: [SavedFace], direction: Int) -> Int {
        if let displayedFaceID {
            if let displayed = faces.firstIndex(where: { $0.id == displayedFaceID }) {
                return ((displayed + direction) % faces.count + faces.count) % faces.count
            }
            // The displayed face was deleted. `currentIndex` now denotes the
            // gap it occupied: next selects the item that shifted into that
            // gap, previous selects the item immediately before it.
            let gap = min(currentIndex, faces.count)
            let candidate = direction >= 0 ? min(gap, faces.count - 1) : gap - 1
            return ((candidate % faces.count) + faces.count) % faces.count
        }
        let initial = min(currentIndex, faces.count - 1)
        return ((initial + direction) % faces.count + faces.count) % faces.count
    }

    private func confirmDisplayed(_ face: SavedFace, at index: Int) {
        displayedFaceID = face.id
        currentIndex = index
    }
}
