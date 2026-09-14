import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Host repros for real-device observations reported by the coordinator.
@MainActor
final class StressDeviceObservationTests: XCTestCase {
    /// (b) Firmware pushes EV_STATUS built with `buildStatusJson(d, true)`
    /// (protocol.cpp:2079), which omits `device`, `uptimeMs`, `wifi`,
    /// `matrix`, `stats`. `applyStatus` replaces `status` wholesale.
    func testObsB_LiteStatusPushKeepsDeviceIdentity() async {
        let t = StressTransport()
        t.responder = { frame in
            guard frame.type == RinaLinkMessageType.getStatus.rawValue else { return nil }
            let full = #"{"ok":true,"v":1,"version":1,"device":"RinaChanBoard","uptimeMs":1234,"wifi":{"ip":"192.168.1.20"},"power":{},"renderer":{"mode":"auto"}}"#
            return [RinaLinkFrame(type: frame.type | 0x80, seq: frame.seq, flags: 0, payload: Data(full.utf8))]
        }
        let c = await stressConnected(t)
        let deviceBefore = c.status?.device
        let uptimeBefore = c.status?.uptimeMs
        let lite = #"{"ok":true,"v":2,"version":2,"power":{},"renderer":{"mode":"manual"}}"#
        t.inject(RinaLinkFrame(type: RinaLinkMessageType.evStatus.rawValue, seq: 0, flags: 0, payload: Data(lite.utf8)))
        let applied = await Stress.wait(timeout: 1) { c.status?.renderer?.mode == "manual" }
        let deviceAfter = c.status?.device
        let pass = deviceBefore == "RinaChanBoard" && applied && deviceAfter == "RinaChanBoard"
        Stress.record(case: "OBS-b-lite-status-drops-device", layer: "BoardConnection.applyStatus",
                      load: "full GET_STATUS then 1 lite EV_STATUS", status: pass ? "PASS" : "FAIL",
                      metrics: ["device_before": deviceBefore ?? "nil", "device_after": deviceAfter ?? "nil",
                                "uptime_before": uptimeBefore ?? -1, "uptime_after": c.status?.uptimeMs ?? -1,
                                "status_wifi_after": c.status?.wifi == nil ? "nil" : "present",
                                "connection_wifi_after": c.wifi?.ip ?? "nil", "lite_applied": applied],
                      evidence: "StressDeviceObservationTests/testObsB_LiteStatusPushKeepsDeviceIdentity")
        XCTAssertEqual(deviceBefore, "RinaChanBoard")
        XCTAssertEqual(deviceAfter, "RinaChanBoard", "lite EV_STATUS push erased status.device (Settings shows —)")
        c.disconnect()
    }
}
