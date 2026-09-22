import XCTest
@testable import RinaCore

/// Asserts `RinaCommand.groupFanOutPolicy` for every case. The switch below
/// is exhaustive (no `default`) so a newly added `RinaCommand` case fails to
/// compile here until its policy is decided, per the board-group
/// control-fan-out addendum to `BOARD_GROUP_SPEC.md`.
final class GroupFanOutPolicyTests: XCTestCase {
    func testPolicyForEveryCommand() {
        let sample: [RinaCommand] = [
            .setColor(hex: "#000000"),
            .setBrightness(raw: 128),
            .setHintLED(led: 5),
            .setMode(mode: "idle"),
            .setAutoInterval(ms: 500),
            .setScrollInterval(intervalMs: 100, fps: nil),
            .startScroll(intervalMs: 100, fps: nil, sourceText: nil),
            .scrollStep(direction: 1),
            .scrollSeek(frameIndex: 0),
            .setScrollLoop(loop: true),
            .pauseScroll,
            .resumeScroll,
            .stopScroll(restoreAuto: nil, clear: nil),
            .pause,
            .resume,
            .applySavedFace(index: 0, id: nil, reason: nil, playback: nil),
            .button(button: "B1"),
            .button(button: "B2"),
            .button(button: "B3"),
            .terminateOtherActivities(targetMode: nil),
            .resetBatteryMin,
            .resetBatteryMax,
            .batteryOverlay(singleShot: nil),
            .reboot,
            .getInfo,
            .subscribe(preview: nil, status: nil, power: nil, log: nil),
            .logSubscribe(on: true),
            .wifiStatus,
            .wifiScan,
            .wifiScanResult,
            .wifiSetCredentials(ssid: "s", password: "p"),
            .wifiClearCredentials,
            .wifiSetMode(mode: "sta"),
            .wifiConnect,
            .wifiSetAp(ssid: "s", password: "p"),
            .wifiSetHotspotCredentials(ssid: "s", password: "p"),
            .wifiClearHotspotCredentials,
            .faceRename(id: "1", name: "n"),
            .faceReorder(ids: ["1"]),
            .faceDelete(id: "1"),
            .faceUpsert(face: FaceUpsertPayload(name: "n", type: "custom", frameHex: String(repeating: "0", count: 94))),
            .facesClearUser,
            .setDeviceName(name: "n"),
            .identify(number: 1, ttlMs: nil),
            .clockSample,
            .groupStart(atUs: 0, bootId: "b", intervalMs: 100, startFrame: nil, loop: nil),
        ]

        for cmd in sample {
            XCTAssertEqual(cmd.groupFanOutPolicy, expectedPolicy(for: cmd), "\(cmd.name)")
        }
    }

    /// Exhaustive switch (no `default`): a new `RinaCommand` case must be
    /// added here — and given a real policy decision — before it compiles.
    private func expectedPolicy(for cmd: RinaCommand) -> GroupFanOutPolicy {
        switch cmd {
        case .setColor: return .verbatim(coalesceKey: "set_color")
        case .setBrightness: return .verbatim(coalesceKey: "set_brightness")
        case .setAutoInterval: return .verbatim(coalesceKey: "set_auto_interval")
        case .setHintLED: return .verbatim(coalesceKey: "set_hint_led")
        case .setMode: return .verbatim(coalesceKey: nil)
        case .pause: return .verbatim(coalesceKey: nil)
        case .resume: return .verbatim(coalesceKey: nil)
        case .terminateOtherActivities: return .verbatim(coalesceKey: nil)
        case .batteryOverlay: return .verbatim(coalesceKey: nil)
        case .button(let button):
            return (button == "B1" || button == "B2") ? .resolveFace : .verbatim(coalesceKey: nil)
        case .applySavedFace: return .resolveFace
        case .setScrollInterval, .startScroll, .scrollStep, .scrollSeek, .setScrollLoop,
             .pauseScroll, .resumeScroll, .stopScroll:
            return .deny
        case .identify, .clockSample, .groupStart, .getInfo, .subscribe, .logSubscribe:
            return .deny
        case .reboot, .resetBatteryMin, .resetBatteryMax:
            return .deny
        case .setDeviceName:
            return .deny
        case .wifiStatus, .wifiScan, .wifiScanResult, .wifiSetCredentials, .wifiClearCredentials,
             .wifiSetMode, .wifiConnect, .wifiSetAp, .wifiSetHotspotCredentials, .wifiClearHotspotCredentials:
            return .deny
        case .faceUpsert, .faceDelete, .faceReorder, .faceRename, .facesClearUser:
            return .deny
        }
    }
}
