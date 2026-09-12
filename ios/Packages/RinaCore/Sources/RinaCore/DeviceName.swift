import Foundation

/// Validation for the board's custom display name (`set_device_name`,
/// `RINALINK_PROTOCOL_V1`). The firmware enforces `MAX_DEVICE_NAME_BYTES` in
/// UTF-8 *bytes* (mirrored as `RinaLinkConstants.maxDeviceNameBytes`); an
/// empty (or whitespace-only) name is legal and means "reset to the
/// MAC-derived default".
public enum DeviceNameValidation: Sendable, Equatable {
    case valid
    case tooLong(bytes: Int)
    case empty
}

public enum DeviceNameValidator {
    /// Trims leading/trailing whitespace, then classifies the result.
    public static func validateDeviceName(_ name: String) -> DeviceNameValidation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }
        let byteCount = trimmed.utf8.count
        if byteCount > RinaLinkConstants.maxDeviceNameBytes {
            return .tooLong(bytes: byteCount)
        }
        return .valid
    }
}
