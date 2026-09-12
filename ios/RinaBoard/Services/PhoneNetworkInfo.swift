import CoreLocation
import Foundation

/// Reads the iPhone's current Wi-Fi SSID only after an explicit user action.
/// iOS treats this as location-derived information, so the result deliberately
/// distinguishes permission state from "no value returned". A nil SSID never
/// means that the phone is disconnected.
@Observable
@MainActor
public final class PhoneNetworkInfo: NSObject, @preconcurrency CLLocationManagerDelegate {
    public enum SSIDState: Equatable {
        case notRequested
        case requestingPermission
        case reading
        case available(String)
        case permissionDenied
        case preciseLocationRequired
        case unavailable
        case failed(String)
    }

    public private(set) var state: SSIDState = .notRequested

    private let locationManager: CLLocationManager
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    public override init() {
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
    }

    /// Requests the minimum authorization needed by
    /// `NEHotspotNetwork.fetchCurrent`, then reads the SSID. This method is
    /// called from the "读取当前 Wi-Fi" button and nowhere during app launch.
    public func requestCurrentSSID() async {
        guard state != .requestingPermission, state != .reading else { return }

        if locationManager.authorizationStatus == .notDetermined {
            state = .requestingPermission
            await requestWhenInUseAuthorization()
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .denied, .restricted:
            state = .permissionDenied
            return
        case .notDetermined:
            state = .notRequested
            return
        @unknown default:
            state = .failed(NSLocalizedString("无法确认定位权限状态", comment: "unknown location authorization state"))
            return
        }

        if locationManager.accuracyAuthorization != .fullAccuracy {
            state = .requestingPermission
            await requestTemporaryFullAccuracyAuthorization()
            guard locationManager.accuracyAuthorization == .fullAccuracy else {
                state = .preciseLocationRequired
                return
            }
        }

        state = .reading
        if let ssid = await HotspotJoiner.currentSSID(), !ssid.isEmpty {
            state = .available(ssid)
        } else {
            // Apple returns nil for several privacy/capability conditions. Do
            // not turn that ambiguous response into a false "disconnected".
            state = .unavailable
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined,
              let continuation = authorizationContinuation else { return }
        authorizationContinuation = nil
        continuation.resume()
    }

    private func requestWhenInUseAuthorization() async {
        await withCheckedContinuation { continuation in
            authorizationContinuation?.resume()
            authorizationContinuation = continuation
            locationManager.requestWhenInUseAuthorization()
        }
    }

    private func requestTemporaryFullAccuracyAuthorization() async {
        await withCheckedContinuation { continuation in
            locationManager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: "ReadCurrentWiFiSSID"
            ) { _ in
                continuation.resume()
            }
        }
    }
}
