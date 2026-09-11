import SwiftUI
import RinaCore

struct RootView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Environment(BLETransport.self) private var bleTransport
    @Environment(BootLoaderModel.self) private var bootLoader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didAutoReconnect = false

    var body: some View {
        ZStack {
            TabView {
                ControlView()
                    .tabItem { Label("控制", systemImage: "slider.horizontal.3") }

                FacesView()
                    .tabItem { Label("表情", systemImage: "face.smiling") }

                DebugView()
                    .tabItem { Label("调试", systemImage: "ladybug") }

                ConnectionView()
                    .tabItem { Label("连接", systemImage: "antenna.radiowaves.left.and.right") }
            }
            .tint(Color("AccentColor"))
            .task {
                // Board status fetch begins only after the loader is gone.
                await bootLoader.waitUntilDone()
                await autoReconnect()
            }

            if bootLoader.isVisible {
                BootLoaderOverlay()
            }
        }
        .onAppear {
            bootLoader.reduceMotion = reduceMotion
            bootLoader.start()
        }
    }

    /// D8/E5: on launch, try to reconnect to the most recently used board via
    /// its remembered preferred transport. Runs at most once per app launch;
    /// BLE readiness (waiting for `.poweredOn`) is handled inside
    /// `BLETransport.connect()` itself, so this never needs to throw before
    /// the central manager is ready.
    private func autoReconnect() async {
        guard !didAutoReconnect else { return }
        didAutoReconnect = true
        guard connection.connectionState == .disconnected else { return }
        guard let last = boardStore.boards.max(by: { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }) else { return }
        switch last.preferredTransport {
        case "bluetooth":
            guard let uuid = UUID(uuidString: last.id) else { return }
            bleTransport.peripheralIdentifier = uuid
            await connection.connect(using: bleTransport)
        case "wifi", "hotspot":
            guard let host = last.lastHost else { return }
            let kind: TransportKind = last.preferredTransport == "hotspot" ? .hotspot : .wifi(host: host, port: RinaLinkConstants.tcpPort)
            let transport = TCPTransport(host: host, kind: kind)
            await connection.connect(using: transport)
        default:
            break
        }
    }
}

// No #Preview: RootView requires a live BLETransport (backed by a real
// CBCentralManager), which isn't safe/meaningful to construct in the
// Xcode Previews sandbox (H7 / preview cleanup).
