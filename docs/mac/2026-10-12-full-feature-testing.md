# Mac and real-board feature verification — 2026-10-12

This extends the earlier Mac port validation. The requested acceptance scope is
both physical ESP32s, all shared Mac/iPad feature families, in-app discovery and
connection, scanned Wi-Fi setup, explicit transport switching, and multiboard
operation. Test network credentials must be removed from both boards afterward.
Passwords are not recorded here.

Boards: `80B54EF48E09` and `80B54EF74801`. Connections use unbonded BLE; macOS
Bluetooth pairing is not needed. Each board originally has 11 saved faces, a
manual 34-LED frame, brightness 50, color `#F971D4`, and interval 3000 ms.
Both originally have no station network and use board-hotspot mode.

## Confirmed fixes and software checks

- Shared network UI removes the separate iPhone/Personal Hotspot setup and uses
  board-discovered network rows. Explicit Bluetooth/Wi-Fi switching is available.
- A physical AP+BLE scan completed with 19 networks in 8.780 seconds; the former
  8-second app wait expired 619 ms before completion. Scan startup, main-loop
  response, and AP restoration all worked. Production wait now allows 65 seconds,
  covering the pinned driver's 60-second limit.
- Carrier switching checks the original physical identity before accepting a
  candidate and retains host aliases only after a confirmed connection. This
  prevents a reassigned cached IP from replacing one group member with another.
- Wi-Fi forgetting clears the matching IDF station configuration and active or
  pending profile, preserving the other profile, requested mode, AP, and control
  carrier. Five regressions failed before the fix; all 19 firmware audit repair
  cases pass under ASan/UBSan with strict compiler warnings.
- A real Catalyst timeout alert had correct title/message/OK accessibility data
  but painted a blank white window. Mac error presentation now uses a SwiftUI
  sheet; physical visual verification confirmed the title, message, and working
  OK button. iPad retains system alerts.
- Shared Mac suite: 654 executed, zero skips, zero failures before the later
  identity and error-sheet changes. Focused identity/manual-host/scan suite:
  12 executed, zero skips, zero failures. iPad network UI regression: one executed,
  zero skips, zero failures after correcting its boot-overlay wait.

## Physical acceptance matrix

### Mac titlebar regression

The user reported a half-width titlebar background/divider on any tab. The split
pages have independent scroll views: the left preview is pinned while the right
list reaches the top. Native scroll-edge rendering and underlap therefore
affected only one half of the shared Mac titlebar.

`RootTabView` now applies a single Catalyst-only policy to all tab content:
hide the per-scroll-view top edge effect on iOS 26+, and clip the shared page
container to its safe-area bounds. Hiding the effect alone removed the divider
but allowed video timeline content to paint under half of the titlebar; clipping
was verified to stop that underlap and retain a continuous system titlebar.

Release Mac build and iPad simulator build passed. Visual checks covered all
five tabs, both Live/Video modes, real list scrolling in a shortened window,
normal/maximized windows, and repeated tab switching. The installed app is
`/Users/sager/Applications/RinaBoard-Mac/RinaBoard.app`.
Build logs: `/tmp/rina-mac-topbar-clip-build.log` and
`/tmp/rina-topbar-ipad-build.log`. This UI verification does not complete the
pending physical-board feature matrix below.

Statuses below distinguish implemented test coverage from executed acceptance.

