import Foundation
import NetworkExtension
import RinaCore

/// Joins the board's SoftAP (`RinaChanBoard-V2` / `rinachan`) via
/// `NEHotspotConfiguration` (§E4). Requires the Hotspot Configuration
/// entitlement.
public enum HotspotJoiner {
    public static func join(
        ssid: String = RinaLinkConstants.apSSID,
        password: String = RinaLinkConstants.apPassword
    ) async throws {
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error {
                    // "already associated" is not a real failure.
                    let nsError = error as NSError
                    if nsError.domain == NEHotspotConfigurationErrorDomain,
                       nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume()
                }
            }
        }
        // H5: `apply`'s completion fires as soon as the configuration is
        // installed, not once the device has actually associated with the
        // SSID. Poll the currently-joined hotspot network until it matches.
        try await waitForAssociation(ssid: ssid)
    }

    private static func waitForAssociation(ssid: String, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let current = await currentSSID(), current == ssid {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RinaTransportError.timeout
    }

    /// The system returns nil when it cannot disclose the current network.
    /// Callers must preserve that ambiguity rather than treating it as an
    /// assertion that the phone has no Wi-Fi connection.
    public static func currentSSID() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    public static func makeTransport() -> TCPTransport {
        TCPTransport(host: RinaLinkConstants.apIP, port: RinaLinkConstants.tcpPort, kind: .hotspot)
    }
}
