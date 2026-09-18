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
    /// Draws one logical LED at half the board colour on top of whatever is
    /// showing (`nil` clears it) — the face editor's Apple Pencil hover. Owned
    /// by the sending client; the board clears it when that client leaves.
    /// `mirror`: a second LED shown with `led` (the other eye). Firmware
    /// older than the field ignores it and shows `led` alone.
    case setHintLED(led: Int?, mirror: Int? = nil)
    case setMode(mode: String)
    case setAutoInterval(ms: Int)
    case setScrollInterval(intervalMs: Int?, fps: Int?)
    case startScroll(intervalMs: Int?, fps: Int?, sourceText: String?)
    case scrollStep(direction: Int)
    /// Absolute jump on the bound scroll timeline; play/pause state is kept.
    case scrollSeek(frameIndex: Int)
    /// Loop preference: off pauses the scroll on its last frame.
    case setScrollLoop(loop: Bool)
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
    /// Sets (or, with an empty/omitted `name`, clears) the board's custom
    /// display name (`RINALINK_PROTOCOL_V1` `set_device_name`).
    case setDeviceName(name: String)
    // Board groups (BOARD_GROUP_SPEC.md §1.2/§1.3/§1.5).
    /// Overlay-draws a large digit (`number` 1…9) for `ttlMs` (0 cancels;
    /// missing → 5000); re-arms on repeat calls.
    case identify(number: Int, ttlMs: Int?)
    /// Cheap, never rate-limited round-trip timestamp exchange used to build a
    /// `ClockOffsetEstimator` sample.
    case clockSample
    /// Enters/re-anchors group-timed scroll playback: `atUs` is this board's
    /// own `esp_timer_get_time()` latch point, `bootId` must match the
    /// board's current boot, `startFrame` defaults to 0, `loop` defaults to `true`.
    case groupStart(atUs: Int64, bootId: String, intervalMs: Int, startFrame: Int?, loop: Bool?)

    public var name: String {
        switch self {
        case .setColor: return "set_color"
        case .setBrightness: return "set_brightness"
        case .setHintLED: return "set_hint_led"
        case .setMode: return "set_mode"
        case .setAutoInterval: return "set_auto_interval"
        case .setScrollInterval: return "set_scroll_interval"
        case .startScroll: return "start_scroll"
        case .scrollStep: return "scroll_step"
        case .scrollSeek: return "scroll_seek"
        case .setScrollLoop: return "set_scroll_loop"
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
        case .setDeviceName: return "set_device_name"
        case .identify: return "identify"
        case .clockSample: return "clock_sample"
        case .groupStart: return "group_start"
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
        case .setHintLED(let led, let mirror):
            fields["led"] = led ?? -1
            if led != nil, let mirror { fields["mirror"] = mirror }
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
        case .scrollSeek(let frameIndex):
            fields["frameIndex"] = frameIndex
        case .setScrollLoop(let loop):
            fields["loop"] = loop
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
        case .setDeviceName(let name):
            fields["name"] = name
        case .identify(let number, let ttlMs):
            fields["number"] = number
            if let ttlMs { fields["ttlMs"] = ttlMs }
        case .clockSample:
            break
        case .groupStart(let atUs, let bootId, let intervalMs, let startFrame, let loop):
            fields["atUs"] = atUs
            fields["bootId"] = bootId
            fields["intervalMs"] = intervalMs
            if let startFrame { fields["startFrame"] = startFrame }
            if let loop { fields["loop"] = loop }
        }
        return fields
    }

    /// Serializes `jsonObject` to UTF-8 JSON `Data` for use as the `CMD` payload.
    public func encode() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }

    /// How this command should fan out to the other boards in a board group
    /// when it's sent to the group's primary board (`BOARD_GROUP_SPEC.md`
    /// control-fan-out addendum). `resolveFace` commands are re-resolved to
    /// the primary's actual resulting frame rather than replayed verbatim,
    /// since face libraries aren't synced across members. Everything not
    /// explicitly listed defaults to `.deny` so new commands are safe by
    /// default.
    public var groupFanOutPolicy: GroupFanOutPolicy {
        switch self {
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

/// Fan-out behavior of a `RinaCommand` when it's dispatched from a board
/// group's primary connection to the group's other (sink) members. See
/// `RinaCommand.groupFanOutPolicy`.
public enum GroupFanOutPolicy: Equatable, Sendable {
    /// Replay the same command on every sink. `coalesceKey` non-nil means
    /// only the latest queued command with that key is kept per sink
    /// (latest-wins); nil means every call is queued and sent in order.
    case verbatim(coalesceKey: String?)
    /// Don't replay the command as-is; instead resolve it to the primary's
    /// resulting frame and `SET_FRAME` that to every sink.
    case resolveFace
    /// Never fan out; only the primary receives this command.
    case deny
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
