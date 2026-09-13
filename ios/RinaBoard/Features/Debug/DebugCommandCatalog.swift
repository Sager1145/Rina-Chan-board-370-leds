import Foundation

/// A ready-to-send RinaLink `CMD` JSON payload for the Serial Monitor.
struct DebugCommandTemplate: Identifiable {
    let name: String
    let example: String

    var id: String { name }
}

/// Commands accepted by `esp32s3_firmware/src/protocol.cpp` over BLE or Wi-Fi.
/// Examples are CMD payloads, not USB serial-console commands or RinaLink frames.
enum DebugCommandCatalog {
    static let commands: [DebugCommandTemplate] = [
        .init(name: "set_color", example: ##"{"cmd":"set_color","hex":"#EC3FC7"}"##),
        .init(name: "set_brightness", example: #"{"cmd":"set_brightness","raw":80}"#),
        .init(name: "set_mode", example: #"{"cmd":"set_mode","mode":"manual"}"#),
        .init(name: "set_auto_interval", example: #"{"cmd":"set_auto_interval","ms":5000}"#),
        .init(name: "set_scroll_interval", example: #"{"cmd":"set_scroll_interval","intervalMs":100}"#),
        .init(name: "start_scroll", example: #"{"cmd":"start_scroll","intervalMs":100,"sourceText":"Hello","loop":true}"#),
        .init(name: "scroll_step", example: #"{"cmd":"scroll_step","direction":1}"#),
        .init(name: "scroll_seek", example: #"{"cmd":"scroll_seek","frameIndex":0}"#),
        .init(name: "set_scroll_loop", example: #"{"cmd":"set_scroll_loop","loop":false}"#),
        .init(name: "pause_scroll", example: #"{"cmd":"pause_scroll"}"#),
        .init(name: "resume_scroll", example: #"{"cmd":"resume_scroll"}"#),
        .init(name: "stop_scroll", example: #"{"cmd":"stop_scroll","restoreAuto":false,"clear":true}"#),
        .init(name: "pause", example: #"{"cmd":"pause"}"#),
        .init(name: "resume", example: #"{"cmd":"resume"}"#),
        .init(name: "apply_saved_face", example: #"{"cmd":"apply_saved_face","index":0,"reason":"debug","playback":"idle"}"#),
        .init(name: "button", example: #"{"cmd":"button","button":"B3"}"#),
        .init(name: "terminate_other_activities", example: #"{"cmd":"terminate_other_activities","targetMode":"manual"}"#),
        .init(name: "reset_battery_min", example: #"{"cmd":"reset_battery_min"}"#),
        .init(name: "reset_battery_max", example: #"{"cmd":"reset_battery_max"}"#),
        .init(name: "battery_overlay", example: #"{"cmd":"battery_overlay","singleShot":true}"#),

        .init(name: "reboot", example: #"{"cmd":"reboot"}"#),
        .init(name: "get_info", example: #"{"cmd":"get_info"}"#),
        .init(name: "subscribe", example: #"{"cmd":"subscribe","preview":true,"status":true,"power":true,"log":false}"#),
        .init(name: "log_subscribe", example: #"{"cmd":"log_subscribe","on":true}"#),

        .init(name: "wifi_status", example: #"{"cmd":"wifi_status"}"#),
        .init(name: "wifi_scan", example: #"{"cmd":"wifi_scan"}"#),
        .init(name: "wifi_scan_result", example: #"{"cmd":"wifi_scan_result"}"#),
        .init(name: "wifi_set_credentials", example: #"{"cmd":"wifi_set_credentials","ssid":"Home Wi-Fi","password":"password123"}"#),
        .init(name: "wifi_clear_credentials", example: #"{"cmd":"wifi_clear_credentials"}"#),
        .init(name: "wifi_set_hotspot_credentials", example: #"{"cmd":"wifi_set_hotspot_credentials","ssid":"My iPhone","password":"password123"}"#),
        .init(name: "wifi_clear_hotspot_credentials", example: #"{"cmd":"wifi_clear_hotspot_credentials"}"#),
        .init(name: "wifi_set_mode", example: #"{"cmd":"wifi_set_mode","mode":"sta_or_ap"}"#),
        .init(name: "wifi_connect", example: #"{"cmd":"wifi_connect"}"#),
        .init(name: "wifi_set_ap", example: #"{"cmd":"wifi_set_ap","ssid":"RinaChanBoard-V2","password":"rinachan"}"#),

        .init(name: "face_rename", example: #"{"cmd":"face_rename","id":"face_01_surprised_winking_with_mouth","name":"Wink"}"#),
        .init(name: "face_reorder", example: #"{"cmd":"face_reorder","ids":["face_01_surprised_winking_with_mouth","face_02_glasses_eyed_square_mouth","face_03_confused_raised_eyebrows","face_04_sad_diagonal_eyes_downturned_mouth","face_05_neutral_blocky_eyes_smirk","face_06_squinting_happy","face_07_wide_eyebrows_tiny_mouth","face_08_triangle_eyes_frown","face_09_stoic_vertical_eyes_frown","face_10_x_eyes_frown","face_11_qiangqiang"]}"#),
        .init(name: "face_delete", example: #"{"cmd":"face_delete","id":"custom_example"}"#),
        .init(name: "face_upsert", example: #"{"cmd":"face_upsert","face":{"id":"custom_example","name":"Example","type":"custom","frameBytes":[0,0,0,0,0,14,32,16,1,2,34,64,0,4,16,128,0,4,0,0,0,8,64,0,0,0,0,134,1,64,158,0,16,32,0,2,4,32,79,0,12,3,0,0,0,0,0]}}"#),
        .init(name: "faces_clear_user", example: #"{"cmd":"faces_clear_user"}"#),

        .init(name: "set_device_name", example: #"{"cmd":"set_device_name","name":"Rina Board"}"#)
    ]
}
