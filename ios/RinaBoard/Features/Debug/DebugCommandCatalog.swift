import Foundation

/// Groups the Serial Monitor's command picker into sections, matching the
/// firmware's own command families (`esp32s3_firmware/src/protocol.cpp`).
enum DebugCommandGroup: String, CaseIterable, Identifiable {
    case query, display, scroll, network, faces, device, subscription

    var id: String { rawValue }

    var title: String {
        switch self {
        case .query: return NSLocalizedString("查询", comment: "debug command group")
        case .display: return NSLocalizedString("显示与播放", comment: "debug command group")
        case .scroll: return NSLocalizedString("文字滚动", comment: "debug command group")
        case .network: return NSLocalizedString("网络", comment: "debug command group")
        case .faces: return NSLocalizedString("表情库", comment: "debug command group")
        case .device: return NSLocalizedString("设备与电源", comment: "debug command group")
        case .subscription: return NSLocalizedString("订阅", comment: "debug command group")
        }
    }
}

/// A ready-to-send RinaLink `CMD` JSON payload for the Serial Monitor.
struct DebugCommandTemplate: Identifiable {
    let name: String
    let example: String
    let group: DebugCommandGroup
    var isDestructive: Bool

    var id: String { name }
}

/// Commands accepted by `esp32s3_firmware/src/protocol.cpp` over BLE or Wi-Fi.
/// Examples are CMD payloads, not USB serial-console commands or RinaLink frames.
enum DebugCommandCatalog {
    /// Commands whose effect cannot be undone or interrupts the board
    /// meaningfully — the Serial Monitor gates sending these behind an
    /// extra confirmation toggle.
    private static let destructiveNames: Set<String> = [
        "reboot", "faces_clear_user", "face_delete",
        "wifi_clear_credentials", "wifi_clear_hotspot_credentials",
        "reset_battery_min", "reset_battery_max"
    ]

    static func isDestructive(commandName: String) -> Bool {
        destructiveNames.contains(commandName)
    }

