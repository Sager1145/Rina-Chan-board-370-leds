import SwiftUI
import RinaCore

/// Settings tab (design guide §31–§35): a list of categories and the selected
/// category's page, with no LED preview.
///
/// Wide enough, the categories sit in a sidebar beside the page; otherwise the
/// list pushes each page on a stack. Which one is decided from the width this
/// tab actually gets (`SettingsLayoutPolicy`), not from the device, so resizing
/// a window, rotating an iPad or switching a folding phone's screen crosses
/// between them. Everything that must survive that crossing — the route,
/// unsent input, the Debug workspace, open dialogs — lives in the app-scoped
/// `SettingsWorkspace`, and the dialogs are attached here, above both layouts,
/// so neither rebuild can dismiss them.
///
/// On iOS 17–25 the single-column list also carries the Control Center,
/// because those releases have no persistent system bottom surface to attach
/// it to and the guide forbids hand-building one (§2). On iOS 26+ it lives in
/// the tab bar accessory, and on the two-column iPad layout under every other
/// page's board preview; either way the entry is omitted rather than
/// duplicated (§33).
struct SettingsView: View {
    @Environment(SettingsWorkspace.self) private var workspace
    @Environment(BoardConnection.self) private var connection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            // Resolved in the same pass that measures, so the first frame is
            // already the right layout; `previous` carries the hysteresis.
            let mode = SettingsLayoutPolicy.resolve(
                width: proxy.size.width, horizontalSizeClass: horizontalSizeClass,
                dynamicTypeSize: dynamicTypeSize, previous: workspace.layoutMode)
            Group {
                switch mode {
                case .split: SettingsSplitLayout()
                case .compact: SettingsStackLayout()
                }
            }
            // Only a change of layout writes anything; a resize within one
            // layout is not a navigation, a reload or a reconnect.
            .onChange(of: mode, initial: true) { _, mode in
                if workspace.layoutMode != mode { workspace.layoutMode = mode }
            }
        }
        .onChange(of: ObjectIdentifier(connection), initial: true) {
            workspace.boardChanged(to: connection)
        }
        .modifier(SettingsDialogs())
    }
}

// MARK: - Layouts

