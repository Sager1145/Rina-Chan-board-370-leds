import XCTest
@testable import RinaBoard
@testable import RinaCore

@MainActor
final class GroupControlFanOutTests: XCTestCase {
    private struct Harness {
        let sessions: BoardSessionStore
        let store: BoardGroupStore
        let coordinator: BoardGroupCoordinator
        let fanOut: GroupControlFanOut
        let transports: [String: GroupControlFakeTransport]
        let group: BoardGroup
    }

    private func harness(_ memberIDs: [String]) async -> Harness {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "gcf.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)
        var transports: [String: GroupControlFakeTransport] = [:]
        for id in memberIDs {
            let transport = GroupControlFakeTransport()
            transport.wifiBoardId = id
            // Deliberately a BLE-UUID-like session key, distinct from `id`
            // (the firmware identity/`physicalBoardID` a group member is
            // keyed by): a regression that resolves group members by
            // `BoardSession.boardID` (the session's own persistent slot
            // identity) instead of `BoardConnection.boardIdentity` must fail
            // these tests, not pass by both happening to be the same string.
            let sessionKey = "ble:\(UUID().uuidString)"
            let session = sessions.session(for: sessionKey, name: id)
            _ = await session.connection.connect(using: transport)
            transports[id] = transport
        }
        let group = store.create(name: "测试组")
        for id in memberIDs {
            try? store.addMember(groupID: group.id, member: .init(physicalBoardID: id, displayName: id))
        }
        return Harness(sessions: sessions, store: store, coordinator: coordinator, fanOut: fanOut,
                       transports: transports, group: store.groups[0])
    }

