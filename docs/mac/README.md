# RinaBoard for Mac and iPad

The Mac app is Mac Catalyst using the existing RinaBoard target in the iPad interface idiom. It compiles the same screens, models, resources, protocol code, RinaCore package, and version/build settings as iPad. There is no copied Mac UI to keep in sync. Changes to these shared files apply to both platforms; the default verification script now includes the Mac unit-test lane.

Mac pages adapt to the actual window width: narrow windows use one scrolling
column, and wide windows show the preview and controls side by side. Settings
switches between stack navigation and its category/detail columns without
discarding the selected page or unsaved inputs. Board controls remain embedded
in either Mac layout, and the transparent native top tabs stay in place.

Build the locally signed universal Mac app:

```sh
./tools/build_mac.sh
open "$HOME/Applications/RinaBoard-Mac/RinaBoard.app"
```

The default output is a dedicated folder under Applications. This workspace is backed by iCloud, which adds Finder metadata to application bundles in Documents and can invalidate their signatures. Use `RINA_MAC_OUTPUT` to choose another local destination. `RINA_MAC_DERIVED_DATA` selects the build cache. This is a local development build, not a notarized public distribution.

The Mac uses the same BLE and TCP transports. Apple's hotspot configuration API is iOS-only, so the Mac-only `RinaMacWiFiBridge.bundle` uses public CoreWLAN behind the shared `HotspotJoiner` interface. Blocking Wi-Fi operations run on a background queue, match the selected board SSID, and confirm association before TCP connection. The bundle is embedded and signed during the Catalyst build; iPad builds skip it. Location authorization is requested only when reading Wi-Fi or joining a board hotspot, since the system protects Wi-Fi names. Passive reads do not request permission.

Each board persists its own factory hotspot IPv4 address. Connect over Bluetooth to read it in Wi-Fi & Hotspot settings, where Home Wi-Fi IP and hotspot IP appear separately. Edit the hotspot address over Bluetooth; an IP-only save preserves the hotspot name and password. The app validates private /24 gateway addresses and rejects conflicts with saved boards. Selecting Direct Hotspot joins the selected board's exact SSID and dials its reported or saved address. A Mac has one Wi-Fi association at a time, so switching board hotspots releases the previous hotspot carrier while retaining Bluetooth and reachable Home Wi-Fi sessions.

## Verification

```sh
./tools/verify_ios.sh mac
RINA_SIM_ID=<iPad-simulator-UDID> ./tools/verify_ios.sh
./tools/test_mac_boards.sh
swift ./tools/check_mac_board_pairings.swift
```

The hardware command is explicitly opt-in and addresses only boards `80B54EF48E09` and `80B54EF74801`. It uses the production Mac BLE/connection implementation, connects both boards simultaneously, checks identity/status/power/frame responses, changes brightness by one step, and verifies restoration of the original value. It does not save brightness to flash or change faces, timelines, or network configuration.

Cleanup stops the connection owners' reconnect loops and waits for the actual terminal BLE disconnect callbacks and peripheral state. A timeout or missing restoration/disconnection proof fails the command. During this test, the Debug Mac host suppresses saved-board and group auto-reconnect; normal builds retain the iPad behavior. Pairing inventory is checked before and afterward, filtering only these two boards' hardware/BLE addresses. The firmware uses unbonded BLE, so connecting normally does not create a Bluetooth pairing. If a board was previously paired, forget only that board in System Settings → Bluetooth; the runner refuses to report success while a board pairing remains. Do not toggle Bluetooth or forget unrelated devices.

Close the Mac app after physical testing so it cannot restore a saved connection later. The unit test lane never starts the opt-in physical tests.

Set `RINA_MAC_SIGN_IDENTITY` to an existing Apple Development certificate identity
when rebuilding and running physical tests to retain a stable signing identity.
The default `-` produces an ad-hoc local build. Use the same identity for
`build_mac.sh`, `test_mac_boards.sh`, and `test_mac_features.sh`.

The shared network page selects Wi-Fi from a board scan; it has no separate
iPhone/Personal Hotspot setup. The connection page switches each saved board
between Bluetooth and Wi-Fi and validates the same physical identity.

After provisioning both boards with a scanned test network, run
`tools/test_mac_features.sh` for the expanded feature and multiboard suite. It
restores saved faces, settings, and output; clear test Wi-Fi profiles after all
network tests, then close the app and verify no board pairings remain.

For single-board, group-frame, and selected-board switching stress without a
Wi-Fi prerequisite, run `bash tools/test_mac_stress.sh`. It uses the production
Mac control models, checks both boards' real readback, and restores their state.
Run only one physical suite or interactive controller at a time; capture serial
logs from both boards separately while it runs.

See the [port validation record](2026-10-12-validation.md) and the
[expanded feature verification](2026-10-12-full-feature-testing.md) for actual
results and outstanding physical checks.
