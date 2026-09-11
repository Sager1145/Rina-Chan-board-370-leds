import SwiftUI
import RinaCore

@main
struct RinaBoardApp: App {
    @State private var connection = BoardConnection()
    @State private var boardStore = BoardStore()
    @State private var bleTransport = BLETransport()
    @State private var bootLoader = BootLoaderModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .environment(boardStore)
                .environment(bleTransport)
                .environment(bootLoader)
        }
    }
}
