# RinaBoard iOS app

Open `RinaBoard.xcodeproj` in Xcode 27.1 or newer (Duo layout APIs require the iOS 27.1 SDK), or run the
command below, and build the `RinaBoard` scheme for an iOS 17+ simulator or device.
The minimum deployment target is iOS 17; this is separate from the build SDK.
Sources reference iOS 27.1 APIs behind runtime availability checks, so Xcode 16
cannot compile them. Older Xcode releases have not been validated by this audit.
The app remains in Swift 5 language mode; RinaCore uses Swift 6. Run
`tools/verify_ios.sh` from the repository root for the package, app tests and
strict-concurrency warning baseline rather than changing the language mode alone.

```sh
cd ios
xcodebuild -project RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Sources under `RinaBoard/` are added automatically via a filesystem-synchronized
group; drop new Swift files or resources into the right subfolder and Xcode
picks them up on the next build. `Packages/RinaCore` is a local Swift package
(`swift test` from that directory runs its unit tests) providing the
transport-agnostic RinaLink protocol codec and models.

## Apple Watch companion

`RinaBoardWatch` is a watchOS 10+ app embedded in `RinaBoard.app` (the
`Embed Watch Content` phase; bundle id `com.rinachan.board.watchkitapp`). It
never pairs with a board: every action goes to the paired iPhone over
WatchConnectivity and the phone runs it against the boards it is connected to.
The watch works while the iPhone app is running in the foreground; the phone
app has no Bluetooth background mode, so with the phone locked or the app
suspended the watch shows "iPhone 不可达" until the app is back.

- Sources: `RinaBoardWatch/` (watch UI), `RinaWatchLink/` (the wire format and
  `WCSessionDelegate` relay, compiled into both apps), and
  `RinaBoard/Services/WatchLinkService.swift` (the phone end). Build or run the
  watch app with the `RinaBoardWatch` scheme on a watch simulator paired with an
  iPhone simulator; building `RinaBoard` builds and embeds it.
- What it controls: the Control Center's board-wide state (brightness,
  previous/next face, auto cycle and its interval, preset colours), the scroll
  speed of a running text scroll (greyed out otherwise), and lip sync
  (start/stop and microphone sensitivity; the iPhone's microphone does the
  listening). Every value opens a screen the Digital Crown drives.
- Target: 控制对象 on the watch defaults to whatever the phone is controlling
  and can be switched to any connected board or any board group. That choice
  lives on the phone side of the link only — it never changes the phone's
  active session or its own 控制对象, so the phone keeps running what it was
  running. Only prev/next, auto on/off and lip sync take over a board's
  output, exactly as the phone's Control Center would; brightness, colour,
  interval and scroll speed retune whatever is already playing. The phone's
  own board goes through `BoardControlCenterModel` (so its drafts and group
  fan-out apply); any other board or group is driven directly through its
  `BoardConnection`(s). A group that is not the phone's synced group receives
  each command per member, and cannot start lip sync.
- Strings: the watch has its own `RinaBoardWatch/Resources/Localizable.xcstrings`,
  hand-maintained in the same four languages (`tools/i18n/README.md`).
- Testing without hardware: pair an iPhone and a Watch simulator (`xcrun simctl
  pair`), install `RinaBoard.app` on the phone and `RinaBoard.app/Watch/RinaBoardWatch.app`
  on the watch, run `python3 tools/rinalink_board_emulator.py`, and add the board
  by host (`127.0.0.1`; the Mac's LAN IP gives a second board for a group). The
  phone's session only reports the watch app as installed/reachable after the
  watch's first message, which the simulator can hold for the better part of a
  minute; until then the watch shows "等待 iPhone…".

On-device: real Bluetooth/Wi-Fi/hotspot connectivity requires a physical
iPhone/iPad; the simulator can still exercise the UI and TCP paths against a
board on the same network.

Debug → 终端 opens the Serial Monitor over the active Bluetooth/Wi-Fi
connection. Enter a CMD name (for example `get_info`) or a JSON CMD payload
(for example `{"cmd":"set_brightness","raw":80}`), then send. `PING`,
`GET_STATUS`, and `GET_POWER` are also available. Enable “显示全部可用指令”
to search all firmware CMD templates and tap one to fill the input. The
monitor retains recent requests/replies and can receive firmware logs;
it does not connect to a USB serial port or accept USB-console syntax.

Multiple boards can remain connected at once over Bluetooth or the same Wi-Fi
network. In Settings → Connection, connect each board, then choose the control
target in the session list. Commands go to the selected board; selecting another
board stops the previous phone-driven output without closing its connection.
Disconnect and Forget apply only to that board. Direct board hotspots require
the phone to join that hotspot and cannot provide several simultaneous Wi-Fi
networks. On launch, the most recently used saved board reconnects automatically;
additional boards can be connected from the saved list.

After force-quitting, reopen the app to resume automatic connection recovery.
BLE recovery first retrieves the saved peripheral, then scans for its exact
UUID if the system cache no longer contains it. It never substitutes another
board with the same advertised name. Connection readiness includes the protocol
handshake and initial reads, so the saved device is recorded when setup succeeds,
including success after an automatic retry.

On launch, reconnect, and return from the background, the app reads the board's
current output mode and selects its page, including the video page inside
Performance. GPIO and other clients' changes take precedence over remembered
phone state. Text follows the board's retained scroll timeline. Lip sync
restarts microphone capture; performance and video restore matching local
material at the board's last stream position, retaining the original stream ID.
An already-running matching player keeps its current playhead. Held media
frames refresh the board position about once a second. A generic board pause
is respected instead of automatically restarting playback.
If that stream's material is unavailable on this phone, the app reports the
missing stream instead of starting unrelated media. Microphone permission is
still required. Update the firmware for stable mode/stream reporting; older
firmware falls back to its last frame reason.
Streams started before identity reporting was added can select their page,
but must be started once from the updated app before automatic live recovery
can identify them reliably.

Duo uses the public reserved-region APIs for its inner-screen workspace. Folded mode supports portrait only and places M, color and the status/expand button above the native tab sidebar. These are separate 44-point circular controls with 6-point gaps. The last button opens the full Control Center as a menu sliding up inside the safe app content area, leaving the native navbar and tabbar uncovered. Expanded and half-folded modes show M, previous/next and color, with no status button; the full Control Center is inline. Column previews are pinned and fill their column width. Half-folded portrait pins the preview above the fold with board controls and tab controls below. Landscape keeps preview and board controls on the left and tab controls on the right. An active vertical fold uses the full available region on each side of the hinge; the flat display keeps equal columns. Segmented picker rows use the native rounded surface without an additional list-card background. At accessibility text sizes, the lower portrait panes stack so labels and controls remain usable. The downloaded research guide is `docs/APPLE_ADAPTIVE_UI_GUIDE_2026_10_13.md`; its matrix is a research plan, not a record of local test passes.

### Simulator multi-board preview fixtures

Debug simulator builds accept `-seedTestGroups YES`. This adds `Test · 2 boards`,
`Test · 3 boards`, `Test · 5 boards`, and `Test · 3 mirrors` once, preserving
existing groups and their ordering. These fixtures are not included in Release
builds and do not claim to be physical boards.

Run `python3 tools/run_simulator_group_boards.py` from the repository root to start
five local RinaLink boards on ports 15370–15374. Terminate any running app instance, then launch the simulator app with:

```sh
xcrun simctl launch <simulator-id> com.rinachan.board \
  -initialTab text -seedTestGroups YES -connectTestBoards YES \
  -testGroupName 'Test · 3 boards' -playTestGroup YES -pauseTestGroup YES
```

Omit `-pauseTestGroup YES` for scrolling playback. The fixture uses the regular
TCP connection, handshake, bitmap upload, synchronization, and reorder paths.
`GroupPreviewSimulatorUITests` checks forward and reverse long-press dragging,
a no-move release, and visible LED content for 2/3/5-board stitched groups and a
3-board mirror group. On narrow previews it checks short horizontal swipes and scrolls an offscreen source into view before dragging. iOS uses a native long-press recognizer so scrolling and board reordering coexist; the existing spring animation and the Mac gesture path are preserved. Drag displacement uses an explicit window conversion from the touch view, so Duo's rotated display keeps the same direction as the preview's layout.
`testFiveBoardPreviewCanDragInLandscape` requires the inner display rotated to landscape in Device Hub and asserts the actual app window is landscape before dragging. Set the desired fold posture in Device Hub before each run. Start the local boards before running the UI tests. Stop
all five listeners with Ctrl-C in the fixture runner.
