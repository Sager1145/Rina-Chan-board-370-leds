import Foundation
import SwiftUI
import UIKit
import XCTest
import RinaCore
@testable import RinaBoard

/// IOS-DRAFT-ADOPT-1..3: can a synced Faces drawing be replaced by the board's
/// frame and persisted, and is the Faces polling task alive on a hidden tab?
@MainActor
final class StressDraftAdoptTests: XCTestCase {
    private var savedDraft: Data?

    override func setUp() async throws {
        savedDraft = try? await DraftStorage.shared.read("face")
    }

    override func tearDown() async throws {
        if let savedDraft { try? await DraftStorage.shared.write(savedDraft, name: "face") }
    }

    private func diskFrame() async -> PackedFrame? {
        guard let data = try? await DraftStorage.shared.read("face"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hex = object["frame"] as? String else { return nil }
        return PackedFrame(hex94: hex)
    }

    private func frame(lit: Int, offset: Int) -> PackedFrame {
        var f = PackedFrame()
        for i in 0..<lit { f.set((offset + i * 7) % 370) }
        return f
    }

    private func label(_ frame: PackedFrame?, drawn: PackedFrame, board: PackedFrame) -> String {
        guard let frame else { return "none" }
        if frame == drawn { return "drawing" }
        if frame == board { return "board" }
        return "other(\(frame.litCount))"
    }

    // (1) synced draft + adoptBoardFrameIfUntouched(other) and the real polling path.
    func testIOSDraftAdopt1_SyncedDrawingReplacedByBoardFrame() async {
        let t = StressTransport()
        let c = await stressConnected(t)
        var rows: [String] = []
        var destroyedCount = 0
        for path in ["adoptBoardFrameIfUntouched", "refreshBoardDisplay(getFrame)"] {
            let vm = ControlViewModel()
            vm.livePreview = false
            for led in stride(from: 0, to: 330, by: 10) { vm.toggle(led: led, connection: c) }
            await vm.send(connection: c)
            let drawn = vm.draftFrame
            let synced = !vm.hasUnsentChanges
            let undoBefore = vm.canUndo
            try? await Task.sleep(nanoseconds: 400_000_000)
            let diskBefore = await diskFrame()
            let board = frame(lit: 7, offset: path.count)
            if path == "adoptBoardFrameIfUntouched" {
                vm.adoptBoardFrameIfUntouched(board)
            } else {
                t.responder = { f in
                    guard f.type == RinaLinkMessageType.getFrame.rawValue else { return nil }
                    return [RinaLinkFrame(type: f.type | 0x80, seq: f.seq, flags: 0, payload: board.data)]
                }
                await vm.refreshBoardDisplay(connection: c)
                t.responder = nil
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            let diskAfter = await diskFrame()
            let destroyed = vm.draftFrame == board && diskAfter == board && !vm.canUndo
            if destroyed { destroyedCount += 1 }
            rows.append("\(path):synced=\(synced),lit=\(drawn.litCount),undoBefore=\(undoBefore),diskBefore=\(label(diskBefore, drawn: drawn, board: board)),mem=\(label(vm.draftFrame, drawn: drawn, board: board)),disk=\(label(diskAfter, drawn: drawn, board: board)),undoAfter=\(vm.canUndo),unsent=\(vm.hasUnsentChanges)")
        }
        let status = destroyedCount == 0 ? "PASS" : "FAIL"
        Stress.record(case: "IOS-DRAFT-ADOPT-1", layer: "ControlViewModel.adoptBoardFrameIfUntouched (ControlViewModel.swift:497-516)",
                      load: "33 toggles, send (synced), board shows 7-lit frame", status: status,
                      metrics: ["paths_destroying_drawing": destroyedCount, "rows": rows.joined(separator: " ; ")],
                      evidence: "StressDraftAdoptTests/testIOSDraftAdopt1_SyncedDrawingReplacedByBoardFrame")
        XCTAssertEqual(destroyedCount, 0, "synced drawing replaced in memory and on disk, undo cleared: \(rows)")
        c.disconnect()
    }

    // (2) fresh ControlViewModel with on-disk draft D; adoption before restoreDraft().
    func testIOSDraftAdopt2_AdoptionBeforeRestoreDraft() async {
        var rows: [String] = []
        var lost = 0
        var restoredUnsent = 0
        let offline = BoardConnection()
        for delayMs in [0, 300] {
            let writer = ControlViewModel()
            writer.livePreview = false
            for led in [5, 17, 29, 41, 53, 65, 77] { writer.toggle(led: led, connection: offline) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await writer.persistDraft()
            let d = writer.draftFrame
            let b = frame(lit: 7, offset: 100 + delayMs)
            let vm = ControlViewModel()
            let unsentAtInit = vm.hasUnsentChanges
            vm.adoptBoardFrameIfUntouched(b)
            if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
            let diskBeforeRestore = await diskFrame()
            await vm.restoreDraft()
            let memAfterRestore = vm.draftFrame
            let unsentAfterRestore = vm.hasUnsentChanges
            try? await Task.sleep(nanoseconds: 450_000_000)
            let diskFinal = await diskFrame()
            if memAfterRestore != d || diskFinal != d { lost += 1 }
            if unsentAfterRestore { restoredUnsent += 1 }
            rows.append("delay\(delayMs)ms:unsentAtInit=\(unsentAtInit),diskBeforeRestore=\(label(diskBeforeRestore, drawn: d, board: b)),mem=\(label(memAfterRestore, drawn: d, board: b)),disk=\(label(diskFinal, drawn: d, board: b)),unsentAfterRestore=\(unsentAfterRestore)")
        }
        let status = lost == 0 ? "PASS" : "FAIL"
        Stress.record(case: "IOS-DRAFT-ADOPT-2", layer: "ControlViewModel.init/restoreDraft/adopt (ControlViewModel.swift:95-122,167-183,497)",
                      load: "draft D on disk; adopt(B) 0/300 ms before restoreDraft", status: status,
                      metrics: ["runs_losing_D": lost, "restored_draft_marked_unsent": restoredUnsent,
                                "rows": rows.joined(separator: " ; ")],
                      evidence: "StressDraftAdoptTests/testIOSDraftAdopt2_AdoptionBeforeRestoreDraft")
        XCTAssertEqual(lost, 0, "on-disk draft lost to an adoption that ran before restoreDraft: \(rows)")
    }

    // (3) Does a `.task(id:)` shaped like ControlView.swift:70 keep polling on a hidden TabView tab?
    func testIOSDraftAdopt3_HiddenTabPollingTask() async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Stress.record(case: "IOS-DRAFT-ADOPT-3", layer: "SwiftUI TabView .task(id:)", load: "probe",
                          status: "BLOCKED", metrics: ["reason": "no UIWindowScene in test host"],
                          evidence: "StressDraftAdoptTests/testIOSDraftAdopt3_HiddenTabPollingTask")
            return
        }
        let model = TabProbeModel()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TabProbeView(model: model))
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let started = await Stress.wait(timeout: 3) { model.ticks > 2 }
        var t0 = model.ticks
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let visibleTicks = model.ticks - t0
        let switchAt = Stress.nowNs()
        let ticksAtSwitch = model.ticks
        model.selection = 1
        // Measure when the loop stops: last tick time after the switch.
        var lastTickMs = 0.0
        var seen = model.ticks
        while Stress.ms(since: switchAt) < 2_000 {
            if model.ticks != seen { seen = model.ticks; lastTickMs = Stress.ms(since: switchAt) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let ticksAfterSwitch = model.ticks - ticksAtSwitch
        t0 = model.ticks
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Steady state: no ticks between 2 s and 3 s after the tab switch.
        let hiddenTicks = model.ticks - t0
        let cancelledOnHide = model.cancellations
        model.selection = 0
        try? await Task.sleep(nanoseconds: 400_000_000)
        t0 = model.ticks
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let revisibleTicks = model.ticks - t0
        let decided = started && visibleTicks > 0
        let status = !decided ? "BLOCKED" : (hiddenTicks > 0 ? "FAIL" : "PASS")
        Stress.record(case: "IOS-DRAFT-ADOPT-3", layer: "SwiftUI TabView .task(id:) as in ControlView.swift:70-77",
                      load: "50 ms poll loop; tab A visible 1 s, hidden 3 s (steady-state window 2-3 s), visible 1 s", status: status,
                      metrics: ["started": started, "ticks_visible_1s": visibleTicks,
                                "ticks_in_first_2s_after_switch": ticksAfterSwitch,
                                "last_tick_ms_after_switch": lastTickMs,
                                "ticks_hidden_steady_2_3s": hiddenTicks,
                                "task_cancellations_on_hide": cancelledOnHide, "ticks_revisible_1s": revisibleTicks,
                                "control_view_task_id_has_tab_term": false],
                      evidence: "StressDraftAdoptTests/testIOSDraftAdopt3_HiddenTabPollingTask")
        XCTAssertTrue(decided, "probe did not start")
        XCTAssertEqual(hiddenTicks, 0, "polling task kept running while its tab was hidden")
    }
}

@Observable @MainActor
final class TabProbeModel {
    var selection = 0
    var ticks = 0
    var cancellations = 0
    var connected = true
    var generation = UUID()
}

struct TabProbeView: View {
    @Bindable var model: TabProbeModel

    var body: some View {
        TabView(selection: $model.selection) {
            Text("faces")
                .task(id: model.connected ? model.generation : nil) {
                    guard model.connected else { return }
                    while !Task.isCancelled {
                        model.ticks += 1
                        do { try await Task.sleep(for: .milliseconds(50)) } catch {
                            model.cancellations += 1
                            return
                        }
                    }
                    model.cancellations += 1
                }
                .tabItem { Text("A") }
                .tag(0)
            Text("text")
                .tabItem { Text("B") }
                .tag(1)
        }
    }
}
