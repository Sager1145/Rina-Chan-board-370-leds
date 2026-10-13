import CoreWLAN
import Foundation

/// Native macOS code loaded by Catalyst through the shared Objective-C ABI.
/// Initializing this class does not read Wi-Fi state or request permission.
@objc(RinaMacWiFiBridge)
public final class RinaMacWiFiBridge: NSObject, MacWiFiBridgeProtocol {
    private static let associationQueue = DispatchQueue(label: "com.rinachan.board.mac.wifi", qos: .userInitiated)

    public required override init() { super.init() }

    public func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    public func join(ssid: String?, prefix: String, password: String,
                     completion: @escaping @Sendable (String?, NSError?) -> Void) {
        // CoreWLAN scan and association are blocking APIs; serialize them
        // off the main thread. No configuration or preferred profile is saved.
        Self.associationQueue.async {
            do {
                guard let interface = CWWiFiClient.shared().interface() else {
                    throw Self.failure(1, "未找到 Mac Wi-Fi 接口")
                }
                guard interface.powerOn() else {
                    throw Self.failure(2, "请先打开 Mac Wi-Fi")
                }
                if let current = interface.ssid(),
                   ssid.map({ current == $0 }) ?? current.hasPrefix(prefix) {
                    completion(current, nil)
                    return
                }
                let networks = try MacWiFiScanPolicy.networks(forSSID: ssid) {
                    try interface.scanForNetworks(withSSID: $0)
                }
                let matching = networks.filter { network in
                    guard let name = network.ssid else { return false }
                    return ssid.map({ name == $0 }) ?? name.hasPrefix(prefix)
                }
                // Choose the strongest signal for a prefix join. A stable
                // name tie-break keeps equal-strength results predictable.
                guard let network = matching.sorted(by: {
                    if $0.rssiValue != $1.rssiValue { return $0.rssiValue > $1.rssiValue }
                    return ($0.ssid ?? "") < ($1.ssid ?? "")
                }).first, let name = network.ssid else {
                    throw NSError(domain: "com.rinachan.board.mac.wifi", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("未找到璃奈板 Wi-Fi，请确认面板已开启热点并允许定位权限", comment: "Mac Wi-Fi association failure")])
                }
                try interface.associate(to: network, password: password)
                completion(name, nil)
            } catch {
                completion(nil, error as NSError)
            }
        }
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "com.rinachan.board.mac.wifi", code: code,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(message, comment: "Mac Wi-Fi association failure")])
    }
}
