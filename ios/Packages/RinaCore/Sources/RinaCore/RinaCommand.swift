import Foundation

/// `SET_FRAME` playback tag (`RINALINK_PROTOCOL_V1.md` §3.2).
public enum Playback: UInt8, Sendable {
    case idle = 0
    case paused = 1
    case scroll = 2
    case auto = 3
}

/// Every `CMD` command from §3.4 of the protocol / the old `/api/command`.
/// `jsonObject` produces the `{"cmd": "...", ...fields}` dictionary; `encode()`
/// serializes that to the `Data` sent as a `CMD` (`0x01`) payload.
public enum RinaCommand: Sendable {
    case setColor(hex: String)
    case setBrightness(raw: Int)
    case setMode(mode: String)
    case setAutoInterval(ms: Int)
    case setScrollInterval(intervalMs: Int?, fps: Int?)
    case startScroll(intervalMs: Int?, fps: Int?, sourceText: String?)
    case scrollStep(direction: Int)
    case pauseScroll
    case resumeScroll
    case stopScroll(restoreAuto: Bool?, clear: Bool?)
    case pause
    case resume
    /// `playback` is the firmware's `DEFAULT_PLAYBACK`-style string
    /// (`"idle"|"paused"|"scroll"|"auto"`), not the `SET_FRAME` binary enum —
    /// `apply_saved_face` reads it via `cstr(d, p, "playback", DEFAULT_PLAYBACK)`.
    case applySavedFace(index: Int, reason: String?, playback: String?)
    case button(button: String)
    case terminateOtherActivities(targetMode: String?)
    case resetBatteryMin
    case resetBatteryMax
    case batteryOverlay(singleShot: Bool?)
    case reboot
    case getInfo
    case subscribe(preview: Bool?, status: Bool?, power: Bool?, log: Bool?)
    case logSubscribe(on: Bool)
    case wifiStatus
    case wifiScan
    case wifiScanResult
    case wifiSetCredentials(ssid: String, password: String)
    case wifiClearCredentials
    case wifiSetMode(mode: String)
    case wifiConnect
    case wifiSetAp(ssid: String, password: String)
    // iPhone Personal Hotspot profile (RINALINK_PROTOCOL_V1 §8): a second
    // station credential set the board tries when `home` isn't visible.
    case wifiSetHotspotCredentials(ssid: String, password: String)
    case wifiClearHotspotCredentials
    // Incremental saved-face commands (RINALINK_PROTOCOL_V1 §7.2), replacing
    // whole-document `BLOB kind:"faces"` re-uploads for everyday edits.
    case faceRename(id: String, name: String)
    case faceReorder(ids: [String])
    case faceDelete(id: String)
    case faceUpsert(face: FaceUpsertPayload)
    case facesClearUser

    public var name: String {
        switch self {
        case .setColor: return "set_color"
        case .setBrightness: return "set_brightness"
        case .setMode: return "set_mode"
        case .setAutoInterval: return "set_auto_interval"
        case .setScrollInterval: return "set_scroll_interval"
        case .startScroll: return "start_scroll"
        case .scrollStep: return "scroll_step"
        case .pauseScroll: return "pause_scroll"
        case .resumeScroll: return "resume_scroll"
        case .stopScroll: return "stop_scroll"
        case .pause: return "pause"
        case .resume: return "resume"
        case .applySavedFace: return "apply_saved_face"
        case .button: return "button"
        case .terminateOtherActivities: return "terminate_other_activities"
        case .resetBatteryMin: return "reset_battery_min"
        case .resetBatteryMax: return "reset_battery_max"
        case .batteryOverlay: return "battery_overlay"
        case .reboot: return "reboot"
        case .getInfo: return "get_info"
        case .subscribe: return "subscribe"
        case .logSubscribe: return "log_subscribe"
        case .wifiStatus: return "wifi_status"
        case .wifiScan: return "wifi_scan"
        case .wifiScanResult: return "wifi_scan_result"
        case .wifiSetCredentials: return "wifi_set_credentials"
        case .wifiClearCredentials: return "wifi_clear_credentials"
        case .wifiSetMode: return "wifi_set_mode"
        case .wifiConnect: return "wifi_connect"
        case .wifiSetAp: return "wifi_set_ap"
        case .wifiSetHotspotCredentials: return "wifi_set_hotspot_credentials"
        case .wifiClearHotspotCredentials: return "wifi_clear_hotspot_credentials"
        case .faceRename: return "face_rename"
        case .faceReorder: return "face_reorder"
        case .faceDelete: return "face_delete"
        case .faceUpsert: return "face_upsert"
        case .facesClearUser: return "faces_clear_user"
        }
    }

