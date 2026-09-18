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
public final class GroupAutoCycler {
    private let fanOut: GroupControlFanOut
    private let faceLibrary: FaceLibraryModel
    private let intervalProvider: () -> Double
    private let sleeper: (Double) async -> Void

    public private(set) var isRunning = false
    /// The user's own "auto should be on" intent, independent of `isRunning`:
    /// stays true across an app-backgrounding pause (`suspendForBackground()`
    /// stops the loop but leaves this set, so `resumeForForeground()` restarts
    /// it), and is cleared by every real stop condition (`stop()`, target →
    /// single, another source claiming the primary).
    public private(set) var wantsRunning = false
    private(set) var currentIndex = 0

    private var runToken = 0
    private var task: Task<Void, Never>?
    private var observedConnection: BoardConnection?

    public init(
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
    }

    // MARK: - Start / stop

    /// Turns synced auto cycling on. No-op if there is no current primary
    /// (target isn't a group, or every member is offline) — the caller
    /// should fall back to ordinary single-board auto in that case.
    @discardableResult
    public func start() -> Bool {
        wantsRunning = true
        return beginIfPossible()
    }

    /// Turns synced auto cycling off — a real stop, not the background pause:
    /// clears `wantsRunning`, so a later foreground doesn't resume it.
    public func stop() {
        wantsRunning = false
        endLoop()
    }

    /// Prev/next while a group is targeted: steps the shared index and sends
    /// that frame via the primary (mirrored to every sink), whether or not
    /// the cycle is currently running, so the boards stay identical either
    /// way. Does not itself start or stop the timer loop.
    public func step(direction: Int) async {
        guard let connection = fanOut.primaryConnection else { return }
        let faces = faceLibrary.faces(in: .board)
        guard !faces.isEmpty else { return }
        currentIndex = ((currentIndex + direction) % faces.count + faces.count) % faces.count
        await sendCurrentFace(faces: faces, connection: connection)
        if isRunning {
            // Restart the sleep window from now, so a manual step doesn't
            // leave a short remainder before the next automatic tick.
            restartLoop(connection: connection)
        }
    }

    /// App-lifecycle pause (BOARD_GROUP_SPEC's "app backgrounded" stop
    /// condition): stops the loop but keeps `wantsRunning`, so
    /// `resumeForForeground()` restarts it if it's still the group's target.
    public func suspendForBackground() {
        guard isRunning else { return }
        endLoop(clearWantsRunning: false)
    }

    /// Resumes after `suspendForBackground()`, only if the user's auto
    /// intent is still on.
    public func resumeForForeground() {
        guard wantsRunning, !isRunning else { return }
        _ = beginIfPossible()
    }

    // MARK: - Loop

    @discardableResult
    private func beginIfPossible() -> Bool {
        guard wantsRunning, !isRunning, let connection = fanOut.primaryConnection else { return false }
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

    private func restartLoop(connection: BoardConnection) {
        runToken += 1
        let myToken = runToken
        task?.cancel()
        let session = connection.output.claim(.automatic)
        task = Task { [weak self] in
            await self?.run(token: myToken, session: session, connection: connection)
        }
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
        observedConnection = nil
    }

    /// The primary changing out from under the cycle (member offline, group
    /// left) is handled by whoever routes the toggle re-checking `isRunning`/
    /// `fanOut.primaryID` — see `BoardControlCenterModel`/the views. This
    /// loop itself simply stops once it notices its primary is no longer
    /// current, rather than silently sending to a stale connection.
    private func run(token: Int, session: UUID, connection: BoardConnection) async {
        while runToken == token, !Task.isCancelled {
            guard fanOut.primaryConnection === connection, connection.output.isCurrent(session) else {
                await MainActor.run { self.endLoop() }
                return
            }
            let faces = faceLibrary.faces(in: .board)
            if !faces.isEmpty {
                await sendCurrentFace(faces: faces, connection: connection, session: session)
                currentIndex += 1
            }
            await sleeper(max(0.05, intervalProvider()))
        }
    }

    private func sendCurrentFace(faces: [SavedFace], connection: BoardConnection, session: UUID? = nil) async {
        guard faces.indices.contains(currentIndex % faces.count) else { return }
        let face = faces[currentIndex % faces.count]
        let frame = PackedFrame(bytes: face.frameBytes.map(UInt8.init))
        let token = session ?? connection.output.claim(.automatic)
        _ = try? await connection.withOutput(token) {
            try await connection.setFrame(frame, playback: .idle, reason: "group_auto_cycle", outputSession: token)
        }
    }
}
