import Foundation
import WatchConnectivity

/// The `WCSessionDelegate` both apps install. WatchConnectivity calls its
/// delegate on a private background queue, so this object stays
/// `nonisolated`, unwraps the envelope there, and hands the owning
/// `@MainActor` model plain `Data` plus a `@Sendable` reply closure — nothing
/// non-Sendable ever crosses the actor hop.
final class WatchLinkSessionRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    typealias Reply = @Sendable (Data) -> Void

    /// A message (a command on the phone, a pushed snapshot on the watch).
    /// `reply` is non-nil only when the sender is waiting for an answer.
    var onPayload: (@Sendable (Data, Reply?) -> Void)?
    /// The watch side: the latest `applicationContext` the phone published.
    var onContext: (@Sendable (Data) -> Void)?
    /// Activation, reachability, and (on iOS) pairing/install changes.
    var onStateChange: (@Sendable () -> Void)?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        onStateChange?()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onStateChange?()
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A watch switch: the session must be re-activated for the new watch.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        onStateChange?()
    }
    #endif

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = WatchLinkCodec.payload(in: message) else { return }
        onPayload?(data, nil)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = WatchLinkCodec.payload(in: message) else {
            replyHandler([:])
            return
        }
        // The reply block is a plain (non-Sendable) closure handed to us on
        // WatchConnectivity's queue; it is only ever invoked once, from the
        // wrapper below, which is what makes this unsafe-capture sound.
        nonisolated(unsafe) let handler = replyHandler
        onPayload?(data) { reply in handler(WatchLinkCodec.envelope(reply)) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = WatchLinkCodec.payload(in: applicationContext) else { return }
        onContext?(data)
    }
}
