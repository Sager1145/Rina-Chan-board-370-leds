#if targetEnvironment(macCatalyst) || os(macOS)
import Foundation

@MainActor
final class MacWiFiAdapter {
    enum JoinError: Error, LocalizedError, Equatable {
        case bridgeUnavailable
        case ssidUnavailable
        case unexpectedNetwork
        case locationPermissionDenied
        case preciseLocationRequired
        case locationPermissionUnavailable

        var errorDescription: String? {
            switch self {
            case .bridgeUnavailable:
                NSLocalizedString("无法加载 Mac Wi-Fi 连接组件", comment: "Mac Wi-Fi bridge missing")
            case .ssidUnavailable:
                NSLocalizedString("无法确认已连接的 Wi-Fi 名称，请检查定位权限", comment: "Mac Wi-Fi SSID unavailable")
            case .unexpectedNetwork:
                NSLocalizedString("当前 Wi-Fi 与选择的璃奈板不一致", comment: "Mac Wi-Fi identity mismatch")
            case .locationPermissionDenied:
                NSLocalizedString("连接璃奈板 Wi-Fi 需要定位权限，请在系统设置中允许", comment: "Mac Wi-Fi location permission denied")
            case .preciseLocationRequired:
                NSLocalizedString("连接璃奈板 Wi-Fi 需要精确定位权限", comment: "Mac Wi-Fi precise location required")
            case .locationPermissionUnavailable:
                NSLocalizedString("无法确认定位权限状态", comment: "Mac Wi-Fi location permission unavailable")
            }
        }
    }

    private let bridge: any MacWiFiBridgeProtocol

    init(bridge: any MacWiFiBridgeProtocol) { self.bridge = bridge }

    static func load(from appBundle: Bundle = .main) throws -> MacWiFiAdapter {
        guard let plugins = appBundle.builtInPlugInsURL,
              let bundle = Bundle(url: plugins.appendingPathComponent("RinaMacWiFiBridge.bundle")),
              let bridgeClass = bundle.principalClass as? any MacWiFiBridgeProtocol.Type else {
            throw JoinError.bridgeUnavailable
        }
        return MacWiFiAdapter(bridge: bridgeClass.init())
    }

    /// Passive reads never request Location Services authorization.
    func currentSSID() -> String? { bridge.currentSSID() }

    func join(ssid: String?, prefix: String, password: String) async throws -> String {
        try Task.checkCancellation()
        let joined: String = try await withCheckedThrowingContinuation { continuation in
            bridge.join(ssid: ssid, prefix: prefix, password: password) { joined, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let joined, !joined.isEmpty {
                    continuation.resume(returning: joined)
                } else {
                    continuation.resume(throwing: JoinError.ssidUnavailable)
                }
            }
        }
        try Task.checkCancellation()
        guard ssid.map({ joined == $0 }) ?? joined.hasPrefix(prefix) else {
            throw JoinError.unexpectedNetwork
        }
        return joined
    }
}
#endif
