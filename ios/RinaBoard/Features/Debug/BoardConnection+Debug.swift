import Foundation
import RinaCore

/// Debug-tab-only helpers layered on top of `BoardConnection`'s public API
/// (FEATURE_INVENTORY §C). Kept in its own file per project convention: no
/// edits to `Services/BoardConnection.swift` itself.
public extension BoardConnection {
    /// Raw `GET_STATUS` JSON, preserving fields the typed `DeviceStatus` model
    /// doesn't declare (e.g. `ledDma`, `frameQueueCount`, `lastReason`) so the
    /// Debug device-overview grid (C2) can show everything the firmware sends.
    func getStatusRaw(lite: Bool = false) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: lite ? ["lite": true] : [:])
        let frame = try await send(type: .getStatus, payload: payload)
        return frame.payload
    }

    /// Raw `GET_POWER` JSON.
    func getPowerRaw() async throws -> Data {
        let frame = try await send(type: .getPower, payload: Data())
        return frame.payload
    }

    /// `CMD get_info` (fw/build/led backend/heap/psram), §3.4.
    func getDeviceInfo() async throws -> DeviceInfo {
        let payload = try RinaCommand.getInfo.encode()
        let frame = try await send(type: .cmd, payload: payload)
        return try JSONDecoder().decode(DeviceInfo.self, from: frame.payload)
    }

    /// `PING` round trip; returns firmware-reported uptime and measured RTT (ms).
    func pingRoundTrip() async throws -> (uptimeMs: Int, rttMs: Double) {
        struct PingReply: Codable { var ok: Bool?; var uptimeMs: Int? }
        let start = Date()
        let frame = try await send(type: .ping, payload: Data())
        let rtt = Date().timeIntervalSince(start) * 1000
        let decoded = try JSONDecoder().decode(PingReply.self, from: frame.payload)
        return (decoded.uptimeMs ?? 0, rtt)
    }

    /// Sends an arbitrary raw `CMD` JSON payload (already-encoded) and returns
    /// the raw reply JSON, for the Debug tab's "raw command" panel (C11).
    /// Bypasses the typed `command(_:)` wrapper so any JSON body is accepted.
    func sendRawCommand(json: Data) async throws -> Data {
        let frame = try await send(type: .cmd, payload: json)
        return frame.payload
    }

    // NOTE (C10 firmware log): `EV_LOG` (0x94) frames are consumed and
    // discarded inside `BoardConnection.route(_:)`, which is private and
    // lives in `Services/BoardConnection.swift` (out of scope to edit for
    // this feature). There is no public event stream/callback exposed for
    // events other than the already-published `status`/`power`/`wifi`/
    // `preview` properties, so this extension cannot observe `EV_LOG`
    // without modifying `BoardConnection.swift`. The Debug tab's "固件日志"
    // subscribe toggle is therefore left disabled with an explanatory note.
}