| Feature | Planned real-board verification | Status |
| --- | --- | --- |
| Discovery and reconnect | Both boards added/connected inside app; terminal disconnect | Passed real BLE stress and expanded production-path suite |
| Wi-Fi provisioning | Select actual scanned SSID, join both, BLE remains usable | Passed installed-app provisioning and physical BLE coexistence |
| Carrier identity | Same board BLE ↔ TCP; sibling remains connected and unchanged | Passed physical identity/peer preservation checks |
| Individual controls/faces | Editor, brightness/color, manual/auto, temporary face CRUD/import/export | Passed both physical boards |
| Text | Real upload/play/pause/seek/step/speed/loop/stop and frame readback | Passed both physical boards |
| Performance/video | Actual WAV playback and AVAsset decode/quantize/send | Passed single and group paths |
| Microphone | Actual PCM and production analysis/composition/start/stop | Passed actual 48 kHz PCM, both boards and group paths |
| Multiboard | Both BLE, mixed BLE/TCP, both TCP; mirror/stitched/gap/slot swap | Passed all three carrier configurations |
| Group controls/rejoin | Group controls/media and switching during playback | Passed controls/media, active carrier changes and member rejoin |
| Native board-hotspot join | Mac CoreWLAN bridge, TCP, restore prior Mac network | Waiting on user choice for Location Services; Mac remains on original BELL456 |
| Debug/telemetry | Safe commands, patterns, status/power/log subscription | Passed both physical boards with serial capture |
| Recovery | Original faces/settings/output/name restored; reboot persistence | Passed both boards, before-restoration persistence readback |
| Final cleanup | Forget test networks, reboot/readback, disconnect, zero board bonds | Passed Wi-Fi erase, post-reboot empty profiles, app zero-online, both serial disconnects and zero bonds |

## Deployment and evidence

### Real-data stress sequence and initial run

The user requested a sequence first and actual Mac app control with serial
diagnostics. The sequence is: capture originals; stress each board; stress both
boards as a group; repeatedly switch selected boards and carriers; restore and
remove test networking/disconnect. The new BLE-only runner is
`bash tools/test_mac_stress.sh`, with the same `RINA_MAC_SIGN_IDENTITY` as the
installed app. It requires both explicit hardware and stress opt-in flags,
checks positive execution counts, all phase markers, restoration, and no bonds.

`MacBoardStressHardwareTests` uses production control/editor/session/fanout
paths, not mock transports: 50 frames per single board, 50 group frames in each
of mirror/stitched control modes, settings bursts, and 20 selected-board switches.
Each iteration reads back physical target and peer state. It reports measured
timing rather than claiming the requested 10 FPS was achieved. It preserves
resident timelines and does not upload stitched text or reboot; those operations
remain in the separate full feature suite.

The initial stress run compiled and executed one test, zero skips, one failure:
`Bluetooth scan did not become ready`. It failed before connecting or sending
any frame/control update. Both unused carriers were confirmed disconnected;
pairing inventory remained zero. This is not a hardware stress pass.

Serial status on both boards remained brightness 50, `#F971D4`, manual face 7,
11 faces, 34 lit LEDs, and `accepted=1`. No test Wi-Fi credentials were entered.

Live Mac logging identified the blocker precisely: tccd reported
`Failed to match existing code requirement` for `com.rinachan.board.mac` and
`kTCCServiceBluetoothAlways`, followed by `AUTHREQ_PROMPTING`. The old Settings
ON state does not authorize the new signing requirement. Modern codesign
entitlement decoding confirms valid DER Bluetooth/sandbox entitlements; the
deprecated XML-dump warning is not evidence of missing effective entitlements.
A bounded Grok read-only consultation supported checking the actual TCC result;
the later live trace supplies the decisive signature-mismatch evidence.

Refreshing only RinaBoard's existing Bluetooth permission in System Settings
opened a Touch ID authentication challenge. The user completed local
authentication; the same signed Mac test host subsequently reported authorization
3 and discovered and connected both boards. No new entitlement, global Bluetooth
toggle, or unrelated-device change was applied.

Logs: `/tmp/rina-real-board-stress.log`,
`/tmp/rina-stress-serial-80B54EF48E09.log`,
`/tmp/rina-stress-serial-80B54EF74801.log`, and
`/tmp/rina-stress-bluetooth-init.log`.

