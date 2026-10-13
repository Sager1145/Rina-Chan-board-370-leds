import UIKit

/// The outer phone display stays portrait; Duo's inner display can rotate.
enum RinaPhoneOrientationPolicy {
    static func mask(displaySize: CGSize, idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        idiom == .phone && min(displaySize.width, displaySize.height) < 600 ? .portrait : .all
    }

    @MainActor
    static func updateConnectedScenes() {
        #if !targetEnvironment(macCatalyst)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if mask(displaySize: scene.screen.bounds.size, idiom: .phone) == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
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
        guard let window else { return .all }
        return RinaPhoneOrientationPolicy.mask(displaySize: window.screen.bounds.size,
                                               idiom: window.traitCollection.userInterfaceIdiom)
        #endif
    }
}
