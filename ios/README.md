# RinaBoard for Apple devices

English · [简体中文](README.zh-CN.md)

Draw expressions, send scrolling text, and bring a 370-LED RinaChanBoard to life with your voice, music, or video. RinaBoard is the shared SwiftUI app for **iPhone, iPad, and Mac Catalyst**, with an **Apple Watch companion** that sends controls through the paired iPhone.

Boards connect over BLE or local-network TCP using RinaLink. Everyday control needs no external server. For hardware, firmware installation, and physical buttons, start with the [project README](../README.md).

## What you can do

### Create and collect expressions

Tap or drag on the 370-point canvas to draw and erase. Use mirror drawing, invert, clear, undo, pinch zoom, draft recovery, and live sending. On supported iPads, Apple Pencil hover can highlight the corresponding LED in the preview and on the board.

Combine left-eye, right-eye, mouth, and cheek parts, use symmetric eyes or random combinations, then refine the result by drawing. Manage separate local and board libraries: apply, rename, copy, reorder, edit, bulk-delete, and import or export JSON. Presets are protected, and local deletions can be undone. Individual M370 frames support hex, byte-array, and Base64 import/export.

### Adjust the board from any working page

The Control Center shows connection status and provides previous/next expression, manual/automatic cycling, cycle interval, brightness, and colour. Pick a Love Live! character colour preset or enter your own colour.

| Layout | Control Center placement |
|---|---|
| iOS 26+ single column | A draggable card above the native bottom navigation, with collapsed, half-page, and full-page stops; changing tabs retains its height |
| Wide iPad | Inline below the pinned board preview, beside the page controls |
| Mac | Embedded in the page in both narrow and wide windows |
| Folded Duo | Toolbar controls and an expandable menu inside the app content |
| iOS 17–25 single column | A page in Settings |

Duo adapts the preview and controls to fold posture and orientation. Half-folded portrait places the preview above the fold; landscape separates preview/board controls from page controls. Settings also adapts between stack and category/detail navigation while retaining the selected page and unsaved inputs.

### Play text, voice, music, and video

| Feature | Available controls | Where playback runs |
|---|---|---|
| Scrolling text | Ark Pixel 12px rasterization and preview; play, pause, resume, stop, loop, frame stepping, scrubbing, and nominal 1–60 fps speed | The board plays uploaded frames independently until power-off |
| Lip sync | Microphone-driven vowel/closed-mouth shapes; voice presets, sensitivity, refresh rate, smoothing, vowel calibration, and shape mapping | The app analyses audio and streams frames |
| Performance | Local audio paired with `.rinalive` expression keyframes; pause, seek, and loop | The app follows the audio playhead and sends expressions |
| Video | File or Photos import; fit mode, threshold, dithering, inversion, mirroring, frame rate, loop, mute, and seeking | The app converts video to on/off LED frames and streams them |

Video uses the board-wide colour and brightness. Preset performance timelines are included; supply the audio yourself. Lip sync requires microphone permission. Performance and video recovery require the matching material to remain on this device.

### Control one board or a group

Keep multiple BLE or local-network TCP sessions connected and choose the active control target. Switching boards stops the previous app-driven output while retaining that board's connection; Disconnect and Forget apply only to the selected device.

Create groups of up to **5 boards**. Stitched mode spreads text across a long display with adjustable gaps; mirror mode repeats it on each board. Identify physical boards by number and drag the group preview to reorder members. Group text uses clock sampling and scheduled starts; expressions, colour, brightness, and app-driven live content also support group control.

The app stores known devices, connection preferences, and groups locally. It automatically reconnects the most recently used saved board on launch; connect additional boards from the saved list.

### Use Apple Watch

Use the Digital Crown to adjust brightness, automatic-cycle interval, the speed of a running text scroll, and lip-sync sensitivity. The Watch also switches expressions, colour presets, auto/manual mode, and lip sync.

The Watch control target can follow the phone or select another connected board or group without changing the phone's active target. A group other than the phone's current synced group cannot start lip sync from the Watch. Expression switching, auto-mode changes, and lip sync take over output; brightness, colour, interval, and scroll speed adjust existing playback.

