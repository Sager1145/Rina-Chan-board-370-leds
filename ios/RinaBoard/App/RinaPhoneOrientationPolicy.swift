import UIKit

/// The outer phone display stays portrait; Duo's inner display can rotate.
enum RinaPhoneOrientationPolicy {
    static func mask(displaySize: CGSize?, idiom: UIUserInterfaceIdiom,
                     innerDisplay: Bool? = nil, folded: Bool = false) -> UIInterfaceOrientationMask {
        guard idiom == .phone else { return .all }
        if folded { return .portrait }
        if let innerDisplay { return innerDisplay ? .all : .portrait }
        guard let displaySize else { return .portrait }
        return min(displaySize.width, displaySize.height) < 600 ? .portrait : .all
    }

    @MainActor private static var sceneMasks: [String: UIInterfaceOrientationMask] = [:]

    @MainActor
    static func mask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        let scene = window?.windowScene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        if let scene, let observed = sceneMasks[scene.session.persistentIdentifier] {
            return observed
        }
        return mask(displaySize: window?.screen.bounds.size ?? scene?.screen.bounds.size,
                    idiom: window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom)
    }

    @MainActor
    static func updateConnectedScenes(innerDisplay: Bool, folded: Bool) {
        #if !targetEnvironment(macCatalyst)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
            where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
            let supported = mask(displaySize: scene.screen.bounds.size, idiom: .phone,
                                 innerDisplay: innerDisplay, folded: folded)
            sceneMasks[scene.session.persistentIdentifier] = supported
            // Refresh the app controller, excluding keyboard and accessibility
            // windows, which have independent orientation policies.
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            // Supported orientations are sufficient on the outer display.
            // Do not leave a programmatic portrait geometry preference attached
            // to a scene that is about to move to the resizable inner display.
        }
        #endif
    }
}

@MainActor
final class RinaOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if targetEnvironment(macCatalyst)
        return .all
        #else
        return RinaPhoneOrientationPolicy.mask(for: window)
        #endif
    }
}
