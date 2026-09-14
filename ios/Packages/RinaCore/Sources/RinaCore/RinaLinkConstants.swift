import Foundation

/// Fixed constants shared by every transport and feature, mirrored from
/// `docs/RINALINK_PROTOCOL_V1.md` and `FEATURE_INVENTORY.md`.
public enum RinaLinkConstants {
    // BLE GATT
    public static let serviceUUID = "52494E41-0001-4C49-4E4B-000000000001"
    public static let rxCharacteristicUUID = "52494E41-0002-4C49-4E4B-000000000001"
    public static let txCharacteristicUUID = "52494E41-0003-4C49-4E4B-000000000001"
    public static let infoCharacteristicUUID = "52494E41-0004-4C49-4E4B-000000000001"

    // TCP / discovery
    public static let tcpPort: UInt16 = 5370
    public static let bonjourType = "_rinalink._tcp"
    public static let bonjourDomain = "local."

    // SoftAP ("hotspot" / direct)
    /// The legacy shared SSID advertised by pre-identity firmware (every
    /// board broadcast the same name). Current firmware advertises a
    /// per-board SSID starting with `apSSIDPrefix` instead.
    public static let apSSID = "RinaChanBoard-V2"
    /// Prefix shared by every board's unique SoftAP SSID
    /// (`RinaChanBoard-<12 uppercase hex>`), used to join whichever board's
    /// hotspot is in range without knowing its exact name in advance.
    public static let apSSIDPrefix = "RinaChanBoard-"
    public static let apPassword = "rinachan"
    public static let apIP = "192.168.1.14"

    // Limits (FEATURE_INVENTORY / RINALINK_PROTOCOL_V1 §3.3)
    public static let maxScrollFrames = 3072
    public static let maxScrollTextBytes = 4096
    public static let maxFaces = 128

    /// Mirrors `MAX_DEVICE_NAME_BYTES` in `esp32s3_firmware/src/config.h`.
    /// This is a UTF-8 *byte* budget, not a character count.
    public static let maxDeviceNameBytes = 24

    public static let brightnessMin = 10
    public static let brightnessMax = 200
    public static let brightnessDefault = 50

    public static let autoIntervalMinMs = 500
    public static let autoIntervalMaxMs = 10000
    public static let autoIntervalDefaultMs = 3000

    public static let scrollFpsMin = 1
    public static let scrollFpsMax = 60
    public static let scrollFpsDefault = 10

    public static let intervalMinMs = 17
    public static let intervalMaxMs = 1000

    public static let blobChunkMaxTCP = 4032

    /// Mirrors `RinaLinkFrameConstants.maxPayloadBytes` (the largest payload a
    /// single frame can carry); exposed here so transports/upload code that
    /// only import the constants surface don't need the codec's internal type.
    public static let maxPayloadBytes = RinaLinkFrameConstants.maxPayloadBytes
}