**The paired iPhone app must be in the foreground.** WatchConnectivity forwards each action through the phone; the Watch does not connect directly to a board. Locking the phone or suspending its app makes Watch controls unreachable until the app returns.

Both apps include Simplified Chinese, Traditional Chinese, Japanese, and English localization.

## Build and run

### Requirements

Use **Xcode 27.1 or newer**. The minimum deployment targets are **iOS / iPadOS 17**, **macOS 14**, and **watchOS 10**. The build SDK is separate from the deployment target: Duo sources reference iOS 27.1 APIs behind runtime availability checks, so Xcode 16 cannot compile the current sources.

The app uses Swift 5 language mode; `RinaCore` uses Swift 6. Physical devices require development signing. Simulator builds can exercise the UI and TCP paths; actual BLE, hotspot association, and LED output need physical devices.

### iPhone and iPad

Open `ios/RinaBoard.xcodeproj`, select the `RinaBoard` scheme, and choose a device or simulator. All commands below run from the **repository root**:

```sh
xcodebuild -project ios/RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

### Mac

```sh
./tools/build_mac.sh
open "$HOME/Applications/RinaBoard-Mac/RinaBoard.app"
```

This produces a locally signed Catalyst development build. Output paths, signing options, hotspot support, and physical-board tests are documented in the [Mac guide](../docs/mac/README.md).

### Apple Watch

The `RinaBoard` build embeds `RinaBoardWatch.app`. Select the `RinaBoardWatch` scheme to run it on a Watch or a Watch simulator paired with an iPhone simulator. The companion bundle ID is `com.rinachan.board.watchkitapp`.

## Connect your first board

Start in **Settings → Add Board** (`设置 → 添加璃奈板`), connect over Bluetooth, then send an expression from the editor or library. Use **Settings → Connection** to manage devices and targets, and **Wi-Fi & Hotspot** to configure networking.

| Transport | Setup |
|---|---|
| BLE | Scan for `RinaBoard-<ID>`; direct control and Wi-Fi provisioning are available |
| Home Wi-Fi | Put the board and controller on the same LAN; use Bonjour discovery or enter its IP, TCP port `5370` |
| Direct hotspot | Join `RinaChanBoard-<ID>` with initial password `rinachan`; connect to that board's own hotspot IP |

`<ID>` is the 12-digit uppercase identifier derived from the board's Bluetooth MAC. Names can be changed; connections still validate physical identity. Read or edit the board-specific hotspot address over BLE in Wi-Fi & Hotspot settings. A phone or Mac can join one Wi-Fi network at a time, so use BLE or a shared LAN for simultaneous multiboard control.

After force-quitting, reopen the app to resume connection recovery. BLE recovery retrieves the saved peripheral or scans for its exact UUID; a matching advertised name alone does not substitute another board. A connection becomes ready after the protocol handshake and initial reads.

## Playback and reconnection

On launch, reconnect, and return to the foreground, the app reads the board's actual output mode. First connections and explicit board selections adopt that mode and open the matching page, including Video inside Performance; genuine reconnects retain the selected tab, and Settings stays visible. Physical-button and other-client changes take precedence over remembered app state.

- Text follows the board's retained timeline; uploaded frames are lost at power-off.
- Lip sync can restart microphone capture with permission when the page and recovery state allow it.
- Performance and video restore matching local material at the reported stream position, retaining stream identity. An already-running matching player keeps its playhead.
- A board pause is respected. Missing material is reported instead of starting unrelated content.

Use current firmware for stable mode and stream reporting. Older firmware falls back to the last frame reason; older streams without material identity must be started once from the updated app for reliable live recovery.

The app has no Bluetooth background mode. Voice and media processing depend on the app remaining active; leaving the lip-sync page stops microphone sync, performance pauses when inactive, and video pauses in the background. Saved expressions and uploaded text can continue on the board independently.

## Develop and debug

### Source map

| Directory | Responsibility |
|---|---|
| `RinaBoard/App/` | App lifecycle, navigation, Control Center placement, and recovery |
| `RinaBoard/Features/` | Editor, libraries, text, lip sync, performance, video, groups, settings, and debug UI |
| `RinaBoard/Services/` | Connections, persistence, audio/media services, and Watch relay |
| `RinaBoard/Resources/` | Fonts, parts, expressions, timelines, images, and localization |
| `RinaBoardWatch/` | Watch interface and its localization |
| `RinaWatchLink/` | Shared WatchConnectivity messages and relay |
| `Packages/RinaCore/` | Transport-independent RinaLink codec and models |
| `Packages/RinaFaceSync/` | Independent sync module; iCloud expression sync is not connected to the main app |

`RinaBoard/` uses a filesystem-synchronized Xcode group, so new files in its subfolders are picked up by the project. See the [resource notes](RinaBoard/Resources/README.md) and [localization tools](../tools/i18n/README.md) when changing bundled content.

### Verification

```sh
# Package and sync-module checks, no simulator required
./tools/verify_ios.sh core facesync facesync-guard

