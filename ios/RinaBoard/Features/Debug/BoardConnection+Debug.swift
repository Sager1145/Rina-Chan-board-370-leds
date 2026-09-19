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

    // NOTE (C10 firmware log): no helper is needed here. `BoardConnection`
    // decodes `EV_LOG` (0x94) into `lastLog` and fans it out as
    // `BoardEvent.log` on the public multi-consumer `events()` stream, so
    // the Debug tab's "固件日志" toggle drives the feature directly from
    // `DebugViewModel`: `CMD log_subscribe` to turn the firmware stream on,
    // then `for await` over `events()`.
}