    static let commands: [DebugCommandTemplate] = [
        // MARK: query
        .init(name: "PING", example: "PING", group: .query, isDestructive: false),
        .init(name: "GET_STATUS", example: "GET_STATUS", group: .query, isDestructive: false),
        .init(name: "GET_POWER", example: "GET_POWER", group: .query, isDestructive: false),
        .init(name: "get_info", example: #"{"cmd":"get_info"}"#, group: .query, isDestructive: false),

        // MARK: display
        .init(name: "set_color", example: ##"{"cmd":"set_color","hex":"#EC3FC7"}"##, group: .display, isDestructive: false),
        .init(name: "set_brightness", example: #"{"cmd":"set_brightness","raw":80}"#, group: .display, isDestructive: false),
        .init(name: "set_mode", example: #"{"cmd":"set_mode","mode":"manual"}"#, group: .display, isDestructive: false),
        .init(name: "set_auto_interval", example: #"{"cmd":"set_auto_interval","ms":5000}"#, group: .display, isDestructive: false),
        .init(name: "apply_saved_face", example: #"{"cmd":"apply_saved_face","index":0,"reason":"debug","playback":"idle"}"#, group: .display, isDestructive: false),
        .init(name: "button", example: #"{"cmd":"button","button":"B3"}"#, group: .display, isDestructive: false),
        .init(name: "pause", example: #"{"cmd":"pause"}"#, group: .display, isDestructive: false),
        .init(name: "resume", example: #"{"cmd":"resume"}"#, group: .display, isDestructive: false),
        .init(name: "terminate_other_activities", example: #"{"cmd":"terminate_other_activities","targetMode":"manual"}"#, group: .display, isDestructive: false),

        // MARK: scroll
        .init(name: "set_scroll_interval", example: #"{"cmd":"set_scroll_interval","intervalMs":100}"#, group: .scroll, isDestructive: false),
        .init(name: "start_scroll", example: #"{"cmd":"start_scroll","intervalMs":100,"sourceText":"Hello","loop":true}"#, group: .scroll, isDestructive: false),
        .init(name: "scroll_step", example: #"{"cmd":"scroll_step","direction":1}"#, group: .scroll, isDestructive: false),
        .init(name: "scroll_seek", example: #"{"cmd":"scroll_seek","frameIndex":0}"#, group: .scroll, isDestructive: false),
        .init(name: "set_scroll_loop", example: #"{"cmd":"set_scroll_loop","loop":false}"#, group: .scroll, isDestructive: false),
        .init(name: "pause_scroll", example: #"{"cmd":"pause_scroll"}"#, group: .scroll, isDestructive: false),
        .init(name: "resume_scroll", example: #"{"cmd":"resume_scroll"}"#, group: .scroll, isDestructive: false),
        .init(name: "stop_scroll", example: #"{"cmd":"stop_scroll","restoreAuto":false,"clear":true}"#, group: .scroll, isDestructive: false),

        // MARK: network
        .init(name: "wifi_status", example: #"{"cmd":"wifi_status"}"#, group: .network, isDestructive: false),
        .init(name: "wifi_scan", example: #"{"cmd":"wifi_scan"}"#, group: .network, isDestructive: false),
        .init(name: "wifi_scan_result", example: #"{"cmd":"wifi_scan_result"}"#, group: .network, isDestructive: false),
        .init(name: "wifi_set_credentials", example: #"{"cmd":"wifi_set_credentials","ssid":"Home Wi-Fi","password":"password123"}"#, group: .network, isDestructive: false),
        .init(name: "wifi_clear_credentials", example: #"{"cmd":"wifi_clear_credentials"}"#, group: .network, isDestructive: true),
        .init(name: "wifi_set_hotspot_credentials", example: #"{"cmd":"wifi_set_hotspot_credentials","ssid":"My iPhone","password":"password123"}"#, group: .network, isDestructive: false),
        .init(name: "wifi_clear_hotspot_credentials", example: #"{"cmd":"wifi_clear_hotspot_credentials"}"#, group: .network, isDestructive: true),
        .init(name: "wifi_set_mode", example: #"{"cmd":"wifi_set_mode","mode":"sta_or_ap"}"#, group: .network, isDestructive: false),
        .init(name: "wifi_connect", example: #"{"cmd":"wifi_connect"}"#, group: .network, isDestructive: false),
        .init(name: "wifi_set_ap", example: #"{"cmd":"wifi_set_ap","ssid":"RinaChanBoard-V2","password":"rinachan"}"#, group: .network, isDestructive: false),

        // MARK: faces
        .init(name: "face_rename", example: #"{"cmd":"face_rename","id":"face_01_surprised_winking_with_mouth","name":"Wink"}"#, group: .faces, isDestructive: false),
        .init(name: "face_reorder", example: #"{"cmd":"face_reorder","ids":["face_01_surprised_winking_with_mouth","face_02_glasses_eyed_square_mouth","face_03_confused_raised_eyebrows","face_04_sad_diagonal_eyes_downturned_mouth","face_05_neutral_blocky_eyes_smirk","face_06_squinting_happy","face_07_wide_eyebrows_tiny_mouth","face_08_triangle_eyes_frown","face_09_stoic_vertical_eyes_frown","face_10_x_eyes_frown","face_11_qiangqiang"]}"#, group: .faces, isDestructive: false),
        .init(name: "face_delete", example: #"{"cmd":"face_delete","id":"custom_example"}"#, group: .faces, isDestructive: true),
        .init(name: "face_upsert", example: #"{"cmd":"face_upsert","face":{"id":"custom_example","name":"Example","type":"custom","frameBytes":[0,0,0,0,0,14,32,16,1,2,34,64,0,4,16,128,0,4,0,0,0,8,64,0,0,0,0,134,1,64,158,0,16,32,0,2,4,32,79,0,12,3,0,0,0,0,0]}}"#, group: .faces, isDestructive: false),
        .init(name: "faces_clear_user", example: #"{"cmd":"faces_clear_user"}"#, group: .faces, isDestructive: true),

        // MARK: device
        .init(name: "set_device_name", example: #"{"cmd":"set_device_name","name":"Rina Board"}"#, group: .device, isDestructive: false),
        .init(name: "reboot", example: #"{"cmd":"reboot"}"#, group: .device, isDestructive: true),
        .init(name: "reset_battery_min", example: #"{"cmd":"reset_battery_min"}"#, group: .device, isDestructive: true),
        .init(name: "reset_battery_max", example: #"{"cmd":"reset_battery_max"}"#, group: .device, isDestructive: true),
        .init(name: "battery_overlay", example: #"{"cmd":"battery_overlay","singleShot":true}"#, group: .device, isDestructive: false),

        // MARK: subscription
        .init(name: "subscribe", example: #"{"cmd":"subscribe","preview":true,"status":true,"power":true,"log":false}"#, group: .subscription, isDestructive: false),
        .init(name: "log_subscribe", example: #"{"cmd":"log_subscribe","on":true}"#, group: .subscription, isDestructive: false)
    ]
}