    /// Resolves by the live `BoardConnection.boardIdentity` (the firmware
    /// identity, i.e. `physicalBoardID`) rather than `BoardSession.boardID`
    /// (the session's own persistent slot key, which `harness` deliberately
    /// makes a different, BLE-UUID-like string) — see `harness`.
    private func session(_ h: Harness, _ id: String) -> BoardSession {
        h.sessions.sessions.first { $0.connection.boardIdentity == id }!
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 1. Unleased coalesced verbatim reaches every sink

    func testBrightnessReachesEverySinkUnleased() async throws {
        let h = await harness(["AAAA", "BBBB", "CCCC"])
        h.fanOut.setTarget(.group(h.group.id))
        XCTAssertEqual(h.fanOut.primaryID, "AAAA")
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.setBrightness(raw: 77))

        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 77 }
        await waitUntil { h.transports["CCCC"]?.lastCmdField("set_brightness", "raw") as? Int == 77 }
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 77)
        XCTAssertEqual(h.transports["CCCC"]?.lastCmdField("set_brightness", "raw") as? Int, 77)
        // Unleased: never claims the sink's output lease.
        XCTAssertNotEqual(session(h, "BBBB").connection.output.source, .groupControl)
        XCTAssertNotEqual(session(h, "CCCC").connection.output.source, .groupControl)
    }

    // MARK: 1b. Coalescing a queued command moves it to the end, preserving
    // relative order with other still-queued commands (F8).

    func testCoalescedCommandMovesToEndPreservingOrder() async throws {
        let h = await harness(["AAAA", "BBBB"])
        // Deterministically (not via a wall-clock delay a loaded machine
        // could blow through) blocks the sink's worker on set_color's reply
        // until this test explicitly releases it below, once every
        // subsequent send has already been dispatched.
        h.transports["BBBB"]?.holdCmds = ["set_color"]
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")

        // First item: dequeued and sent immediately, blocking the sink's
        // worker on its (held) reply — everything sent while it's in
        // flight piles up in the queue behind it.
        _ = try await primary.connection.command(.setColor(hex: "#111111"))
        // Queued while the worker is still blocked on set_color's reply:
        _ = try await primary.connection.command(.setBrightness(raw: 10))
        _ = try await primary.connection.command(.setAutoInterval(ms: 500))
        // Coalesces with the already-queued setBrightness(10) — must replace
        // it AND move to the end, after setAutoInterval, not keep its old
        // (earlier) position.
        _ = try await primary.connection.command(.setBrightness(raw: 20))

        h.transports["BBBB"]?.releaseHeld("set_color")
        await waitUntil(timeout: 3) { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 20 }
        let names = h.transports["BBBB"]?.receivedCmdNames ?? []
        let colorIdx = names.lastIndex(of: "set_color")
        let intervalIdx = names.lastIndex(of: "set_auto_interval")
        let brightnessIdx = names.lastIndex(of: "set_brightness")
        XCTAssertNotNil(colorIdx); XCTAssertNotNil(intervalIdx); XCTAssertNotNil(brightnessIdx)
        // set_color, then set_auto_interval, then the coalesced set_brightness
        // last — never brightness before the auto-interval it was queued
        // behind at enqueue time.
        XCTAssertLessThan(colorIdx!, intervalIdx!)
        XCTAssertLessThan(intervalIdx!, brightnessIdx!)
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 20)
        // Only ever one set_brightness reached the sink — the earlier
        // queued(10) was replaced, not sent-then-followed-by-20.
        XCTAssertEqual(names.filter { $0 == "set_brightness" }.count, 1)
    }

    // MARK: 2. Deny-list commands never fan out

    func testDenyListCommandReachesOnlyPrimary() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.pauseScroll)
        // Give any accidental fan-out time to arrive before asserting absence.
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(h.transports["AAAA"]?.receivedCmdNames.contains("pause_scroll") == true)
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("pause_scroll") == true)
    }

    // MARK: 3. Slow sink doesn't delay the primary; ends with the latest frame

    func testSlowSinkDoesNotDelayPrimaryAndEndsWithLatestFrame() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["BBBB"]?.frameReplyDelay = 2.0
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")

        let start = Date()
        var lastBytes: [UInt8] = []
        for i in 0..<50 {
            var frame = PackedFrame()
            frame.set(i % PackedFrame.ledCount)
            lastBytes = frame.bytes
            _ = try await primary.connection.setFrame(frame, playback: .idle, reason: "t")
        }
        // The primary's own 50 sends must not have waited on the 2s-slow sink.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        await waitUntil(timeout: 6) { h.transports["BBBB"]?.receivedFrameBytes.last == lastBytes }
        XCTAssertEqual(h.transports["BBBB"]?.receivedFrameBytes.last, lastBytes)
    }

    // MARK: 4. Sink failure doesn't affect the primary; sets memberErrors

    func testSinkFailureRecordsMemberErrorWithoutAffectingPrimary() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["BBBB"]?.failCmds.insert("set_color")
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")

        let reply = try await primary.connection.command(.setColor(hex: "#112233"))
        XCTAssertTrue(reply.ok)

        await waitUntil { h.fanOut.memberErrors["BBBB"] != nil }
        XCTAssertNotNil(h.fanOut.memberErrors["BBBB"])
    }

    // MARK: 5. apply_saved_face resolves to a frame on the sink

    func testApplySavedFaceSendsResolvedFrameToSink() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        var resolved = PackedFrame()
        resolved.set(5)
        h.fanOut.faceFrameResolver = { _, _ in resolved }
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.applySavedFace(index: 2, reason: nil, playback: nil))

        await waitUntil { !(h.transports["BBBB"]?.receivedFrameBytes.isEmpty ?? true) }
        XCTAssertEqual(h.transports["BBBB"]?.receivedFrameBytes.last, resolved.bytes)
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("apply_saved_face") == true)
    }

    // MARK: 5b. No resolver (or a nil resolve): read the primary's own
    // resulting frame back via get_frame and mirror that, never replay
    // apply_saved_face/B1/B2 verbatim (F5).

    func testUnresolvedFaceReadsBackPrimaryFrameInsteadOfReplayingVerbatim() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        // No `faceFrameResolver` wired at all — the common real-world "not
        // wired yet" / "couldn't resolve" case.
        var readBack = PackedFrame()
        readBack.set(9)
        h.transports["AAAA"]?.getFrameReply = readBack
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.applySavedFace(index: 3, reason: nil, playback: nil))

        await waitUntil(timeout: 2) { !(h.transports["BBBB"]?.receivedFrameBytes.isEmpty ?? true) }
        XCTAssertEqual(h.transports["BBBB"]?.receivedFrameBytes.last, readBack.bytes)
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("apply_saved_face") == true)
    }

    // MARK: 5c. Read-back also failing records a per-sink error instead of
    // guessing (F5).

    func testUnresolvedFaceReadBackFailureRecordsMemberError() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        h.transports["AAAA"]?.failGetFrame = true
        let primary = session(h, "AAAA")

        _ = try await primary.connection.command(.applySavedFace(index: 4, reason: nil, playback: nil))

        await waitUntil(timeout: 2) { h.fanOut.memberErrors["BBBB"] != nil }
        XCTAssertNotNil(h.fanOut.memberErrors["BBBB"])
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("apply_saved_face") == true)
    }

    // MARK: 6. A face during group play supersedes the Text-tab playback

    func testFaceDuringGroupPlaySupersedesPlaybackWithoutReanchor() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["AAAA"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.transports["BBBB"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.fanOut.setTarget(.group(h.group.id))

        try await h.coordinator.play(group: h.group, text: "AB", fps: 10, loop: true)
        XCTAssertTrue(h.coordinator.isPlaying)
        let startCountB = h.transports["BBBB"]?.sentGroupStartAtUs.count ?? 0

        let primary = session(h, "AAAA")
        // Reclaim the primary's own output the way a real face-apply does,
        // then send it — this is what steers the primary board itself away
        // from `.group` before `command(_:)` checks `output.source`.
        let token = primary.connection.output.claim(.manual)
        _ = try await primary.connection.withOutput(token) {
            try await primary.connection.command(.applySavedFace(index: 0, reason: nil, playback: nil))
        }

        await waitUntil { h.coordinator.isPlaying == false }
        XCTAssertFalse(h.coordinator.isPlaying)
        #if DEBUG
        await h.coordinator.debugReanchorNow()
        #endif
        XCTAssertEqual(h.transports["BBBB"]?.sentGroupStartAtUs.count, startCountB)
    }

    // MARK: 6b. A control command during group play (source == .group on the
    // primary, unlike test 6's reclaimed-to-.manual face apply) still
    // mirrors to every sink and never ends group play (F2).

    func testControlCommandDuringGroupPlayStillMirrorsAndDoesNotEndPlay() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["AAAA"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.transports["BBBB"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.fanOut.setTarget(.group(h.group.id))

        try await h.coordinator.play(group: h.group, text: "AB", fps: 10, loop: true)
        XCTAssertTrue(h.coordinator.isPlaying)

        let primary = session(h, "AAAA")
        // Deliberately do NOT reclaim the primary's output first — the
        // coordinator holds every member's `output.source == .group` for the
        // whole play, and only ever calls `requestReliable`, never
        // `command(_:)`, itself. A `set_brightness` reaching `command(_:)`
        // here is exactly the real scenario `command(_:)` must still mirror.
        XCTAssertEqual(primary.connection.output.source, .group)
        _ = try await primary.connection.command(.setBrightness(raw: 88))

        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 88 }
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 88)
        XCTAssertTrue(h.coordinator.isPlaying)
    }

    // MARK: 6c. N2: a control command dispatched while the group is paused
    // (not playing) must still supersede it and clear the paused state —
    // `claimAllSinksAndBumpSeq` only checked `isPlaying` before.

    func testControlCommandDuringGroupPauseSupersedesAndClearsPausedState() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.transports["AAAA"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.transports["BBBB"]?.caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
        h.fanOut.setTarget(.group(h.group.id))

        try await h.coordinator.play(group: h.group, text: "AB", fps: 10, loop: true)
        await h.coordinator.pause(group: h.group)
        XCTAssertTrue(h.coordinator.isPaused)
        XCTAssertFalse(h.coordinator.isPlaying)

        let primary = session(h, "AAAA")
        // Same as 6b: the primary's lease is still `.group` while paused —
        // a paused group never releases its participants' output leases.
        XCTAssertEqual(primary.connection.output.source, .group)
        // Brightness is lease-free and, like 6b during play, must NOT end a
        // paused group (firmware B4/B5 don't exit group-timed either).
        _ = try await primary.connection.command(.setBrightness(raw: 42))
        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 42 }
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 42)
        XCTAssertTrue(h.coordinator.isPaused, "a lease-free control keeps the group paused")

        // A frame (e.g. a face send) takes over output on every member, so it
        // must supersede the paused group.
        var frame = PackedFrame()
        frame.set(7)
        _ = try await primary.connection.setFrame(frame, playback: .idle, reason: "t")
        await waitUntil { !h.coordinator.isPaused }
        // N2: the control dispatch must have superseded the paused group —
        // clearing isPaused/pausedFrame, not just isPlaying.
        XCTAssertFalse(h.coordinator.isPaused)
        XCTAssertFalse(h.coordinator.isPlaying)
        XCTAssertEqual(h.coordinator.pausedFrame, 0)
        XCTAssertNil(h.coordinator.activeGroupID)
    }

    // MARK: 7. target -> single invalidates sink leases and clears fanOut

    func testTargetToSingleInvalidatesSinkLeasesAndClearsFanOut() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")
        let sink = session(h, "BBBB")
        _ = try await primary.connection.command(.applySavedFace(index: 0, reason: nil, playback: nil))
        await waitUntil { sink.connection.output.source == .groupControl }
        XCTAssertEqual(sink.connection.output.source, .groupControl)

        h.fanOut.setTarget(.single)

        await waitUntil { sink.connection.output.source != .groupControl }
        XCTAssertNotEqual(sink.connection.output.source, .groupControl)
        XCTAssertNil(primary.connection.fanOut)
    }

    // MARK: 8. Group target with a non-member active selects the first online member

    func testGroupTargetWithNonMemberActiveSelectsFirstOnlineMember() async throws {
        let h = await harness(["AAAA", "BBBB"])
        let outsider = GroupControlFakeTransport()
        outsider.wifiBoardId = "OUTSIDER"
        let outsiderSession = h.sessions.session(for: "OUTSIDER", name: "OUTSIDER")
        _ = await outsiderSession.connection.connect(using: outsider)
        h.sessions.select(outsiderSession)

        h.fanOut.setTarget(.group(h.group.id))

        XCTAssertEqual(h.fanOut.primaryID, "AAAA")
        XCTAssertTrue(h.sessions.active === session(h, "AAAA"))
    }

    // MARK: 9. Sink reconnect gets a fresh channel

    func testSinkReconnectGetsFreshChannel() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let sink = session(h, "BBBB")

        let newTransport = GroupControlFakeTransport()
        newTransport.wifiBoardId = "BBBB"
        sink.connection.disconnect()
        _ = await sink.connection.connect(using: newTransport)
        await waitUntil { sink.connection.connectionState == .connected }

        let primary = session(h, "AAAA")
        _ = try await primary.connection.command(.setBrightness(raw: 55))
        await waitUntil { newTransport.lastCmdField("set_brightness", "raw") as? Int == 55 }
        XCTAssertEqual(newTransport.lastCmdField("set_brightness", "raw") as? Int, 55)
    }

    // MARK: 9b. Removing a sink's session from BoardSessionStore mid-group-
    // control doesn't crash, and tears the channel down (F3: SinkChannel
    // .connection is `weak`, not `unowned`).

    func testRemovingSinkSessionMidGroupControlDoesNotCrash() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")
        let sink = session(h, "BBBB")

        _ = try await primary.connection.command(.setBrightness(raw: 42))
        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 42 }

        guard let sinkKey = sink.boardID else { return XCTFail("sink has no boardID") }
        h.sessions.remove(id: sinkKey)

        // Would trap under the old `unowned` reference if a queued/racing
        // worker touched a deallocated connection; must instead simply drop
        // the sink.
        _ = try await primary.connection.command(.setBrightness(raw: 43))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(h.sessions.sessions.contains { $0 === sink })
        XCTAssertNil(h.fanOut.memberErrors["BBBB"])
    }

    // MARK: 10. Debug output source is not mirrored

    func testDebugOutputSourceIsNotMirrored() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA")
        let token = primary.connection.output.claim(.debug)
        _ = try await primary.connection.withOutput(token) {
            try await primary.connection.command(.setBrightness(raw: 99))
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw"))
    }

    // MARK: 11. Primary disconnect promotes the next online member; draft survives

    func testPrimaryDisconnectPromotesNextMemberAndPreservesDraft() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        XCTAssertEqual(h.fanOut.primaryID, "AAAA")

        let primary = session(h, "AAAA")
        let oldKey = primary.connection.boardKey

        // Wire `draftPromotionHook` to a real `ControlViewModel` the way
        // `RinaBoardApp` does, and give it an in-progress, unsaved edit
        // against the primary the way a user's Faces draft would exist —
        // this is what F10 asks to actually prove survives promotion,
        // instead of only checking the hook fired with the right key.
        let editor = ControlViewModel()
        editor.boardDidChange(to: oldKey ?? "AAAA")
        editor.toggle(led: 0, connection: primary.connection)
        XCTAssertTrue(editor.draftFrame[0])
        let draftBeforePromotion = editor.draftFrame

        h.fanOut.draftPromotionHook = { editor.retagDraftForGroupPromotion(to: $0) }

        primary.connection.disconnect()

        await waitUntil { h.fanOut.primaryID == "BBBB" }
        XCTAssertEqual(h.fanOut.primaryID, "BBBB")
        let newKey = session(h, "BBBB").connection.boardKey
        XCTAssertEqual(editor.draftBoardID, newKey)

        // The ordinary board-switch handling (`BoardSyncCoordinator` calling
        // `boardDidChange(to:)` once `BoardSessionStore.select` completes the
        // promotion) must now be a no-op — `retagDraftForGroupPromotion`
        // already retagged `draftBoardID` to the new primary — so the draft
        // survives instead of being discarded as an ordinary board switch
        // would.
        editor.boardDidChange(to: newKey ?? "BBBB")
        XCTAssertEqual(editor.draftFrame, draftBeforePromotion)
        XCTAssertTrue(editor.draftFrame[0])
    }

    // MARK: 12. H1/F6 — an implicit non-member selection keeps the group as
    // the in-memory target (not `.single`); re-selecting a member re-attaches
    // and mirroring resumes.

    func testNonMemberActiveKeepsGroupTargetThenReattachesOnMemberReturn() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        XCTAssertEqual(h.fanOut.primaryID, "AAAA")

        let outsider = GroupControlFakeTransport()
        outsider.wifiBoardId = "OUTSIDER"
        let outsiderSession = h.sessions.session(for: "OUTSIDER", name: "OUTSIDER")
        _ = await outsiderSession.connection.connect(using: outsider)

        // An implicit non-member selection (e.g. a Settings board switch),
        // not via `setTarget` — must not force the in-memory target back to
        // `.single` (H1).
        h.sessions.select(outsiderSession)
        await waitUntil { h.fanOut.primaryID == nil }
        XCTAssertNil(h.fanOut.primaryID)

        let primary = session(h, "AAAA")
        h.sessions.select(primary)
        await waitUntil { h.fanOut.primaryID == "AAAA" }
        XCTAssertEqual(h.fanOut.primaryID, "AAAA")

        _ = try await primary.connection.command(.setBrightness(raw: 66))
        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 66 }
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 66)
    }

    // MARK: 12b. F6 — a launch-time restore (`isExplicit: false`) with the
    // active board outside the group must not force-select a member either.

    func testLaunchRestoreWithNonMemberActiveDoesNotForceSelect() async throws {
        let h = await harness(["AAAA", "BBBB"])
        let outsider = GroupControlFakeTransport()
        outsider.wifiBoardId = "OUTSIDER"
        let outsiderSession = h.sessions.session(for: "OUTSIDER", name: "OUTSIDER")
        _ = await outsiderSession.connection.connect(using: outsider)
        h.sessions.select(outsiderSession)

        h.fanOut.setTarget(.group(h.group.id), isExplicit: false)

        XCTAssertNil(h.fanOut.primaryID)
    }

    // MARK: 13. F7 — the primary's own apply_saved_face throwing must never
    // claim the sinks' output lease.

    func testPrimaryApplySavedFaceFailureDoesNotClaimSinks() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        h.transports["AAAA"]?.failCmds.insert("apply_saved_face")
        let primary = session(h, "AAAA")
        let sink = session(h, "BBBB")

        do {
            _ = try await primary.connection.command(.applySavedFace(index: 0, reason: nil, playback: nil))
            XCTFail("expected the primary's own apply_saved_face to throw")
        } catch {
            // Expected — the board rejected it.
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotEqual(sink.connection.output.source, .groupControl)
        XCTAssertTrue(h.transports["BBBB"]?.receivedFrameBytes.isEmpty ?? true)
        // `receivedCmdNames` isn't empty on its own — every session's
        // `connect()` issues its own `subscribe` handshake — but it must
        // never contain `apply_saved_face` (the primary's own failed
        // command never got replayed or otherwise reached the sink).
        XCTAssertFalse(h.transports["BBBB"]?.receivedCmdNames.contains("apply_saved_face") == true)
    }

    // MARK: 14. F9 — a nil primary status at attach retries alignment once a
    // real status arrives.

    func testStatusNilAtAttachAlignsOnceStatusArrives() async throws {
        // Built without the shared `harness()` helper so the primary's
        // transport can be made to omit `renderer` from its very first
        // `getStatus` reply — i.e. before `connect()` ever populates
        // `status` — which is what actually leaves `status?.renderer` nil
        // at attach time (setting the flag only after `harness()`'s own
        // `connect()` already ran would be too late).
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "gcf.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)

        let primaryTransport = GroupControlFakeTransport()
        primaryTransport.wifiBoardId = "AAAA"
        primaryTransport.includeRenderer = false
        let primary = sessions.session(for: "ble:\(UUID().uuidString)", name: "AAAA")
        _ = await primary.connection.connect(using: primaryTransport)
        XCTAssertNil(primary.connection.status?.renderer)

        let sinkTransport = GroupControlFakeTransport()
        sinkTransport.wifiBoardId = "BBBB"
        let sink = sessions.session(for: "ble:\(UUID().uuidString)", name: "BBBB")
        _ = await sink.connection.connect(using: sinkTransport)

        let group = store.create(name: "测试组")
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "AAAA"))
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "BBBB", displayName: "BBBB"))
        fanOut.setTarget(.group(group.id))

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(sinkTransport.lastCmdField("set_brightness", "raw"))

        primaryTransport.includeRenderer = true
        primaryTransport.rendererBrightness = 123
        _ = try? await primary.connection.getStatus()

        await waitUntil { sinkTransport.lastCmdField("set_brightness", "raw") as? Int == 123 }
        XCTAssertEqual(sinkTransport.lastCmdField("set_brightness", "raw") as? Int, 123)
    }

    // MARK: 15. M3 — member resolution prefers a CONNECTED session over a
    // stale duplicate that only matches via `lastKnownBoardIdentity`.

    func testMemberResolutionPrefersConnectedSessionOverStaleDuplicate() async throws {
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: UserDefaults(suiteName: "gcf.\(UUID())")!)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)

        // Added to the store FIRST, so a naive `sessions.first(where:)` scan
        // would find this one before the currently-connected one below.
        let staleTransport = GroupControlFakeTransport()
        staleTransport.wifiBoardId = "AAAA"
        let staleSession = sessions.session(for: "ble:\(UUID().uuidString)", name: "AAAA-stale")
        _ = await staleSession.connection.connect(using: staleTransport)
        staleSession.connection.disconnect()
        await waitUntil { staleSession.connection.connectionState == .disconnected }

        let liveTransport = GroupControlFakeTransport()
        liveTransport.wifiBoardId = "AAAA"
        let liveSession = sessions.session(for: "ble:\(UUID().uuidString)", name: "AAAA-live")
        _ = await liveSession.connection.connect(using: liveTransport)

        XCTAssertTrue(sessions.session(matchingGroupMember: "AAAA") === liveSession)

        let group = store.create(name: "测试组")
        try? store.addMember(groupID: group.id, member: .init(physicalBoardID: "AAAA", displayName: "AAAA"))
        fanOut.setTarget(.group(group.id))

        XCTAssertTrue(sessions.active === liveSession)
        XCTAssertEqual(fanOut.primaryID, "AAAA")
    }

    // MARK: 16. R10 — alignment is confirmed per field and retries are bounded.

    func testPartialAlignmentFailureStaysVisibleAndReconnectRealigns() async throws {
        let h = await harness(["AAAA", "BBBB"])
        let primary = session(h, "AAAA")
        let sink = session(h, "BBBB")
        h.transports["AAAA"]?.rendererBrightness = 123
        h.transports["AAAA"]?.rendererColor = "#123456"
        _ = try await primary.connection.getStatus()
        h.transports["BBBB"]?.failCmds.insert("set_brightness")

        h.fanOut.setTarget(.group(h.group.id))

        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_color", "hex") as? String == "#123456" }
        await waitUntil { h.fanOut.memberErrors["BBBB"] != nil }
        await waitUntil { h.transports["BBBB"]?.receivedCmdNames.filter { $0 == "set_brightness" }.count == 3 }
        XCTAssertEqual(h.transports["BBBB"]?.receivedCmdNames.filter { $0 == "set_brightness" }.count, 3)
        XCTAssertNotNil(h.fanOut.memberErrors["BBBB"], "a successful color ACK must not erase the brightness failure")
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(h.transports["BBBB"]?.receivedCmdNames.filter { $0 == "set_brightness" }.count, 3)

        let replacement = GroupControlFakeTransport()
        replacement.wifiBoardId = "BBBB"
        sink.connection.disconnect()
        _ = await sink.connection.connect(using: replacement)

        await waitUntil { replacement.lastCmdField("set_brightness", "raw") as? Int == 123 }
        await waitUntil { replacement.lastCmdField("set_color", "hex") as? String == "#123456" }
        await waitUntil { h.fanOut.memberErrors["BBBB"] == nil }
        XCTAssertNil(h.fanOut.memberErrors["BBBB"])
    }

    // MARK: 17. R23 — queued leased work keeps its original lease snapshot.

    func testQueuedOldLeaseCannotBorrowNewLeaseAfterManualTakeover() async throws {
        let h = await harness(["AAAA", "BBBB"])
        h.fanOut.setTarget(.group(h.group.id))
        let primary = session(h, "AAAA").connection
        let sink = session(h, "BBBB").connection
        h.transports["BBBB"]?.holdCmds.insert("set_color")

        _ = try await primary.command(.setColor(hex: "#111111"))
        let primaryLease = primary.output.claim(.manual)
        _ = try await primary.withOutput(primaryLease) {
            try await primary.command(.button(button: "B3"))
        }

        _ = sink.output.claim(.manual)
        _ = try await primary.withOutput(primaryLease) {
            try await primary.command(.button(button: "B4"))
        }
        h.transports["BBBB"]?.releaseHeld("set_color")

        await waitUntil { h.transports["BBBB"]?.lastCmdField("button", "button") as? String == "B4" }
        XCTAssertEqual(h.transports["BBBB"]?.receivedCmdNames.filter { $0 == "button" }.count, 1)
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("button", "button") as? String, "B4")
    }

    func testNewSettingSupersedesPendingAlignmentRetry() async throws {
        let h = await harness(["AAAA", "BBBB"])
        let primary = session(h, "AAAA").connection
        h.transports["AAAA"]?.rendererBrightness = 123
        _ = try await primary.getStatus()
        h.transports["BBBB"]?.failCmds.insert("set_brightness")
        h.fanOut.setTarget(.group(h.group.id))
        await waitUntil { h.fanOut.memberErrors["BBBB"] != nil }

        h.transports["BBBB"]?.failCmds.remove("set_brightness")
        _ = try await primary.command(.setBrightness(raw: 200))
        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 200 }
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 200)
        XCTAssertNil(h.fanOut.memberErrors["BBBB"])
    }

    func testQueueCapPreservesPendingAlignmentAcknowledgements() async throws {
        let h = await harness(["AAAA", "BBBB"])
        let primary = session(h, "AAAA").connection
        h.transports["AAAA"]?.rendererBrightness = 123
        h.transports["AAAA"]?.rendererColor = "#123456"
        _ = try await primary.getStatus()
        h.transports["BBBB"]?.holdCmds.insert("set_brightness")
        h.fanOut.setTarget(.group(h.group.id))

        await waitUntil { h.transports["BBBB"]?.heldCount("set_brightness") == 1 }
        for _ in 0..<24 {
            h.fanOut.dispatch(.button(button: "B3"), leased: false, from: primary)
        }
        h.transports["BBBB"]?.releaseHeld("set_brightness")

        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_color", "hex") as? String == "#123456" }
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_color", "hex") as? String, "#123456")
        XCTAssertNil(h.fanOut.memberErrors["BBBB"])
    }

    func testOldInFlightAlignmentAckCannotConfirmNewerValue() async throws {
        let h = await harness(["AAAA", "BBBB"])
        let primary = session(h, "AAAA").connection
        h.transports["AAAA"]?.rendererBrightness = 123
        _ = try await primary.getStatus()
        h.transports["BBBB"]?.holdCmds.insert("set_brightness")
        h.fanOut.setTarget(.group(h.group.id))
        await waitUntil { h.transports["BBBB"]?.heldCount("set_brightness") == 1 }

        _ = try await primary.command(.setBrightness(raw: 200))
        h.transports["BBBB"]?.holdCmds.remove("set_brightness")
        h.transports["BBBB"]?.releaseHeld("set_brightness")

        await waitUntil { h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int == 200 }
        XCTAssertEqual(h.transports["BBBB"]?.lastCmdField("set_brightness", "raw") as? Int, 200)
        XCTAssertNil(h.fanOut.memberErrors["BBBB"])
    }
}

