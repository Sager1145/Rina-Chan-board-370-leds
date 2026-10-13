import CoreBluetooth
import Foundation
import RinaCore
import XCTest
@testable import RinaBoard

#if targetEnvironment(macCatalyst)
/// Explicitly opted-in real hardware coverage of the shared iPad/Mac carrier.
@MainActor
final class MacBoardHardwareTests: XCTestCase {
    private let boardIDs = ["80B54EF48E09", "80B54EF74801"]

    @MainActor
    private final class Rig {
        let id: String
        let transport = BLETransport()
        let connection = BoardConnection()
        var savedBrightness: Int?
        var restoreBrightness = false
        init(id: String) { self.id = id }
    }

    func testBothBoardsThroughProductionBLEAndRestoreOutput() async throws {
        guard ProcessInfo.processInfo.environment["RINA_MAC_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set RINA_MAC_HARDWARE_TESTS=1 to test the two physical boards")
        }
        let rigs = boardIDs.map { Rig(id: $0) }
        let scanner = rigs[0].transport
        defer {
            for rig in rigs {
                rig.connection.disconnect(userInitiated: true)
                rig.transport.stopScan()
            }
        }
        var testError: Error?
        do {
            let deadline = Date().addingTimeInterval(35)
            while !scanner.isScanning {
                try Task.checkCancellation()
                if CBManager.authorization == .denied || CBManager.authorization == .restricted {
                    throw HardwareFailure("Bluetooth permission denied for the Mac test host")
                }
                scanner.startScan()
                guard Date() < deadline else {
                    throw HardwareFailure("Bluetooth did not become ready: \(scanner.lastError ?? "unknown")")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            var found: [String: UUID] = [:]
            while found.count < rigs.count {
                try Task.checkCancellation()
                for rig in rigs {
                    if let device = scanner.discoveredPeripherals.first(where: {
                        $0.advertisedName == "RinaBoard-\(rig.id)"
                    }) { found[rig.id] = device.id }
                }
                guard Date() < deadline else {
                    throw HardwareFailure("Exact board advertisements missing: \(boardIDs.filter { found[$0] == nil })")
                }
                if found.count < rigs.count { try await Task.sleep(for: .milliseconds(100)) }
            }
            scanner.stopScan()
            for rig in rigs {
                rig.transport.peripheralIdentifier = found[rig.id]
                guard await rig.connection.connect(using: rig.transport) else {
                    throw HardwareFailure("\(rig.id) handshake failed: \(rig.connection.lastError ?? "unknown")")
                }
                guard rig.connection.boardIdentity == rig.id else {
                    throw HardwareFailure("Hardware identity mismatch for \(rig.id)")
                }
                let info = try await rig.connection.command(.getInfo)
                guard info.ok, info.defaultName == "RinaBoard-\(rig.id)" else {
                    throw HardwareFailure("GET_INFO identity mismatch for \(rig.id)")
                }
                let status = try await rig.connection.getStatus()
                guard status.wifi?.boardId?.uppercased() == rig.id, status.power != nil else {
                    throw HardwareFailure("Status identity/power missing for \(rig.id)")
                }
                let powerFrame = try await rig.connection.send(type: .getPower, payload: Data())
                let power = try JSONDecoder().decode(PowerStatus.self, from: powerFrame.payload)
                let envelope = try JSONSerialization.jsonObject(with: powerFrame.payload) as? [String: Any]
                guard envelope?["ok"] as? Bool == true,
                      power.batteryValid != nil || power.chargeValid != nil else {
                    throw HardwareFailure("GET_POWER rejected or missing telemetry for \(rig.id)")
                }
                _ = try await rig.connection.getFrame()
                rig.savedBrightness = try XCTUnwrap(status.renderer?.brightness)
            }
            // Both carriers must stay ready while addressing the other board.
            guard rigs.allSatisfy({ $0.connection.connectionState == .connected }) else {
                throw HardwareFailure("Both BLE links did not remain connected")
            }
            for rig in rigs {
                let status = try await rig.connection.getStatus()
                guard status.renderer?.brightness == rig.savedBrightness else {
                    throw HardwareFailure("\(rig.id) brightness changed before reversible coverage")
                }
                let oldBrightness = try XCTUnwrap(rig.savedBrightness)
                let minimum = try XCTUnwrap(status.renderer?.brightnessMin)
                let maximum = try XCTUnwrap(status.renderer?.brightnessMax)
                guard minimum < maximum, (minimum...maximum).contains(oldBrightness) else {
                    throw HardwareFailure("Invalid brightness range for \(rig.id)")
                }
                let probe = oldBrightness == minimum ? oldBrightness + 1 : oldBrightness - 1
                rig.restoreBrightness = true // A timed-out command may already apply.
                let reply = try await rig.connection.command(.setBrightness(raw: probe))
                guard reply.ok else { throw HardwareFailure("Brightness command rejected for \(rig.id)") }
                let actual = try await rig.connection.getStatus()
                guard actual.renderer?.brightness == probe else {
                    throw HardwareFailure("Brightness exact readback failed for \(rig.id)")
                }
            }
        } catch { testError = error }

        // Detached cleanup is independent of the test task's cancellation.
        // Retain the owned carriers until terminal callbacks finish.
        let cleanup = Task.detached { @MainActor in
            var failures: [String] = []
            for rig in rigs {
                if rig.restoreBrightness, let brightness = rig.savedBrightness {
                    do {
                        let reply = try await rig.connection.command(.setBrightness(raw: brightness))
                        let actual = try await rig.connection.getStatus()
                        if !reply.ok || actual.renderer?.brightness != brightness {
                            failures.append("\(rig.id): restored brightness mismatch")
                        } else {
                            print("[MacBoardHardwareTests] \(rig.id) originalBrightnessRestored=true")
                        }
                    } catch { failures.append("\(rig.id): brightness restoration failed: \(error)") }
                }
                do {
                    // Cancel the owner first to suppress reconnect. BLETransport
                    // retains cancelling peripherals until terminal callbacks.
                    rig.connection.disconnect(userInitiated: true)
                    let confirmed = try await rig.transport.disconnectAndWait(timeout: 8)
                    if !confirmed { failures.append("\(rig.id): terminal BLE disconnect unconfirmed") }
                    print("[MacBoardHardwareTests] \(rig.id) terminalDisconnectConfirmed=\(confirmed)")
                } catch {
                    rig.connection.disconnect(userInitiated: true)
                    failures.append("\(rig.id): disconnect wait failed: \(error)")
                }
            }
            return failures
        }
        let failures = await cleanup.value
        for failure in failures { XCTFail(failure) }
        if let testError { throw testError }
        guard failures.isEmpty else { throw HardwareFailure("Hardware cleanup failed") }
    }

    private struct HardwareFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
