import SwiftUI

/// Whether a board page shows its preview and its controls side by side.
///
/// iPad only, and only while the window is actually regular-width: a Split
/// View slide-over is a phone-shaped window and gets the phone's single
/// column. A landscape iPhone Max reports a regular width class too, which is
/// why the idiom is checked as well — the board and a full control panel do
/// not fit beside each other in 430 pt.
enum BoardPageColumns {
    /// Width class only, never orientation: portrait and landscape iPad
    /// windows are both regular-width, so the two columns hold in every
    /// orientation and only a genuinely narrow window (Slide Over, a thin
    /// Split View pane) drops back to one.
    static func isSplit(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }
}

/// The shared skeleton of every page that has a board preview: one `List` on
/// a phone, two columns on iPad.
///
/// A page hands over the board and its status line separately. On a phone
/// they become the list's first section (`Section { board } footer: { status }`),
/// exactly as the pages used to build it themselves. On iPad they are pinned
/// at the top of the preview column — the board never scrolls away — and only
/// the Control Center under it scrolls (§5–§11), so the board-global controls
/// are reachable from every page without the tab-bar accessory the phone
/// layout uses. Settings has no preview and therefore no such column — it
/// stays a single `Form`.
///
/// The caller keeps its own list modifiers (`listSectionSpacing`,
/// `rinaScrollBackground`, `contentMargins`, `scrollDisabled`, alerts): all of
/// them propagate through this view to both lists, so a page reads the same as
/// it did when it built the `List` itself. What a page must *not* do any more
/// is apply `rinaTranslucentRows()` — this view applies it to both columns.
struct BoardSplitPage<Board: View, Status: View, Controls: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let board: Board
    private let status: Status
    private let controls: Controls

    init(@ViewBuilder board: () -> Board,
         @ViewBuilder status: () -> Status,
         @ViewBuilder controls: () -> Controls) {
        self.board = board()
        self.status = status()
        self.controls = controls()
    }

    var body: some View {
        if BoardPageColumns.isSplit(horizontalSizeClass) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    pinnedPreview
                    List {
                        Group {
                            BoardControlCenterView(isEmbedded: true)
                        }
                        .rinaTranslucentRows()
                    }
                }
                // Equal halves, measured against the page rather than laid
                // out by the stack, so rotating keeps them equal.
                .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 0)

                List {
                    Group {
                        controls
                    }
                    .rinaTranslucentRows()
                }
            }
        } else {
            List {
                Group {
                    Section {
                        board
                    } footer: {
                        status
                    }
                    controls
                }
                .rinaTranslucentRows()
            }
        }
    }

    /// The board and its status line outside any list, laid out to match the
    /// list cells beside and below it: the board spans a cell's width (the
    /// inset-grouped margin), the status line sits where a section footer's
    /// text would.
    private var pinnedPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            board
            status
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}
