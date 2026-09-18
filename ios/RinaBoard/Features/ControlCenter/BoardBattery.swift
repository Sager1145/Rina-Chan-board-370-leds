import SwiftUI
import RinaCore

/// What the board's battery is showing, shared by the collapsed accessory's
/// ring (iPhone) and the Control Center's battery bar (the sheet, and the iPad
/// preview column), so the two can never disagree.
enum BatteryReading: Equatable {
    case level(Int)
    case notDetected
}

extension BoardConnection {
    /// The battery as the UI should show it, or `nil` when there is nothing to
    /// show yet (not connected, or no power report so far).
    ///
    /// The firmware reports `batteryPercent: 0` both when the reading is
    /// invalid and when the battery is unplugged or too low to be powering the
    /// board — the latter two with `batteryValid` still true — so all three
    /// count as "no battery detected" rather than an empty battery.
    var batteryReading: BatteryReading? {
        guard connectionState == .connected, let power = currentPower else { return nil }
        if power.batteryValid == false
            || power.batteryDisconnected == true
            || power.batteryLowVoltageUnpowered == true {
            return .notDetected
        }
        return power.batteryPercent.map { .level(min(100, max(0, $0))) }
    }

    var isBatteryCharging: Bool {
        connectionState == .connected && currentPower?.charging == true
    }

    /// The power event only arrives once a second; the status echo carries the
    /// same object, so fall back to it rather than wait.
    private var currentPower: PowerStatus? { power ?? status?.power }
}

/// One Control Center row: 电量, a capacity bar, and the percentage. Always
/// the same height whatever the state, so the controls below it never shift
/// when a power report arrives or the board disconnects.
struct BoardBatteryRow: View {
    @Environment(BoardConnection.self) private var environmentConnection
    private let explicitConnection: BoardConnection?

    private var connection: BoardConnection { explicitConnection ?? environmentConnection }

    /// Reads the connection from the environment (the ordinary single-board
    /// Control Center path).
    init() {
        self.explicitConnection = nil
    }

    /// Reads a specific connection directly, for callers (the group member
    /// list) that show more than one board's battery in the same screen and
    /// so can't rely on a single environment value.
    init(connection: BoardConnection) {
        self.explicitConnection = connection
    }

    var body: some View {
        let reading = connection.batteryReading
        let charging = connection.isBatteryCharging
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("剩余电量") {
                // Not a `Label`: inside a List row a Label gets the
                // leading-icon layout, which sizes the wide battery glyph as a
                // row icon and makes this row taller than its neighbours.
                HStack(spacing: 6) {
                    if charging { Image(systemName: "bolt.fill") }
                    valueText(reading)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
            Gauge(value: Double(percent(reading)), in: 0...100) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(tint(reading))
            .labelsHidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("剩余电量")
        .accessibilityValue(accessibilityValue(reading, charging: charging))
        .animation(.snappy, value: reading)
    }

    private func percent(_ reading: BatteryReading?) -> Int {
        if case .level(let percent) = reading { return percent }
        return 0
    }

    /// Red at 20% and below, like the accessory's ring.
    private func tint(_ reading: BatteryReading?) -> Color {
        if case .level(let percent) = reading, percent > 20 { return .green }
        return .red
    }

    @ViewBuilder
    private func valueText(_ reading: BatteryReading?) -> some View {
        switch reading {
        case .level(let percent): Text("\(percent)%")
        case .notDetected: Text("未检测到电池")
        case nil:
            if connection.connectionState == .connected {
                // Connected, first power report still on its way.
                Text(verbatim: "—")
            } else {
                Text("未连接")
            }
        }
    }

    private func accessibilityValue(_ reading: BatteryReading?, charging: Bool) -> Text {
        switch reading {
        case .level(let percent): charging ? Text("\(percent)% 充电中") : Text("\(percent)%")
        case .notDetected: Text("未检测到电池")
        case nil: connection.connectionState == .connected ? Text(verbatim: "—") : Text("未连接")
        }
    }
}

/// A battery glyph plus the percentage, for places that list several boards
/// (the group member list, the group editor) so every board shows an icon,
/// not just a number. The fill tracks the level to the percent (not SF
/// Symbols' five steps). Red at 20% and below, like the accessory's ring.
struct BoardBatteryLabel: View {
    let reading: BatteryReading?
    let charging: Bool
    let connectionState: BoardConnectionState

    var body: some View {
        HStack(spacing: 4) {
            BatteryGlyph(level: level, fill: fillColor, charging: charging)
            Text(text)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("剩余电量")
        .accessibilityValue(charging ? "\(text) 充电中" : text)
        .animation(.snappy, value: reading)
    }

    private var level: Double {
        if case .level(let percent) = reading { return Double(percent) / 100 }
        return 0
    }

    private var fillColor: Color {
        guard case .level(let percent) = reading else { return .secondary }
        if charging { return .green }
        return percent > 20 ? .secondary : .red
    }

    private var text: String {
        switch reading {
        case .level(let percent): return "\(percent)%"
        case .notDetected: return String(localized: "未检测到电池")
        case nil:
            return connectionState == .connected ? "—" : String(localized: "未连接")
        }
    }
}

/// A horizontal battery outline whose inner bar is `level` (0...1) of the
/// full width, sized with the surrounding text.
private struct BatteryGlyph: View {
    var level: Double
    var fill: Color
    var charging: Bool

    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 10

    var body: some View {
        let width = height * 2.1
        let line = max(1, height / 10)
        let inset = line * 2
        HStack(spacing: line) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.28)
                    .strokeBorder(.secondary.opacity(0.6), lineWidth: line)
                RoundedRectangle(cornerRadius: height * 0.16)
                    .fill(fill)
                    .frame(width: max(0, (width - inset * 2) * min(1, max(0, level))))
                    .padding(inset)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.8, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: line)
                .fill(.secondary.opacity(0.6))
                .frame(width: line * 1.5, height: height * 0.4)
        }
    }
}