Application firmware image SHA-256:
`31f8f501d55ee0dc2df09b0c3470404e89a0ce52eb26a41e0e8c06160623b6a4`.
Only application offset `0x10000` is written. Fresh NVS/OTA backups and earlier
LittleFS backups are retained in `/tmp`; bootloader, partition layout, and saved
faces are preserved.

Both uploads exited zero with flash hash verification. Serial status after
reboot confirmed 11 faces, manual mode, face index 7, brightness 50, `#F971D4`,
3000 ms interval, 34 lit LEDs, and ready RMT DMA output on both boards.

The 1053-line expanded hardware suite compiled successfully. All three carrier
layouts now include group controls and real media/microphone fanout. Active group
text recovery also covers transport switching, natural rejoin, primary promotion,
and member disconnect/reconnect. Execution remains pending.

The installed Release app and compiled Debug hardware host now use the same
existing Apple Development signing identity through `RINA_MAC_SIGN_IDENTITY`.
An earlier ad-hoc host reported controller state 0 and authorization 0 while a
native Mac probe reported state 5 and authorization 3. The macOS privacy service
sample showed a pending user notification. Computer Use explicitly refused
access to `com.apple.UserNotificationCenter`; the user was asked to handle the
system dialog. No privacy settings or unrelated Bluetooth devices were changed.

Relevant logs: `/tmp/rina-wifi-diagnostic-80B54EF48E09.log`,
`/tmp/rina-feature-verify/mac.log`, `/tmp/rina-network-identity-regressions.log`,
`/tmp/rina-feature-ipad-ui-retry.log`, and
`/tmp/rina-feature-firmware-forget-build.log`.

The expanded opt-in runner is `tools/test_mac_features.sh`. Software test success
does not establish physical feature acceptance. This report remains in progress
until the matrix and final credential/disconnection cleanup are complete.

### Executed BLE stress after permission refresh

The first connected run exposed a real test-harness sandbox failure saving the
recovery file to global `/tmp`; both suites now save and report their recovery
file under `FileManager.default.temporaryDirectory`, outside deleted scratch
folders. The repaired stress run passed: one executed, zero skipped, zero failed,
73.477 seconds. It sent 50 frames per single board and 50 group frames per
mirror/stitched control mode, plus settings bursts and 20 selected-board switches.
Physical target/peer readbacks passed throughout. Stitched editor frames are
mirrored intentionally; this run does not establish stitched text/media coverage.

Round-trip validation limited measured frame rate to 5.46–5.90 FPS; requested
10 FPS is not claimed as achieved. Serial capture showed 162 frame applications
per board including restoration, no panic or LED refresh failure. Both originals
were restored (manual, brightness 50, color `#f971d4`, face 7, 11 faces, interval
3000 ms, 34 lit LEDs), and both terminal BLE callbacks were confirmed. Pairing
inventory returned `pairedBoardCount=0`. No Wi-Fi credentials were entered in
this stress run.

Xcode project reading stalled in NSFileCoordinator on the iCloud-backed project.
An identical local source copy under `/tmp/rina-stress-local-source` allowed
building and executing without altering repository layout or permissions.
Evidence: `/tmp/rina-real-board-stress-fixed.log`,
`/tmp/rina-stress-live-serial-80B54EF48E09.log`,
`/tmp/rina-stress-live-serial-80B54EF74801.log`.

### Installed-app Wi-Fi and password-sheet repair

The installed Release app reproduced two SwiftUI environment assertion crashes
while using the scanned-network password sheet (crash reports at 14:03:36 and
14:04:33). The sheet now receives its SettingsWorkspace and selected
BoardConnection explicitly at construction instead of resolving required
observable environment values during presentation/teardown. The shared-source
Mac Release build, signature verification, and iPad simulator build passed.
Physical regression: opened scanned Ciallo network, entered password, cancelled
with Escape, reopened, and successfully provisioned both boards without a crash.

