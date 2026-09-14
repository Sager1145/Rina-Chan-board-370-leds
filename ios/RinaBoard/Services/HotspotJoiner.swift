import Foundation
import NetworkExtension
import RinaCore

/// Joins a board's SoftAP via `NEHotspotConfiguration` (§E4). Requires the
/// Hotspot Configuration entitlement. Current firmware advertises a unique
/// SSID per board (`RinaChanBoard-<12 uppercase hex>`); pass `ssid: nil` to
/// join whichever such board is in range by prefix, or a specific SSID
/// (including the legacy shared `RinaLinkConstants.apSSID`) to join exactly
/// that board.
public enum HotspotJoiner {
    /// The SSID this joiner most recently confirmed association with, shared
    /// across every call site so views that don't own the join can still
    /// identify which board's hotspot is currently active.
    public private(set) static var lastJoinedSSID: String?

    @discardableResult
    public static func join(
        ssid: String? = nil,
        password: String = RinaLinkConstants.apPassword
    ) async throws -> String {
        let configuration: NEHotspotConfiguration
        if let ssid {
            configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        } else {
            configuration = NEHotspotConfiguration(ssidPrefix: RinaLinkConstants.apSSIDPrefix, passphrase: password, isWEP: false)
        }
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
        let joined = try await waitForAssociation(ssid: ssid)
        lastJoinedSSID = joined
        return joined
    }

    /// Waits for association, returning the SSID actually joined. When `ssid`
    /// is nil (prefix join), any currently-joined SSID with the board prefix
    /// satisfies the wait. Throws `RinaTransportError.timeout` rather than
    /// returning nil, so a successful return is always a concrete SSID.
    private static func waitForAssociation(ssid: String?, timeout: TimeInterval = 15) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let current = await currentSSID() {
                if let ssid {
                    if current == ssid { return current }
                } else if current.hasPrefix(RinaLinkConstants.apSSIDPrefix) {
                    return current
                }
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

    /// Re-reads the phone's actual current SSID and reconciles `lastJoinedSSID`
    /// with it. Every board's SoftAP shares one IP, so a cache that drifted
    /// from reality (e.g. iOS silently re-associated with a *different*
    /// remembered board hotspot, or the phone left the board's AP for another
    /// network) would otherwise misattribute a rename or a Control Center
    /// selection to the wrong saved board. Call this before writing into a
    /// saved record and whenever a hotspot-relevant view (re)appears.
    @discardableResult
    public static func revalidateLastJoinedSSID() async -> String? {
        guard let current = await currentSSID() else {
            // `nil` is ambiguous (iOS declining to disclose the network), not
            // proof the phone left the hotspot — leave the cache alone.
            return lastJoinedSSID
        }
        if current.hasPrefix(RinaLinkConstants.apSSIDPrefix) {
            lastJoinedSSID = current
        } else {
            // A concrete, non-board SSID means the phone is no longer on any
            // board's hotspot; do not keep attributing state to a stale one.
            lastJoinedSSID = nil
        }
        return lastJoinedSSID
    }
}