    /// Builds the `{"cmd": "...", ...}` JSON object as a `[String: Any]`.
    public var jsonObject: [String: Any] {
        var fields: [String: Any] = ["cmd": name]
        switch self {
        case .setColor(let hex):
            fields["hex"] = hex
        case .setBrightness(let raw):
            fields["raw"] = raw
        case .setMode(let mode):
            fields["mode"] = mode
        case .setAutoInterval(let ms):
            fields["ms"] = ms
        case .setScrollInterval(let intervalMs, let fps):
            if let intervalMs { fields["intervalMs"] = intervalMs }
            if let fps { fields["fps"] = fps }
        case .startScroll(let intervalMs, let fps, let sourceText):
            if let intervalMs { fields["intervalMs"] = intervalMs }
            if let fps { fields["fps"] = fps }
            if let sourceText { fields["sourceText"] = sourceText }
        case .scrollStep(let direction):
            fields["direction"] = direction
        case .pauseScroll, .resumeScroll, .pause, .resume, .resetBatteryMin, .resetBatteryMax,
             .reboot, .getInfo, .wifiStatus, .wifiScan, .wifiScanResult, .wifiClearCredentials, .wifiConnect,
             .wifiClearHotspotCredentials:
            break
        case .logSubscribe(let on):
            fields["on"] = on
        case .stopScroll(let restoreAuto, let clear):
            if let restoreAuto { fields["restoreAuto"] = restoreAuto }
            if let clear { fields["clear"] = clear }
        case .applySavedFace(let index, let reason, let playback):
            fields["index"] = index
            if let reason { fields["reason"] = reason }
            if let playback { fields["playback"] = playback }
        case .button(let button):
            fields["button"] = button
        case .terminateOtherActivities(let targetMode):
            if let targetMode { fields["targetMode"] = targetMode }
        case .batteryOverlay(let singleShot):
            if let singleShot { fields["singleShot"] = singleShot }
        case .subscribe(let preview, let status, let power, let log):
            if let preview { fields["preview"] = preview }
            if let status { fields["status"] = status }
            if let power { fields["power"] = power }
            if let log { fields["log"] = log }
        case .wifiSetCredentials(let ssid, let password):
            fields["ssid"] = ssid
            fields["password"] = password
        case .wifiSetMode(let mode):
            fields["mode"] = mode
        case .wifiSetAp(let ssid, let password):
            fields["ssid"] = ssid
            fields["password"] = password
        case .wifiSetHotspotCredentials(let ssid, let password):
            fields["ssid"] = ssid
            fields["password"] = password
        case .faceRename(let id, let name):
            fields["id"] = id
            fields["name"] = name
        case .faceReorder(let ids):
            fields["ids"] = ids
        case .faceDelete(let id):
            fields["id"] = id
        case .faceUpsert(let face):
            fields["face"] = face.jsonObject
        case .facesClearUser:
            break
        }
        return fields
    }

    /// Serializes `jsonObject` to UTF-8 JSON `Data` for use as the `CMD` payload.
    public func encode() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }
}

/// `face_upsert`'s `{"face": {...}}` payload (§7.2): create when `id` is nil
/// (server assigns the id, appends with `order = max+1`), update in place
/// when `id` matches an existing non-default face.
public struct FaceUpsertPayload: Sendable, Equatable {
    public var id: String?
    public var name: String
    /// `"custom"` or `"parts"` (`SavedFace.Kind.rawValue`); defaults cannot be upserted.
    public var type: String
    /// 94-hex-char packed frame (`PackedFrame.hex94`).
    public var frameHex: String
    public var call: SavedFace.CallIds?

    public init(id: String? = nil, name: String, type: String, frameHex: String, call: SavedFace.CallIds? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.frameHex = frameHex
        self.call = call
    }

    var jsonObject: [String: Any] {
        var obj: [String: Any] = ["name": name, "type": type, "frameHex": frameHex]
        if let id { obj["id"] = id }
        if let call {
            var callObj: [String: Any] = [:]
            if let leye = call.leye { callObj["leye"] = leye }
            if let reye = call.reye { callObj["reye"] = reye }
            if let mouth = call.mouth { callObj["mouth"] = mouth }
            if let cheek = call.cheek { callObj["cheek"] = cheek }
            obj["call"] = callObj
        }
        return obj
    }
}