/// Sidebar of categories beside the selected page.
private struct SettingsSplitLayout: View {
    @Environment(SettingsWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView(columnVisibility: $workspace.columnVisibility) {
            List(selection: sidebarSelection) {
                SettingsCategoryRows()
            }
            .navigationTitle("设置")
            .accessibilityIdentifier("settings.sidebar")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            // Its own stack so a page can push further pages inside the
            // detail column. Keyed on the category so switching category
            // starts that page at its root instead of inheriting a push.
            NavigationStack {
                // With nothing selected (the single-column layout was left
                // on its list) the last page is only shown, not opened: it
                // must not start network work just because the window grew.
                SettingsDetail(category: workspace.selection ?? workspace.lastVisited,
                               isPassive: workspace.selection == nil)
            }
            .id(workspace.selection ?? workspace.lastVisited)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Highlights the page on screen, which is the last one visited when the
    /// single-column layout was left on its list.
    private var sidebarSelection: Binding<SettingsCategory?> {
        Binding(get: { workspace.selection ?? workspace.lastVisited },
                set: { if let category = $0 { workspace.selection = category } })
    }
}

/// The category list, pushing the selected page.
private struct SettingsStackLayout: View {
    @Environment(SettingsWorkspace.self) private var workspace

    var body: some View {
        NavigationStack(path: path) {
            Form {
                Group {
                    SettingsCategoryRows()
                }
                .rinaTranslucentRows()
            }
            .listSectionSpacing(.compact)
            .rinaScrollBackground()
            .navigationTitle("设置")
            .navigationDestination(for: SettingsCategory.self) { category in
                SettingsDetail(category: category, isPassive: false)
            }
        }
    }

    /// The stack is a projection of `selection`: one page deep, or the list.
    private var path: Binding<[SettingsCategory]> {
        Binding(get: { workspace.selection.map { [$0] } ?? [] },
                set: { workspace.selection = $0.last })
    }
}

// MARK: - Categories

/// The category rows both layouts show, in one order.
private struct SettingsCategoryRows: View {
    @Environment(SettingsWorkspace.self) private var workspace
    @Environment(BoardConnection.self) private var connection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var controlCenterInSettings: Bool {
        ControlCenterPlacement.resolve(
            splitLayout: BoardPageColumns.isSplit(horizontalSizeClass)
        ) == .settingsLink
    }

    var body: some View {
        let categories = workspace.categories(controlCenterInSettings: controlCenterInSettings)
        if categories.contains(.controlCenter) {
            Section { row(.controlCenter) }
        }
        Section {
            ForEach(categories.filter { $0 != .controlCenter }) { row($0) }
        }
    }

    private func row(_ category: SettingsCategory) -> some View {
        NavigationLink(value: category) {
            HStack {
                Label(category.title, systemImage: category.systemImage)
                if category == .connection {
                    Spacer()
                    Text(stateText).foregroundStyle(.secondary)
                }
            }
        }
        .tag(category)
        .accessibilityIdentifier("settings.category.\(category.rawValue)")
    }

    private var stateText: String {
        switch connection.connectionState {
        case .connected: return NSLocalizedString("已连接", comment: "connection state connected")
        case .connecting: return NSLocalizedString("连接中", comment: "connection state connecting")
        case .reconnecting: return NSLocalizedString("重连中", comment: "connection state reconnecting")
        case .disconnected: return NSLocalizedString("未连接", comment: "connection state disconnected")
        case .failed: return NSLocalizedString("连接失败", comment: "connection state failed")
        }
    }
}

/// One category's page, the same view in both layouts.
private struct SettingsDetail: View {
    let category: SettingsCategory
    /// Shown without being opened — see `SettingsSplitLayout`.
    let isPassive: Bool
    @Environment(SettingsWorkspace.self) private var workspace

    var body: some View {
        Group {
            switch category {
            case .controlCenter: BoardControlCenterView()
            case .connection: ConnectionView(workspace: workspace, isPassive: isPassive)
            case .board: BoardSettingsView()
            case .application: ApplicationSettingsView()
            case .debug: DebugView(workspace: workspace, isPassive: isPassive)
            case .about: AboutView()
            }
        }
        // `.contain` keeps the page's own identifiers; a bare identifier on
        // a container would be stamped onto every element inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.detail.\(category.rawValue)")
    }
}

// MARK: - Dialogs

/// Every sheet and confirmation the Settings pages open, attached above the
/// layout switch so a resize that rebuilds the page leaves them up.
private struct SettingsDialogs: ViewModifier {
    @Environment(SettingsWorkspace.self) private var workspace
    @Environment(BoardConnection.self) private var connection

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace
        let debug = workspace.debug
        content
            .sheet(item: $workspace.networkForPassword) { network in
                ConnectionPasswordSheet(network: network)
            }
            // Board page.
            .confirmationDialog("重启面板？", isPresented: $workspace.confirmBoardReboot,
                                titleVisibility: .visible) {
                Button("重启", role: .destructive) { rebootBoard() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("面板将断开连接并重新启动。")
            }
            .errorAlert($workspace.boardRebootError)
            // Debug page.
            .confirmationDialog("发送全亮图案？", isPresented: $workspace.confirmDebugAllOn,
                                titleVisibility: .visible) {
                Button("发送全亮", role: .destructive) {
                    Task { await debug.sendPattern(.allOn, connection: connection) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("全亮会点亮全部 370 颗 LED，估算功耗可能超过 40 W。")
            }
            .confirmationDialog("重置最低电压？", isPresented: $workspace.confirmDebugResetMin,
                                titleVisibility: .visible) {
                Button("重置", role: .destructive) {
                    Task { await debug.runCommand(.resetBatteryMin, connection: connection) }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("重置最高电压？", isPresented: $workspace.confirmDebugResetMax,
                                titleVisibility: .visible) {
                Button("重置", role: .destructive) {
                    Task { await debug.runCommand(.resetBatteryMax, connection: connection) }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("清空用户表情", isPresented: $workspace.confirmDebugClearFaces) {
                TextField("输入 CLEAR 以确认", text: Bindable(debug).clearFacesConfirmText)
                Button("确认清空", role: .destructive) {
                    guard debug.clearFacesConfirmText == "CLEAR" else { return }
                    Task { await debug.clearUserFaces(connection: connection) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作会删除所有非默认表情，且不可撤销。输入 CLEAR 确认。")
            }
            .confirmationDialog("确定要重启设备吗？", isPresented: $workspace.confirmDebugReboot,
                                titleVisibility: .visible) {
                Button("重启", role: .destructive) { Task { await debug.reboot(connection: connection) } }
                Button("取消", role: .cancel) {}
            }
    }

    private func rebootBoard() {
        Task {
            do {
                _ = try await connection.command(.reboot)
            } catch {
                // The firmware acknowledges `reboot` and only reboots
                // 200 ms later, so a failure here means the command
                // never arrived rather than "it rebooted, link gone".
                workspace.boardRebootError = String(
                    format: NSLocalizedString("重启命令未送达：%@",
                                              comment: "reboot command failed to reach the board"),
                    error.localizedDescription
                )
            }
        }
    }
}