Both boards joined the scanned test network using the installed app while both
BLE sessions remained online. The initial automation credential entry was empty
because the secure field's AX click did not focus its actual typing region;
coordinate focus and masked-length verification corrected it. Network inputs
were taken from real scan rows, not a manually entered SSID. Temporary test
credentials were subsequently erased on both boards and verified after reboot.

First expanded run exercised both boards' editor/face CRUD, text, WAV performance,
video, debug/status/power, Wi-Fi coexistence, carrier identity, and active group
carrier switching/member rejoin. It restored both originals and verified reboot
persistence but failed overall. The microphone assertion expected lowercase
`lipsync`; firmware and protocol specify `lipSync`, and serial confirms frames
applied. That test assertion and preflight guards are corrected. Group speed/loop
checks also expected a paused update to reach firmware immediately, although
production deliberately applies it upon resume. Those checks are being repaired
and rerun; this first expanded run is not recorded as an overall pass.

Evidence: `/tmp/rina-mac-password-sheet-build.log`,
`/tmp/rina-password-ipad-build.log`, `/tmp/rina-full-feature-real.log`.

### Expanded-suite passing repeat and network cleanup

The repeated real-board suite passed: one executed, zero skipped, zero failed,
186.958 seconds. It covers the feature families in the matrix above through the
real Mac app host and production models/transports; this is distinct from
manual UI verification of every individual widget. The repeated checks use the
canonical `lipSync` owner. Paused speed changes must preserve held physical
frames and the old timing/loop, then resume must apply actual interval 83 ms and
loop=false. Carrier-switch peer baselines require three stable idle physical
frames; exact generation, carrier, identity and frame preservation remain.

Both BLE, mixed BLE/TCP, and both TCP groups passed real controls, media,
mirror/stitched text, gap/slot swap, timed pause/step/resume/stop and speed/loop.
Active-playback carrier switching, primary promotion, natural member rejoin,
disconnect/reconnect, retained target, and original timeline continuation passed.
Both boards restored original full face documents/settings/output/name and
verified reboot persistence before runtime restoration. Evidence:
`/tmp/rina-full-feature-fixed.log`,
`/tmp/rina-network-mode-build/Logs/Test/Test-RinaBoardMac-2026.10.12_14-21-43--0400.xcresult`.

The installed app then forgot the test network on each board, changed each back
to hotspot-only mode, rebooted each, and showed empty Home Network and Connected
Network fields. Serial confirms `event=credentials_clear driver_erased=1` on both
boards, followed by clean boots and original manual face 7/11 faces, brightness
50, color `#f971d4`, interval 3000 ms, 34 lit LEDs, refreshFail=0. No panic,
assertion, brownout or nonzero LED refresh failure appeared in captured logs.
Pairing inventory remains zero. Native Mac hotspot join waits for Location
Services consent, currently off for RinaBoard; the Mac remains on BELL456.

Final cleanup: installed app showed both boards Not Connected and 0 online, then
quit. Both serial logs end their client lifecycle with `client_disconnect`.
Serial capture was closed and pairing inventory again returned zero. Mac Wi-Fi
association remains original BELL456. Native hotspot testing is the only listed
connection path still awaiting Location Services authorization; no grant was
changed and no Mac network association was changed during that pending request.

### Transparent Mac top bar

At the user's request, the shared Catalyst root now hides the native tab bar
background and attaches the common Rina backdrop outside the existing content
clip. The backdrop can paint through the full title/tab bar while scrollable
page content remains below it. Visual checks covered Faces, Text, Speak, Live
(Video mode), Settings, and independent left/right scrolling; the former
half-width divider/underlap did not return. Mac Release build and signature
verification passed, as did the shared iPad simulator build. The installed app
was left on Faces with its automatically reconnected board disconnected; pairing
inventory is zero. Logs: `/tmp/rina-mac-transparent-topbar-build.log` and
`/tmp/rina-transparent-topbar-ipad-build.log`.

### Mac window single-column adaptation