# Default lanes: core, facesync, facesync-guard, app, concurrency, mac
RINA_SIM_ID=<simulator-UDID> ./tools/verify_ios.sh

# UI tests are opt-in
RINA_SIM_ID=<simulator-UDID> ./tools/verify_ios.sh ui

# Mac app unit tests only
./tools/verify_ios.sh mac
```

Use a simulator UDID from `xcrun simctl list devices available`. The script covers the local packages as well as the app, checks actual executed test counts, and enforces the strict-concurrency warning baseline. A successful app scheme test alone does not cover `RinaCore` tests. Physical-board suites are separate; their setup and restoration behaviour are in the [Mac guide](../docs/mac/README.md).

### TCP simulator boards

```sh
# One board, default TCP port 5370
python3 tools/rinalink_board_emulator.py

# Five boards on ports 15370–15374
python3 tools/run_simulator_group_boards.py
```

In the same-machine iOS simulator, add host `127.0.0.1`; on a physical device, use the computer's LAN IP. Stop the listeners with Ctrl-C.

Debug simulator builds can seed `Test · 2 boards`, `Test · 3 boards`, `Test · 5 boards`, and `Test · 3 mirrors` without replacing existing groups. With the five-board runner active and the app installed, terminate any running app instance and launch:

```sh
xcrun simctl terminate <simulator-UDID> com.rinachan.board
xcrun simctl launch <simulator-UDID> com.rinachan.board \
  -initialTab text -seedTestGroups YES -connectTestBoards YES \
  -testGroupName 'Test · 3 boards' -playTestGroup YES -pauseTestGroup YES
```

The terminate command can report that the app is not running. Omit `-pauseTestGroup YES` for scrolling playback. Fixtures use the regular handshake, upload, sync, and reorder paths and are excluded from Release builds.

`GroupPreviewSimulatorUITests` covers stitched and mirrored previews, long-press reordering, and narrow-preview scrolling. The five-board landscape case requires the actual app window to be landscape; set Duo posture and orientation in Device Hub before running the relevant test.

For Watch testing, pair simulators with `xcrun simctl pair`, install the phone app and its embedded Watch app on the respective simulators, and connect the phone to the TCP emulator. Watch reachability is established after the first Watch message; the simulator may initially show a waiting state.

### Debug terminal

**Settings → Debug → Terminal** uses the active BLE/TCP connection. Send a command name such as `get_info`, or a JSON payload:

```json
{"cmd":"set_brightness","raw":80}
```

`PING`, `GET_STATUS`, and `GET_POWER` are also supported. Show all available commands to search firmware templates and fill the input. Recent requests, replies, and firmware logs stay in the monitor. USB serial diagnostics use the firmware's separate console.

## Further reading

- [Project overview and firmware setup](../README.md)
- [Mac build and validation](../docs/mac/README.md)
- [RinaLink protocol](../docs/RINALINK_PROTOCOL_V1.md)
- [Lip sync and performance](../docs/LIVE_FEATURES_ZH.md)
- [Board group design](../docs/BOARD_GROUP_SPEC.md)
- [Text rasterization](../docs/SCROLL_RASTERIZER_SPEC.md)

The project uses [GNU GPL v3](../LICENSE). Keep third-party resource notices and licences with their assets; performance audio is not distributed in this repository.
