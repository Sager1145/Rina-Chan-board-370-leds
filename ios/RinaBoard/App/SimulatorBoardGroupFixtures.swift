#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Opt-in local fixtures. Connections still use TCPTransport and the normal
/// handshake, upload, clock sync and group playback paths.
@MainActor
enum SimulatorBoardGroupFixtures {
    static let configurations: [(name: String, count: Int, mode: BoardGroup.Mode)] = [
        ("Test · 2 boards", 2, .stitched),
        ("Test · 3 boards", 3, .stitched),
        ("Test · 5 boards", 5, .stitched),
        ("Test · 3 mirrors", 3, .mirror)
    ]

    static func seed(in store: BoardGroupStore) {
        for configuration in configurations where !store.groups.contains(where: { $0.name == configuration.name }) {
            let group = store.create(name: configuration.name)
            for index in 1...configuration.count {
                let host = "127.0.0.\(index)"
                try? store.addMember(groupID: group.id, member: .init(
                    physicalBoardID: "EMU-\(host)", displayName: "Test board \(index)", knownBoardIDs: [host]))
            }
            store.setMode(id: group.id, mode: configuration.mode)
            if configuration.mode == .stitched {
                for slot in 0..<(configuration.count - 1) {
                    try? store.setGap(groupID: group.id, afterSlot: slot, columns: 2)
                }
            }
        }
    }

    static func argument(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-\(key)"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var requested: Bool { argument("seedTestGroups") == "YES" }

    static func prepare(store: BoardGroupStore, sessions: BoardSessionStore,
                        coordinator: BoardGroupCoordinator, textModel: TextViewModel) async {
        guard requested, argument("connectTestBoards") == "YES" else { return }
        let port = argument("testBoardPort").flatMap(UInt16.init) ?? 15370
        for index in 1...5 {
            let host = "127.0.0.\(index)"
            let session = sessions.session(for: "simulator-test-board-\(index)", name: "Test board \(index)")
            let connected = await session.connection.connect(using: TCPTransport(host: "127.0.0.1", port: port + UInt16(index - 1)),
                                                             expectedBoardIdentity: "EMU-\(host)")
            guard connected else {
                textModel.errorMessage = "Test board \(index): \(session.connection.lastError ?? "connection failed")"
                return
            }
        }
        guard argument("playTestGroup") == "YES",
              let group = store.groups.first(where: { $0.name == argument("testGroupName") }) else { return }
        do {
            textModel.text = "RINA 123 ABC"
            textModel.userEditedText = true
            textModel.requestedFps = 30
            textModel.loopPlayback = true
            try await coordinator.play(group: group, text: textModel.text, fps: 30, loop: true)
            if argument("pauseTestGroup") == "YES" {
                // The timeline begins with a blank entrance. Pause after the
                // first glyph enters, so the fixture tests a visible held frame.
                let deadline = Date().addingTimeInterval(3)
                while (coordinator.previewFrame() ?? 0) < 12, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                await coordinator.pause(group: group)
            }
        } catch {
            textModel.errorMessage = "Test group: \(error.localizedDescription)"
        }
    }
}
#endif