// MARK: - Fake transport

/// Minimal copy of `GroupFakeTransport` (private to `BoardGroupTests.swift`)
/// extended with per-command failure/delay and SET_FRAME recording for the
/// fan-out tests above.
private final class GroupControlFakeTransport: RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512
    var bootId = "aaaaaaaa"
    var caps = ["identify", "clock_sample", "scroll_viewport", "group_start"]
    var wifiBoardId: String?
    /// What `get_frame` replies with; overridable so a test can prove a
    /// sink actually receives the primary's *read-back* frame (F5).
    var getFrameReply = PackedFrame()
    /// `get_frame` isn't a `.cmd`-typed message (so `failCmds` can't reach
    /// it) — this makes it reply with a payload `PackedFrame(data:)` can't
    /// decode, so `BoardConnection.getFrame()` throws (F5's read-back-fails
    /// path).
    var failGetFrame = false
    /// F9: when `false`, `getStatus`'s reply omits the `renderer` object
    /// entirely, so a connection's `status?.renderer` decodes to `nil` —
    /// simulating "no status received yet" without leaving `status` itself
    /// nil (which `BoardConnection.connect` never actually leaves it as
    /// once the handshake completes).
    var includeRenderer = true
    var rendererBrightness: Int?
    var rendererColor: String?
    /// M2: firmware `renderer.mode`, as reported by `getStatus`.
    var rendererMode = "manual"
    var clockRxUs: Int64 = 1_000
    var clockTxUs: Int64 = 1_200
    var cmdReplyDelay: [String: TimeInterval] = [:]
    var frameReplyDelay: TimeInterval = 0
    var failCmds: Set<String> = []
    /// Commands named here never get a reply until `releaseHeld(_:)` is
    /// called — deterministic, unlike `cmdReplyDelay`'s wall-clock delay,
    /// which a loaded machine can blow through (a test racing a fixed delay
    /// against several other sends is exactly the kind of flake a shared-Mac
    /// load skews).
    var holdCmds: Set<String> = []
    private var heldRequests: [String: [RinaLinkFrame]] = [:]
    private(set) var sentGroupStartAtUs: [Int64] = []
    private(set) var receivedCmdNames: [String] = []
    private(set) var receivedFrameBytes: [[UInt8]] = []
    private var lastCmdPayloads: [String: [String: Any]] = [:]

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func lastCmdField(_ cmd: String, _ key: String) -> Any? {
        lastCmdPayloads[cmd]?[key]
    }

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws { stateContinuation?.yield(.connected) }
    func disconnect() { stateContinuation?.yield(.disconnected) }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            if let cmd = cmdName(of: request), holdCmds.contains(cmd) {
                heldRequests[cmd, default: []].append(request)
                continue
            }
            let delay = delay(for: request)
            if delay > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self else { return }
                    self.emitReply(request, payload: self.replyPayload(for: request))
                }
            } else {
                emitReply(request, payload: replyPayload(for: request))
            }
        }
    }

    /// Replies to every request currently held for `cmd` (see `holdCmds`).
    func releaseHeld(_ cmd: String) {
        guard let requests = heldRequests.removeValue(forKey: cmd) else { return }
        for request in requests {
            emitReply(request, payload: replyPayload(for: request))
        }
    }

    func heldCount(_ cmd: String) -> Int {
        heldRequests[cmd]?.count ?? 0
    }

    private func cmdName(of request: RinaLinkFrame) -> String? {
        guard request.type == RinaLinkMessageType.cmd.rawValue,
              let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any] else { return nil }
        return object["cmd"] as? String
    }

    private func delay(for request: RinaLinkFrame) -> TimeInterval {
        if request.type == RinaLinkMessageType.setFrame.rawValue { return frameReplyDelay }
        guard let cmd = cmdName(of: request) else { return 0 }
        return cmdReplyDelay[cmd] ?? 0
    }

    private func emitReply(_ request: RinaLinkFrame, payload: Data) {
        incomingContinuation?.yield(try! RinaLinkEncoder.encode(
            RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
        ))
    }

    private func replyPayload(for request: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: request.type) {
        case .getStatus:
            var wifi: [String: Any] = ["ip": "192.168.4.1"]
            if let wifiBoardId { wifi["boardId"] = wifiBoardId }
            var object: [String: Any] = ["ok": true, "power": [:], "wifi": wifi]
            if includeRenderer {
                var renderer: [String: Any] = ["mode": rendererMode]
                if let rendererBrightness { renderer["brightness"] = rendererBrightness }
                if let rendererColor { renderer["color"] = rendererColor }
                object["renderer"] = renderer
            }
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        case .getPreviewSync:
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "mode": "manual"])) ?? Data()
        case .getFrame:
            return failGetFrame ? Data() : getFrameReply.data
        case .setFrame:
            let bytes = Array(request.payload.suffix(PackedFrame.byteCount))
            receivedFrameBytes.append(bytes)
            return Data(#"{"ok":true}"#.utf8)
        case .blobBegin:
            return Data(#"{"ok":true,"offset":0,"chunkMax":512}"#.utf8)
        case .blobChunk:
            let offset = request.payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            let newOffset = Int(offset) + max(0, request.payload.count - 4)
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "offset": newOffset])) ?? Data()
        case .blobEnd:
            return Data(#"{"ok":true}"#.utf8)
        case .cmd:
            guard let object = try? JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
                  let cmd = object["cmd"] as? String else {
                return Data(#"{"ok":true}"#.utf8)
            }
            receivedCmdNames.append(cmd)
            lastCmdPayloads[cmd] = object
            if failCmds.contains(cmd) {
                return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": "denied"])) ?? Data()
            }
            switch cmd {
            case "get_info":
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "proto": 1, "bootId": bootId, "caps": caps])) ?? Data()
            case "clock_sample":
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "rxUs": clockRxUs, "txUs": clockTxUs, "bootId": bootId])) ?? Data()
            case "group_start":
                if let atUs = object["atUs"] as? NSNumber { sentGroupStartAtUs.append(atUs.int64Value) }
                return (try? JSONSerialization.data(withJSONObject: ["ok": true, "nowUs": 0, "frameCount": 10])) ?? Data()
            case "identify":
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "shown": true, "number": object["number"] ?? 1, "ttlMs": object["ttlMs"] ?? 5000,
                ])) ?? Data()
            case "stop_scroll":
                return Data(#"{"ok":true}"#.utf8)
            case "apply_saved_face":
                let index = object["index"] as? Int ?? 0
                return (try? JSONSerialization.data(withJSONObject: [
                    "ok": true, "autoFaceIndex": index, "autoFaceId": "face-\(index)",
                ])) ?? Data()
            default:
                return Data(#"{"ok":true}"#.utf8)
            }
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}
