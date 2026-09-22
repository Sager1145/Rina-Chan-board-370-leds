import SwiftUI

/// The Apple Watch companion: a remote for the iPhone app's Control Center
/// and Lip Sync. It never pairs with a board — every action goes to the
/// paired iPhone over WatchConnectivity, which runs it against the boards it
/// is connected to (see `WatchLinkService` on the phone side).
@main
struct RinaBoardWatchApp: App {
    @State private var model = WatchSessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .task { model.activate() }
                .onChange(of: scenePhase) { _, phase in
                    // The phone only pushes live updates while we are
                    // reachable, so returning to the foreground re-asks.
                    if phase == .active { model.refresh() }
                }
        }
    }
}
