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

    private var runToken = 0
    private var task: Task<Void, Never>?
    private var observedConnection: BoardConnection?

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
        currentIndex = ((currentIndex + direction) % faces.count + faces.count) % faces.count
        if isRunning {
            await sendCurrentFace(faces: faces, connection: connection)
            // Restart the sleep window from now, so a manual step doesn't
            // leave a short remainder before the next automatic tick; the
            // fresh loop must not re-send the face `sendCurrentFace` above
            // already delivered (L1).
            restartLoop(connection: connection, sleepBeforeFirstSend: true)
        } else {
            // L3: not running — this is an ordinary manual face send, not an
            // auto-cycle tick, so it must not claim the `.automatic` output
            // source (which would misreport the mode row as "auto" and could
            // fight a real auto-cycle start racing in). Goes through the
            // primary's own normal manual send path, which self-claims
            // `.manual` and still mirrors to every sink via
            // `GroupControlFanOut.dispatchFrame`.
            let face = faces[currentIndex % faces.count]
            guard let frame = PackedFrame(bytes: face.frameBytes.map(UInt8.init)) else { return }
            _ = try? await connection.setFrame(frame, playback: .idle, reason: "group_auto_cycle")
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
        runToken += 1
        let myToken = runToken
        observedConnection = connection
        // Fires the moment another source (manual face send, Live, lip sync,
        // video, Text tab…) claims this board's output lease out from under
        // the cycle — the "another output source claims the primary" stop
        // condition.
        connection.output.register(.automatic) { [weak self] in
            guard let self, self.runToken == myToken else { return }
            self.wantsRunning = false
            self.endLoop(clearWantsRunning: true, callerAlreadySuperseded: true)
        }
        let session = connection.output.claim(.automatic)
        task = Task { [weak self] in
            await self?.run(token: myToken, session: session, connection: connection)
        }
        return true
    }

    private func restartLoop(connection: BoardConnection, sleepBeforeFirstSend: Bool = false) {
        runToken += 1
        let myToken = runToken
        task?.cancel()
        let session = connection.output.claim(.automatic)
        task = Task { [weak self] in
            await self?.run(token: myToken, session: session, connection: connection, sleepBeforeFirstSend: sleepBeforeFirstSend)
        }
    }

    /// Clears the stop-handler registration this loop's own `.automatic`
    /// source held on `connection` (L3): otherwise a stale closure — keyed
    /// to a `runToken` that can never match again once this loop has ended
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
        runToken += 1
        task?.cancel()
        task = nil
        isRunning = false
        if clearWantsRunning { wantsRunning = false }
        if !callerAlreadySuperseded, let connection = observedConnection, connection.output.source == .automatic {
            connection.output.invalidate()
        }
        clearStopHandler(on: observedConnection)
        observedConnection = nil
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
    private func run(token: Int, session: UUID, connection: BoardConnection, sleepBeforeFirstSend: Bool = false) async {
        var skipSend = sleepBeforeFirstSend
        while runToken == token, !Task.isCancelled {
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
                    await sendCurrentFace(faces: faces, connection: connection, session: session)
                    // L1: the send above awaited a network round-trip; only
                    // advance the shared index if this run is still current —
                    // a stale send racing a restart/stop must not skip a face.
                    guard runToken == token else { return }
                    currentIndex += 1
                }
            }
            await sleeper(max(0.05, intervalProvider()))
        }
    }

    private func sendCurrentFace(faces: [SavedFace], connection: BoardConnection, session: UUID? = nil) async {
        guard !faces.isEmpty else { return }
        let face = faces[currentIndex % faces.count]
        guard let frame = PackedFrame(bytes: face.frameBytes.map(UInt8.init)) else { return }
        let token = session ?? connection.output.claim(.automatic)
        _ = try? await connection.withOutput(token) {
            try await connection.setFrame(frame, playback: .idle, reason: "group_auto_cycle", outputSession: token)
        }
    }
}
