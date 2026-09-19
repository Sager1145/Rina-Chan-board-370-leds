import SwiftUI
import RinaCore

/// Everything the Settings tab must keep while its layout changes: the route,
/// the pages' models, unsent input and the dialogs that are up.
///
/// App-scoped, like the other draft models, because the Settings tab swaps
/// between a stack and a split view as its window is resized, a folding phone
/// changes screens or an iPad rotates — and each swap rebuilds the pages. Any
/// of this held in a page's `@State` would be reset by a resize: the page a
/// user was on, a half-typed hotspot password, the Debug terminal.
@Observable @MainActor
final class SettingsWorkspace {
    // MARK: Route

    /// The page on screen. `nil` means the category list in the single-column
    /// layout; the split layout then shows `lastVisited` without making it a
    /// new navigation.
    var selection: SettingsCategory? {
        didSet {
            // The page that was on screen: with nothing selected, the split
            // layout shows the last one visited.
            let shown = oldValue ?? lastVisited
            if let selection { lastVisited = selection }
            // Leaving Debug ends its firmware-log stream, as closing the page
            // did when the page owned the model. A layout change never
            // changes `selection`, so it keeps the stream.
            if shown == .debug, selection != .debug { debug.handleSessionChange() }
            // Another category starts at its root; a layout change never
            // gets here, so it keeps the editor open.
            if selection != oldValue, selection != .groups { editingGroupID = nil }
        }
    }
    private(set) var lastVisited: SettingsCategory
    /// The group whose editor is pushed on the 多板组 page. Settings' one
    /// second-level page, kept here so crossing between the layouts, which
    /// rebuilds the stack, reopens it.
    var editingGroupID: UUID?
    /// Decided by `SettingsLayoutPolicy` from the width Settings gets.
    var layoutMode: SettingsLayoutMode?
    /// Whether the user hid the sidebar; kept across layout changes so a
    /// resize does not force it open again.
    var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: Page models

    /// Browses Bonjour only while the Connection page is on screen — see
    /// `connectionPageAppeared()`.
    let connection = ConnectionViewModel(startBonjourBrowsing: false)
    let debug = DebugViewModel()

    // MARK: Connection drafts

    var bluetoothFilter = ""
    var apSSID = ""
    var apPassword = ""
    var networkForPassword: WifiNetwork?
    /// In memory only; never persisted.
    var passwordInput = ""

    // MARK: Debug

    var debugWorkspace = 0
    var confirmDebugResetMin = false
    var confirmDebugResetMax = false
    var confirmDebugAllOn = false
    var confirmDebugClearFaces = false

    // MARK: Board

    var confirmBoardReboot = false
    var boardRebootError: String?

    /// The board a destructive confirmation was opened for. The dialogs are
    /// dropped when the controlled board changes — see `boardChanged(to:)` —
    /// so confirming can never act on a board the user did not choose.
    @ObservationIgnored private var boardKey: ObjectIdentifier?
    @ObservationIgnored private var connectionPageVisits = 0

    init(initialSelection: SettingsCategory? = SettingsCategory(
        launchArgument: UserDefaults.standard.string(forKey: "initialTab"))
    ) {
        selection = initialSelection
        lastVisited = initialSelection ?? .connection
    }

    /// The categories the list shows, in order. The Control Center entry only
    /// exists where it has no other home, but stays while it is open so a
    /// resize cannot remove the page under the user.
    func categories(controlCenterInSettings: Bool) -> [SettingsCategory] {
        SettingsCategory.allCases.filter {
            $0 != .controlCenter || controlCenterInSettings || selection == .controlCenter
        }
    }

    // MARK: Connection page lifetime

    /// Counted rather than flagged: when the layout changes, the new page can
    /// appear before the old one disappears.
    func connectionPageAppeared() {
        connectionPageVisits += 1
        if connectionPageVisits == 1 { connection.bonjour.start() }
    }

    func connectionPageDisappeared() {
        connectionPageVisits = max(0, connectionPageVisits - 1)
        if connectionPageVisits == 0 { connection.bonjour.stop() }
    }

    // MARK: Connection errors

    /// The page whose action last went through `connection`. Four pages
    /// share that model's `lastErrorMessage`; only this one alerts it, so an
    /// error from a connect that outlives its page does not pop up on
    /// whichever page opens next. Errors from no page belong to 连接.
    private(set) var connectionErrorPage: SettingsCategory?

    func markConnectionAction(from page: SettingsCategory) {
        connectionErrorPage = page
    }

    /// Runs a page's `connection` action with its errors attributed to it.
    func run(from page: SettingsCategory, _ action: @escaping @MainActor () async -> Void) {
        markConnectionAction(from: page)
        Task { await action() }
    }

    func connectionError(for page: SettingsCategory) -> Binding<String?> {
        Binding(
            get: { [self] in
                (connectionErrorPage ?? .connection) == page ? connection.lastErrorMessage : nil
            },
            set: { [self] in if $0 == nil { connection.lastErrorMessage = nil } }
        )
    }

    // MARK: Board changes

    /// Drops what belonged to the previously controlled board: its Wi-Fi
    /// scan, the hotspot fields typed for it and every destructive
    /// confirmation opened against it. Layout changes never come through
    /// here; only the active connection object changing does.
    func boardChanged(to connection: BoardConnection) {
        let key = ObjectIdentifier(connection)
        defer { boardKey = key }
        guard let boardKey, boardKey != key else { return }
        self.connection.wifiNetworks = []
        boardRebootError = nil
        apSSID = ""
        apPassword = ""
        networkForPassword = nil
        passwordInput = ""
        confirmBoardReboot = false
        confirmDebugResetMin = false
        confirmDebugResetMax = false
        confirmDebugAllOn = false
        confirmDebugClearFaces = false
        debug.clearFacesConfirmText = ""
    }
}
