import SwiftUI
import RinaCore

/// One row per member of the targeted group, in slot order: name, a "主控"
/// badge on the fan-out's current control primary, connection state (with a
/// "连接" button that kicks `GroupAutoConnector` for just that member while
/// it's offline), battery (+ charging indicator), and that member's
/// `GroupControlFanOut.memberErrors` entry if any (user requirements:
/// "显示所有板子的电池信息", "界面显示所有板子的信息，主控需要标出来",
/// "需要显示多条电池信息，连接信息"). Shown at the top of the Control
/// Center's status section in place of the single-board connection/battery
/// rows.
///
/// Member lookup goes through `BoardGroupCoordinator.session(for:)`/
/// `status(for:)`, the same path `BoardControlCenterView.groupMemberRow` and
/// `BoardGroupEditorView.memberRow` already use — `BoardGroup.Member
/// .physicalBoardID` is the stable per-board identity, not a live
/// `BoardSession.boardID` (a BLE UUID/host).
struct GroupMemberStatusList: View {
    let group: BoardGroup

    @Environment(BoardGroupCoordinator.self) private var coordinator
    @Environment(GroupControlFanOut.self) private var fanOut
    @Environment(GroupAutoConnector.self) private var autoConnector
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ForEach(Array(group.members.enumerated()), id: \.element.physicalBoardID) { index, member in
            row(index: index, member: member)
        }
    }

    @ViewBuilder
    private func row(index: Int, member: BoardGroup.Member) -> some View {
        let connection = coordinator.session(for: member)?.connection
        let status = coordinator.status(for: member)
        let isPrimary = member.physicalBoardID == fanOut.primaryID
        let name = connection?.deviceName ?? member.displayName
        let error = fanOut.memberErrors[member.physicalBoardID]

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                header(index: index, name: name, isPrimary: isPrimary)
                statusLine(status, connection: connection, member: member)
                batteryLine(connection)
                errorLine(error)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    header(index: index, name: name, isPrimary: isPrimary)
                    Spacer(minLength: 8)
                    statusLine(status, connection: connection, member: member)
                }
                batteryLine(connection)
                errorLine(error)
            }
        }
    }

    private func header(index: Int, name: String, isPrimary: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1). \(name)")
                .lineLimit(1)
                .truncationMode(.middle)
            if isPrimary {
                Text("主控")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .accessibilityLabel("主控")
            }
        }
    }

    /// Connection state — "连接中"/"已连接"/"离线"/etc — plus a button: "断开"
    /// while connected (calls the same user-disconnect path as the single-
    /// board Control Center, so `GroupAutoConnector` stops redialing this
    /// member), or "连接" while offline, which kicks `GroupAutoConnector` for
    /// just this member instead of waiting out its backoff (user requirement:
    /// "需要显示多条电池信息，连接信息"). No button while a connect is already in
    /// flight. Once actually connected the state text falls back to the
    /// coordinator's richer play-state text ("播放中"/"上传中 N%"/etc), same as
    /// before.
    @ViewBuilder
    private func statusLine(_ status: BoardGroupCoordinator.MemberStatus, connection: BoardConnection?, member: BoardGroup.Member) -> some View {
        HStack(spacing: 8) {
            Text(connectionStateText(status: status, connection: connection, member: member))
                .font(.caption)
                .foregroundStyle(BoardGroupStatusFormatting.color(status))
            switch connection?.connectionState {
            case .connected:
                Button("断开", role: .destructive) {
                    connection?.disconnect(userInitiated: true)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .disconnected, .failed, nil:
                Button("连接") {
                    autoConnector.connectNow(member)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .connecting, .reconnecting:
                EmptyView()
            }
        }
    }

    private func connectionStateText(status: BoardGroupCoordinator.MemberStatus, connection: BoardConnection?, member: BoardGroup.Member) -> String {
        switch connection?.connectionState {
        case .connected: return BoardGroupStatusFormatting.text(status)
        case .connecting, .reconnecting: return "连接中"
        case .disconnected, .failed, nil:
            if autoConnector.isHotspotOnlyMember(member) { return "热点直连的板需手动连接" }
            if autoConnector.hasGivenUp(member) { return "连接失败，点击重试" }
            return "离线"
        }
    }

    @ViewBuilder
    private func batteryLine(_ connection: BoardConnection?) -> some View {
        if let connection {
            HStack(spacing: 6) {
                if connection.isBatteryCharging { Image(systemName: "bolt.fill") }
                Text(batteryText(connection.batteryReading, connectionState: connection.connectionState))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorLine(_ error: String?) -> some View {
        if let error {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private func batteryText(_ reading: BatteryReading?, connectionState: BoardConnectionState) -> String {
        switch reading {
        case .level(let percent): return "\(percent)%"
        case .notDetected: return "未检测到电池"
        case nil: return connectionState == .connected ? "—" : "未连接"
        }
    }
}
