import Foundation

/// This Objective-C ABI is compiled into both the Catalyst app and its
/// native macOS bundle. CoreWLAN itself is unavailable to Catalyst.
@objc(RinaMacWiFiBridgeProtocol)
public protocol MacWiFiBridgeProtocol: NSObjectProtocol {
    init()
    func currentSSID() -> String?
    func join(ssid: String?, prefix: String, password: String,
              completion: @escaping @Sendable (String?, NSError?) -> Void)
}
