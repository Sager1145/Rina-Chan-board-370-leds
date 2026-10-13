#if targetEnvironment(macCatalyst) || os(macOS)
import Foundation

enum MacWiFiScanPolicy {
    /// A directed miss gets one broadcast scan; callers still match the selected SSID.
    static func networks<Result: Collection>(
        forSSID ssid: String?,
        scan: (Data?) throws -> Result
    ) throws -> Result {
        let networks = try scan(ssid.map { Data($0.utf8) })
        if ssid != nil, networks.isEmpty {
            return try scan(nil)
        }
        return networks
    }
}
#endif