MacWindowLayout measures the window and passes its width through a dedicated
environment value to BoardSplitPage and Settings. It does not override the
system horizontal size class: doing so makes Catalyst move native top tabs to
a phone-style bottom bar. Mac uses a 1024-layout-point split threshold to allow
comfortable columns with Catalyst scaling; iPad's existing rule is unchanged.
The native scene permits a 520×600 minimum. In compact mode board controls are
embedded after page controls in the single List; no bottom accessory is used.

Final focused run: 18 executed, zero skipped, zero failed (five Mac window
regressions and 13 existing Settings navigation tests). Runtime scene limits
were verified. Mac universal Release build/signature and iPad simulator build
passed. Physical UI checks used native window half/fill sizing on the built-in
Retina display: all five tabs switched to single-column content while retaining
the transparent native top tabs. Controls were reachable by scrolling; wider
windows restored two columns. Settings About selection survived widening, and
the exact text-entry accessibility value survived wide→narrow resizing.

Logs: `/tmp/rina-mac-compact-native-tabs-build.log`,
`/tmp/rina-mac-compact-native-tabs-tests.log`,
`/tmp/rina-mac-compact-native-tabs-ipad.log`.

The user has now explicitly approved Location Services for native hotspot
testing. Only RinaBoard's app switch was changed from off to on; other app and
system permissions were left unchanged. Native hotspot acceptance continues
after the completed adaptive-layout checks.

### Batched native-hotspot acceptance

User-approved RinaBoard Location Services enabled native CoreWLAN hotspot
association from inside the app. The Mac joined A's unique SoftAP and received
a verified TCP handshake. A real Faces send produced serial
`custom_face_send`, 34 lit LEDs, and accepted counter 1→2. B's simultaneous
Bluetooth connection sent a face and ran the 325-frame text timeline; pause,
step forward/back, resume and stop were exercised in the installed app. B
continued playing while the hotspot session retried.

The remaining problems were collected before another build, per the user's
batched-test instruction:

1. Legacy saved BLE/AP entries could resolve to separate sessions for one
   physical board, inflating online count.
2. A retired exact AP alias could outrank the live BLE identity, leaving two
   owners and an alternating TCP reconnect cycle.
3. Saved-record deduplication could discard the old AP address metadata.

Unified repair retains the verified selected session, merges all carrier
aliases, disconnects/removes retired same-board sessions, and preserves saved
BLE/AP metadata. Unknown physical identities are only merged after a successful
handshake. Sibling physical boards sharing the AP IP remain distinct.

Native AP media and mixed AP/BLE group acceptance are pending the single batch
build/retest below; prior full-feature and stress results above remain separate
evidence.

Second batch findings from actual installed UI:

- Legacy row consolidation now yields two physical board rows, 2 online.
- Native AP PING timeouts reproduce on both boards. Independent matched PING
  diagnostic (not app control) also times out after replies of 13 ms and
  1035 ms. Serial DEBUG records failed PING reply type 134; it does not yet
  distinguish the causal network/socket error. A Wi-Fi-address-bound SYN also
  times out. Both wireless off/AP transitions via BLE succeed and BLE stays
  available. No firmware deadline change is justified by this evidence alone.
- Reconnecting after a genuine drop redirects Text to Faces; board-state
  reconciliation must preserve the user-selected tab.
- Actual temporary two-member group creation, identification and stitched
  timeline/pause/step/resume succeeded. Stopping, changing to Mirror and
  starting exposed automatic adoption replacing an explicit preparation ID,
  leaving the UI Starting after reporting cancellation. The same unchanged
  Mirror retry reproduces it. Stop clears the stuck state and both physical
  boards restore saved face 7, 34 lit LEDs.

The second software batch preserves tabs on genuine reconnect and refuses
automatic adoption while an explicit start already owns preparation. Focused
regressions cover real delayed-start concurrency and state reconciliation.
Native AP packet capture requires local Mac administrator authentication; the
requested command captures only board TCP headers, and is pending user setup.
