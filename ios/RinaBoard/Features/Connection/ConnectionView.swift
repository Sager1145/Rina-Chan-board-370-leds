import SwiftUI
import RinaCore

/// "连接" category (FEATURE_INVENTORY §E): which board the app is controlling
/// and every board it knows about. Adding a board and a board's own Wi-Fi
/// settings are their own Settings categories (`AddBoardView`,
/// `BoardNetworkSettingsView`), so this page stays one screen long.
struct ConnectionView: View {
    @Environment(SettingsWorkspace.self) private var workspace
    @Environment(BoardSessionStore.self) private var sessions
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardStore.self) private var boardStore
    @Bindable private var viewModel: ConnectionViewModel

    /// Shown beside the category list without the user having opened it: does not
    /// touch the network.
    private let isPassive: Bool

    init(workspace: SettingsWorkspace, isPassive: Bool = false) {
        self.viewModel = workspace.connection
        self.isPassive = isPassive
    }

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        Form {
            Group {
                currentBoardSection
                boardsSection
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("连接")
        .task(id: isPassive) {
            guard !isPassive else { return }
            // A saved hotspot board reconnects through the phone's current
            // join; refresh that cache whenever the page (re)appears.
            await HotspotJoiner.revalidateLastJoinedSSID()
        }
        .errorAlert(workspace.connectionError(for: .connection))
    }

    // MARK: Current board

    /// Whether any real board is selected; a fresh launch starts on a
    /// placeholder session with no board behind it.
    private var hasBoard: Bool { isConnected || sessions.active.boardID != nil }

    private var activeName: String {
        if let name = connection.deviceName { return name }
        return hasBoard ? sessions.active.name : String(localized: "未选择璃奈板")
    }

    /// The board every other page acts on, said once and plainly.
    @ViewBuilder
    private var currentBoardSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(stateColor(connection.connectionState))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activeName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if hasBoard { CurrentBoardBadge() }
                    }
                    Text(currentSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isInProgress(connection.connectionState) { ProgressView() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connection.currentBoard")

            if let error = connection.lastError, !isConnected {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("connection.failureReason")
                // Secondary encouragement directly under the concrete
                // failure reason above — it never stands in for that
                // reason, and only appears once one is already shown.
                // Only once the app has given up: while it is still
                // retrying on its own, lastError is set too.
                if case .failed = connection.connectionState {
                    Text("请重新尝试连接")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if case .bluetooth = connection.transportKind, connection.wifi?.staConnected == true {
                Button("切换到 Wi-Fi") {
                    workspace.run(from: .connection) { await viewModel.switchToWifi(connection: connection, boardStore: boardStore) }
                }
            }

            if isConnected || isInProgress(connection.connectionState) {
                // Also while connecting or retrying: disconnecting is how a
                // user stops a board that is off from being redialled.
                Button("断开", role: .destructive) { connection.disconnect(userInitiated: true) }
            } else if !hasBoard {
                Button("添加璃奈板…") { workspace.selection = .addBoard }
            }
        } header: {
            Text("当前璃奈板")
        }
    }

    /// "蓝牙 · 已连接"; just the state while no transport is chosen. The
    /// failure reason is its own row, so `.failed` does not repeat it.
    private var currentSubtitle: String {
        let state = stateLabel(connection.connectionState)
        guard let transport = connection.transportKind else { return state }
        return "\(transportLabel(transport)) · \(state)"
    }

    // MARK: Boards

    /// A board: its saved records (several when it was saved under more than
    /// one address, e.g. BLE and then Wi-Fi), its live session, or both.
    private struct BoardRow: Identifiable {
        let id: String
        var records: [KnownBoard]
        let session: BoardSession?
        var saved: KnownBoard? { records.first }
    }

    /// Saved boards in their saved order, then any live board session that no
    /// saved board accounts for — one row per board, where the page used to
    /// list sessions and saved boards separately.
    private var boardRows: [BoardRow] {
        var rows: [BoardRow] = []
        var rowForSession: [UUID: Int] = [:]
        for board in boardStore.boards {
            let session = sessions.existingSession(for: board.id)
            if let session, let index = rowForSession[session.id] {
                rows[index].records.append(board)
                continue
            }
            if let session { rowForSession[session.id] = rows.count }
            rows.append(BoardRow(id: board.id, records: [board], session: session))
        }
        for session in sessions.sessions where session.boardID != nil && rowForSession[session.id] == nil {
            rows.append(BoardRow(id: session.id.uuidString, records: [], session: session))
        }
        return rows
    }

    private var onlineCount: Int {
        sessions.sessions.filter { $0.connection.connectionState == .connected }.count
    }

    @ViewBuilder
    private var boardsSection: some View {
        let rows = boardRows
        Section {
            if rows.isEmpty {
                Text("还没有璃奈板。")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                boardRow(row)
            }
        } header: {
            Text("璃奈板 · \(onlineCount) 块在线")
        } footer: {
            Text("可连接多块璃奈板，点选要控制的板，其他板保持连接。多板 Wi-Fi 连接需处于同一网络；热点直连仅适用于当前加入的热点。")
        }
    }

    @ViewBuilder
    private func boardRow(_ row: BoardRow) -> some View {
        let state = row.session?.connection.connectionState
        let isOnline = state == .connected
        let isActive = row.session.map { $0.id == sessions.active.id } ?? false
        let isConnecting = (row.saved != nil && viewModel.connectingSavedBoardID == row.saved?.id)
            || state.map(isInProgress) == true
        let name = (isOnline ? row.session?.connection.deviceName : nil)
            ?? row.saved?.name ?? row.session?.name ?? ""
        let canDisconnect = state.map { $0 != .disconnected } ?? false

        HStack {
            Button {
                open(row)
            } label: {
                HStack(spacing: 12) {
                    // The selection mark: filled for the board every other
                    // page acts on, empty for the rest.
                    SwapSymbol(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name)
                                .fontWeight(isActive ? .semibold : .regular)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if isActive { CurrentBoardBadge() }
                        }
                        Text(rowSubtitle(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text(isOnline ? "在线" : "未连接")
                            .foregroundStyle(isOnline ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .swapText(isOnline)
                    }
                }
                .contentShape(Rectangle())
            }
            // `connectSavedBoard` ignores a tap while another connect is in
            // flight, so the row says so rather than silently doing nothing.
            .disabled(row.saved != nil && (viewModel.connectingSavedBoardID != nil || viewModel.isConnectingBLE))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(Text(isOnline ? "在线" : "未连接"))
            // `.ignore` makes a new element, which drops the button trait.
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("connection.boardRow")

            if canDisconnect || row.session != nil || row.saved != nil {
                Menu {
                    if canDisconnect, let session = row.session {
                        Button("断开", systemImage: "xmark.circle", role: .destructive) {
                            session.connection.disconnect(userInitiated: true)
                        }
                    }
                    Button("忘记", systemImage: "trash", role: .destructive) {
                        forget(row)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: AppLayout.minimumTapTarget, minHeight: AppLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("更多操作"))
            }
        }
        .buttonStyle(.borderless)
    }

    /// A saved board goes through `connectSavedBoard`, which selects it,
    /// keeps a live link, and redials a hotspot link whose shared SoftAP IP
    /// now reaches a different board. A session never saved is only selected.
    private func open(_ row: BoardRow) {
        if let board = row.saved {
            workspace.run(from: .connection) { await viewModel.connectSavedBoard(board, sessions: sessions, boardStore: boardStore) }
        } else if let session = row.session {
            sessions.select(session)
        }
    }

    /// Drops every saved record of the board and its session.
    private func forget(_ row: BoardRow) {
        if let id = row.session?.boardID { sessions.remove(id: id) }
        for board in row.records {
            sessions.remove(id: board.id)
            boardStore.remove(id: board.id)
        }
    }

    private func rowSubtitle(_ row: BoardRow) -> String {
        if let session = row.session, let transport = session.connection.transportKind,
           session.connection.connectionState == .connected {
            return transportLabel(transport)
        }
        switch row.saved?.preferredTransport {
        case "bluetooth": return String(localized: "蓝牙")
        case "hotspot": return String(localized: "热点直连")
        case .some: return String(localized: "家庭 Wi-Fi")
        case nil: return row.session.map { stateLabel($0.connection.connectionState) } ?? ""
        }
    }

    // MARK: Labels

    private func isInProgress(_ state: BoardConnectionState) -> Bool {
        switch state {
        case .connecting, .reconnecting: true
        case .connected, .disconnected, .failed: false
        }
    }

    private func stateColor(_ state: BoardConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    private func transportLabel(_ kind: TransportKind) -> String {
        switch kind {
        case .bluetooth: String(localized: "蓝牙")
        case .wifi: String(localized: "家庭 Wi-Fi")
        case .hotspot: String(localized: "热点直连")
        }
    }

    private func stateLabel(_ state: BoardConnectionState) -> String {
        switch state {
        case .disconnected: String(localized: "未连接")
        case .connecting: String(localized: "连接中…")
        case .connected: String(localized: "已连接")
        case .reconnecting(let attempt): String(localized: "重连中(\(attempt))")
        case .failed: String(localized: "连接失败")
        }
    }
}

/// Marks the board the app is controlling wherever boards are listed.
struct CurrentBoardBadge: View {
    var body: some View {
        Text("当前")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint, in: Capsule())
            .accessibilityHidden(true)
    }
}

// No #Preview: ConnectionView requires a live BLETransport (backed by a real
// CBCentralManager), which isn't safe/meaningful to construct in the
// Xcode Previews sandbox.

/// Joins the board to a scanned network. Presented from `SettingsView` so it
/// survives the Settings layout changing under it.
struct ConnectionPasswordSheet: View {
    let network: WifiNetwork
    @Environment(SettingsWorkspace.self) private var workspace
    @Environment(BoardConnection.self) private var connection

    var body: some View {
        @Bindable var workspace = workspace
        NavigationStack {
            Form {
                Section(network.ssid) {
                    if network.secure {
                        SecureField("密码", text: $workspace.passwordInput)
                    } else {
                        Text("开放网络，无需密码")
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("连接网络")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        workspace.passwordInput = ""
                        workspace.networkForPassword = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        let ssid = network.ssid
                        let password = workspace.passwordInput
                        workspace.passwordInput = ""
                        workspace.networkForPassword = nil
                        let viewModel = workspace.connection
                        workspace.run(from: .network) { await viewModel.connectNetwork(ssid: ssid, password: password, connection: connection) }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
