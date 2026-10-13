# Mac/iPad validation — 2026-10-12

## Delivered result

Installed universal Release app: `/Users/sager/Applications/RinaBoard-Mac/RinaBoard.app`. Both app and native Wi-Fi bridge contain arm64 and x86_64 slices. Deep strict signature verification passes, with no injected debugging or test-host entitlements in the delivered application. The processed app uses iPad device family `[2]`; its bundle identifier is `com.rinachan.board.mac`. iOS retains its existing identifier and Watch embedding.

Both platforms compile the same target's screens, models, resources, RinaCore package and version settings. Mac-only platform plumbing is the signed CoreWLAN bundle, sandbox entitlements, and hardware-test launch guard. The Mac scheme runs the shared app unit tests without the iPhone-only UI automation target. This synchronizes source/UI/version changes; it does not add cross-device synchronization of personal app preferences or libraries.

## Evidence

| Check | Actual result |
| --- | --- |
| Universal Release build and installed package signature | Passed |
| Final shared Mac unit suite | 643 executed, 0 skipped, 0 failures |
| Embedded native Wi-Fi bundle loading inside Catalyst | Passed; no Wi-Fi read or permission prompt needed for initialization |
| Final iPad build-for-testing | Passed with the new shared files and Mac-only build phase |
| Final iPad cleanup and adaptive Text preview tests | 6 executed, 0 skipped, 0 failures; preview observed 25 ticks, parent-body delta 0 |
| Real-board Mac runner | 1 test passed, covering both boards simultaneously |
| Native pairing inventory before and after | `pairedBoardCount=0` |
| Packaged app launch and offline screens | Faces, Text, Speak, Live, Video and Settings opened; iPad split layout visible |
| Packaged app Bluetooth scan | Found both exact board names; scan stopped afterward |
| Final Mac app exit | Confirmed no process for the installed executable |

The real-board runner verified board identities, GET_INFO, status, power and frame responses, one-step brightness changes and exact restoration. The final hardware log contains all four required proofs:

```text
80B54EF48E09 originalBrightnessRestored=true
80B54EF48E09 terminalDisconnectConfirmed=true
80B54EF74801 originalBrightnessRestored=true
80B54EF74801 terminalDisconnectConfirmed=true
```

The BLE terminal callbacks and peripheral states were confirmed before the test returned. Bluetooth permission for RinaBoard was already enabled; scanning from the final packaged app worked without a new Allow prompt. System Settings did not list either board under My Devices. Neither board had a stored pairing to remove, and no pairing was created. Unrelated Bluetooth devices and the global Bluetooth switch were left alone. The application was closed after the scan check.

## Review and limits

Independent subagents implemented cleanup and the native adapter, diagnosed the missing environment dependencies in the regular-width preview test, and reviewed the final project/platform/cleanup integration. The preview performance assertions were preserved. Grok's bounded parity consultation reached its turn limit without a usable result; no changes or conclusions were attributed to it.

Apple's [Wi-Fi configuration documentation](https://developer.apple.com/documentation/networkextension/wi-fi-configuration?changes=_10_4) states that NEHotspotConfigurationManager is iOS-only. Attempting Mac provisioning with the iOS Wi-Fi entitlements was rejected; those entitlements were removed from Mac. Direct Catalyst CoreWLAN Swift calls were also rejected by the SDK, so a native macOS bundle uses public CoreWLAN behind the shared HotspotJoiner facade. Exact/prefix identity checks, missing SSID and underlying error propagation are tested, and the signed Catalyst host successfully loads the embedded component.

Physical hotspot association, microphone capture and video playback against a board were not exercised in this session. The physical test specifically covered BLE identity/status/frame/power/brightness, and it did not change network configuration, saved faces or timelines. The package is locally signed for this Mac, not notarized for public distribution.

Relevant session logs (temporary): `/tmp/rina-mac-verification/mac.log`, `/tmp/rina-mac-release-build.log`, `/tmp/rina-mac-ipad-build.log`, `/tmp/rina-mac-ipad-tests.log`, `/tmp/rina-mac-final-boards.log`, `/tmp/rina-mac-final-hardware-runner.log`, `/tmp/rina-mac-pairing-after.log`.
