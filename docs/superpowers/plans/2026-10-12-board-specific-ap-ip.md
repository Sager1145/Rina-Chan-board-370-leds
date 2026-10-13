# Board-specific hotspot IP implementation plan

> For agentic workers: execute the bounded firmware, shared connection and UI tasks in parallel; root integrates and runs one complete batch of builds, flashes and physical retests.

Goal: Each board boots production firmware with a distinct persisted hotspot IP, exposes it over BLE, and supports a manually edited hotspot IP in the shared Mac/iPad app.

Architecture: Generate the factory IPv4 address from the last 24 bits of the firmware's stable board identity. Use 10.a.b.c for valid /24 host octets 1–254. Remap the .0/.255 identities injectively into valid hosts in 172.16/12: index=(suffix>>8)*2+(last==255), subnet=index/254, address=172.(16+subnet/256).(subnet%256).(index%254+1). Persist a private /24 IPv4 override; factory reset returns to the hardware-derived value. Configure a DHCP pool that excludes the gateway. Shared app records the reported AP host separately from router Wi-Fi host; every direct/saved hotspot dial resolves the actual host and verifies physical identity.

Stack: Existing ESP32 Arduino/IDF, NVS, RinaLink protocol, shared SwiftUI/Catalyst and RinaCore.

Constraints: Preserve board faces/names/home profile cleanup and existing user changes. Do not alter Bluetooth availability or require system pairing. No commits/pushes. User prefers batch tests → issue list → batch fixes/build/flash → whole batch retest. Restore test edits and disconnect after testing.

## Firmware task

Files: esp32s3_firmware/src/{config.h,config.cpp,wifi_manager.h,wifi_manager.cpp,protocol.cpp,serial_console.cpp}, a pure address policy header and matching host tests.

- Add deterministic default generation and strict private IPv4 validation; test A=10.244.142.9 and B=10.247.72.1 plus .0/.255 remapping, invalid/public/reserved host rejection.
- Persist/load the AP IP override without erasing other NVS. Report current configured IP through existing wifi_status.apIp and serial STATUS.
- Extend wifi_set_ap with optional `ip`; omitted IP retains current IP. Reject invalid values without mutation. Configure safe DHCP pool; acknowledge before any disruptive AP restart. Preserve BLE. Serial production IP setting is optional if necessary for existing tooling, not a new dependency.
- Test strict host suite, build one production image, root flashes both boards after shared app integration.

## Shared connection task

Files: RinaCore address policy/RinaCommand, HotspotJoiner, KnownBoard/BoardStore, BoardSessionStore, ConnectionViewModel and their focused tests.

Interfaces: `.wifiSetAp(ssid:password:ip:)` adds optional String IP with nil default. `ConnectionViewModel.setAp(ssid:password:ip:connection:boardStore:)` adds optional IP with nil default. Keep older call sites valid. `KnownBoard.hotspotIP` stores AP host independently of lastHost for router Wi-Fi. `HotspotJoiner.makeTransport(host:)` accepts actual AP host.

- Mirror firmware factory policy and private /24 validation in RinaCore; pin shared vectors.
- Prefer BLE-reported wifi.apIp and saved hotspotIP. For a new default SSID derive its factory IP; retain legacy saved address compatibility. Resolve address for the joined physical board, not the board previously selected.
- Persist AP identity/address after BLE/save/IP update, preserving stable BLE UUID, sibling records and known aliases. Validate expected physical identity in all hotspot dials. Reject known sibling IP conflicts on manual update. Keep Home Wi-Fi address separate.
- A configuration update returns success/failure and refreshes board status; no false successful saves. IP-only update must preserve SSID/password.

## Shared UI task

Files: BoardNetworkSettingsView, SettingsWorkspace and focused relevant tests/localizations.

- Display Wi-Fi and hotspot addresses via BLE. Add an editable hotspot IPv4 field, Save IP action with clear validation/success feedback; IP-only edit preserves SSID/password. Use the existing scoped workspace model so drafts survive resize and clear on board change.
- Use `setAp(ssid:"",password:"",ip:<draft>,...)` for IP-only command; firmware treats empty fields as retained for an IP-only edit. Continue existing SSID/password behavior when IP omitted.

## Root batch validation

- Review the integrated protocol/metadata and DHCP semantics; run meaningful firmware/address unit tests and combined Mac regressions. Build Mac Release and iPad simulator once after the complete batch.
- Flash both boards with the same production image, verify hash/boot/derived distinct addresses over serial and BLE.
- Actual Mac app: join A and B hotspots, single sends, BLE while AP enabled, sibling control, carrier changes, board selection, mirror/stitched group timelines and stop/layout/restart; manually change and reboot one IP, reconnect using actual edited host, reject invalid/conflicting IPs, restore factory IP.
- Preserve original manual face 7, 11 faces, brightness 50, color #f971d4, interval 3000 and blank test Wi-Fi profiles. Restore Mac BELL456, remove temporary test group, disconnect app sessions, verify no OS pairings and close serial captures.
