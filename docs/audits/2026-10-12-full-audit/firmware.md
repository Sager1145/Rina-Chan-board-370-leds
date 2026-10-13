# Firmware audit (2026-10-12)

Read-only audit of production source, config, build/font tools, and all host tests. Correctness/spec and standards/architecture lenses are separated below. No repository source edited, no upload, radio, live device, or external-account action. Matt Pocock codebase-design skill read and applied.

## Actionable correctness/spec findings

### FW-A1 [P2] Short battery overlays discard the fresh power snapshot
- Location: `esp32s3_firmware/src/button_animations.cpp:517` (startOverlay), especially 530–535; producer at 542–560; single-shot service branch at 722.
- Trigger: Fresh boot, then short B6 press or `CMD battery_overlay {singleShot:true}` with a healthy charged battery.
- Evidence: startBatteryOverlay builds next.batValid/batCharging/batPercent/batVbat/batVcharge, but startOverlay copies none of them into sAnim. Only continuous battery overlays get those fields refreshed by serviceButtonAnimations. drawBatteryPage consequently sees default false/0/NAN, or stale values from a prior long overlay.
- Impact: Board displays red 0% for the normal short-press battery check; after a long check it displays stale battery data.
- Fix: Copy the five bat* fields when starting the overlay, preserving button-input and pause-ownership fields explicitly. Test fresh single-shot and repeated short checks after changing power.
- Reproduced with extracted production startOverlay/startBatteryOverlay (fake power valid=true, percent=83, vbat=8): `battery fresh single-shot: valid=0 percent=0 voltage=nan`.

### FW-A2 [P2] Already-ended group playback never transitions to paused
- Location: `esp32s3_firmware/src/scroll_session.cpp:670` (and group start 614–632); helper `src/group_math.h:79`.
- Trigger: `group_start {loop:false}` on a one-frame raw timeline, startFrame equal to the final frame, or atUs old enough that GroupStart immediately selects the final frame.
- Evidence: GroupStart sets firmwareScrollPaused=false and publishes cursor.frame even if cursor.endedNoLoop. Tick returns before setting pause whenever the current index already equals that final frame. All subsequent ticks repeat the same return.
- Impact: The pixels hold correctly but firmwareScrollPaused/playback/end-of-timeline state remains active/scroll forever; clients fail to learn that playback finished.
- Fix: Separate the end-state transition from deciding whether a final frame needs a new presentation. Latch pause once even if the final frame is already current.
- Reproduced: `group one-frame no-loop: paused=0 pending=0 scrollLoop=1 groupLoop=0`; `group late start no-loop: idx=4 paused=0 pending=0`.
- Existing group_math test deliberately asserts the frame-latch predicate becomes false after the index changes; it never exercises the production state transition with a GroupStart that begins ended.

### FW-A3 [P2] Group playback has a separate loop preference that status and controls ignore
- Location: `esp32s3_firmware/src/scroll_session.cpp:604`, `:205` (SetLoop), `:299` (RewindIfEnded); wire status/meta read scrollLoop, not groupLoop.
- Trigger: Starting group playback with loop=false after boot (scrollLoop defaults true), then polling metadata or issuing set_scroll_loop/resume_scroll.
- Evidence: GroupStart assigns groupLoop only. The group tick consumes groupLoop; GET_SCROLL_META/status/preview expose scrollLoop. set_scroll_loop only changes scrollLoop, so it has no effect while groupTimed; resume's end rewind also checks scrollLoop, then clears group mode and uses the unrelated legacy preference.
- Impact: Status advertises looping for a non-loop group; loop controls can be acknowledged without affecting actual playback; resume from an ended non-loop group can wrap from the final frame instead of restarting frame 0.
- Fix: Use one effective loop preference or synchronize/update both at the group-control seam. Test loop true→false and false→true during group playback plus end/resume.

### FW-A4 [P2] RinaLink can persist unusable AP settings while reporting success
- Location: `esp32s3_firmware/src/wifi_manager.cpp:494` and `:88`–94; protocol handler `src/protocol.cpp:617`; HTTP validation exists separately at `src/web_setup.cpp:358`.
- Trigger: `wifi_set_ap {ssid:"Board",password:"x"}` over BLE/TCP. Overlength SSIDs/passwords have the same unvalidated path.
- Evidence: The shared setter only rejects an empty SSID, persists the values, and returns true; startSoftAp ignores WiFi.softAP's boolean and unconditionally sets g_apActive=true. Pinned local Arduino core `/Users/sager/.platformio/packages/framework-arduinoespressif32/libraries/WiFi/src/AP.cpp:224` returns false for non-empty passwords shorter than 8 bytes. HTTP alone checks this, BLE/TCP do not.
- Impact: Response says ok and status reports a configured active AP that was not applied; the invalid credentials survive reboot and can remove the AP recovery path until BLE/physical reset repairs it.
- Fix: Centralize valid Wi-Fi byte lengths in wifiManagerSetAp, validate before persisting, handle softAP failure, and report actual AP state/result across every adapter.

### FW-A5 [P2] Station selection loses visible configured networks below the scan display cap
- Location: `esp32s3_firmware/src/wifi_manager.cpp:313`–331, `:104`–111, `:164`–187.
- Trigger: Home/hotspot SSID is visible but outside the strongest 20 scan entries (common in dense apartment/venue environments); more than 64 entries can also exclude it before sorting.
- Evidence: Service retains at most 20 UI scan results and deletes the complete WiFi scan result. evaluateScanResults/ssidVisibleInScan use only that capped list to determine whether configured profiles exist.
- Impact: Board never attempts a reachable configured network and falls back/retries indefinitely, or selects phone hotspot despite a visible home network.
- Fix: Resolve configured home/hotspot visibility across all original scan results before truncating the UI list; keep the 20-result cap only for responses.

### FW-A6 [P2] A BLE scan leaves Wi-Fi enabled despite mode off
- Location: `esp32s3_firmware/src/wifi_manager.cpp:377`–385 and scan completion `:326`–329.
- Trigger: Set Wi-Fi mode off, then request wifi_scan over BLE (including scan-start failure).
- Evidence: StartScan switches WIFI_OFF to WIFI_STA, but cleanup restores only the temporary AP→APSTA transition; it never restores WIFI_OFF; the radio stays enabled until another mode application/reset. The stored g_mode remains off, whose service branch then skips mode management.
- Impact: UI reports Wi-Fi off while the station radio remains enabled; the battery-power/off preference is silently violated.
- Fix: Track and restore the pre-scan mode on both success and failure, or explicitly reject scanning in mode off with a clear contract. Do not overwrite a new mode applied while a scan is running.

### FW-A7 [P2] Bulk face imports accept duplicate/empty identities that make ID-pinned edits ambiguous
- Location: `esp32s3_firmware/src/storage.cpp:261`–278; dependent handlers `src/protocol.cpp:785` rename / `:864` delete / `:959` upsert / `:1328` apply.
- Trigger: BLOB faces import with two valid framed faces sharing an id (one default/one custom), or a default with id empty. Existing validation accepts it.
- Evidence: Validator checks category/count/order/default-presence/frame bytes, but never checks id non-empty/unique. Apply/rename/delete stop at the first match; upsert searches the entire array and retains the last match. Thus the same id can identify different faces for different commands, and default overwrite guards can be bypassed by the later custom duplicate.
- Impact: A successful import breaks stable face identity and can rename/apply/delete/update a different face than the editor loaded; an ID-based list cannot represent the library reliably.
- Fix: Validate unique non-empty ids during import before replacing the previous file; preserve existing library on rejection. Add duplicate/default-vs-custom and missing-id fixtures.

### FW-A8 [P2] A failed render-task creation leaves the board accepting changes with no renderer
- Location: `esp32s3_firmware/src/scroll.cpp:89`–92; `src/main.cpp:80`–81 and `:107`–109.
- Trigger: xTaskCreatePinnedToCore fails (e.g. insufficient internal task-stack memory) after mutex allocation succeeds.
- Evidence: startScrollRenderTask returns void, logs failure, clears handle. g_syncReady remains true. Main's only synchronous render fallback is conditioned on !g_syncReady, so no task will ever consume subsequent render requests.
- Impact: Board advertises/acknowledges color/frame/buttons and reports scrolling while LEDs remain at boot frame; this is a handled allocation failure with no functional recovery.
- Fix: Return/report render-task readiness separately from mutex readiness; use the existing single-thread render fallback when task creation fails and decline unsupported scroll capability accurately.

### FW-A9 [P2] Registry frees a client slot before clearing the BLE carrier's old mapping
- Location: `esp32s3_firmware/src/protocol.cpp:2636`–2639; `src/transport_ble.cpp:128`–143 and `:179`–206.
- Trigger/interleaving: Old BLE peer disconnects on host task (mConnected=false, slot disconnectPending); loop finalizes and sets c.used=false; a new onConnect preempts before transport->disconnect and claims the same free slot; old teardown's disconnect(ClientId{i}) then matches the new peer's slot and disconnects it.
- Evidence: Registry release and carrier clearing are ordered this way; ClientId has only a slot, no generation. BLE disconnect matches mClientId.slot only. The new disconnect callback sees mConnected=false after explicit disconnect and does not unregister the new claimed protocol slot.
- Impact: Fast reconnect can be spuriously disconnected and leave a registered phantom slot; repeated races can exhaust slots. Existing host critical-section fakes do not exercise this interleaving.
- Fix: Keep the registry slot unavailable until the old carrier mapping is cleared (call carrier disconnect before publishing used=false), or carry a checked generation/connection identity through registration/teardown. Deterministic callback-between-release-and-disconnect test should accompany it.
- Confidence: Static concurrency interleaving, not hardware reproduced.

### FW-A10 [P2] Successful render retry loses the precise presentation context
- Location: `esp32s3_firmware/src/led_renderer.cpp:306` (consume pending context) and `:391`–394.
- Trigger: Scroll start/seek/final tick refresh fails, RMT recovery succeeds and ready stays true, then requested retry succeeds before a later scroll tick changes the frame (particularly a paused seek/final frame).
- Evidence: First render consumes/clears the identity context before refresh. Failure requests render again without retaining it; successful retry consumes invalid default context and publishLedPresentedSample returns without recording it.
- Impact: LED finally shows the correct frame but GET_PREVIEW_SYNC keeps reporting the previous successfully latched frame indefinitely on a paused/static timeline.
- Fix: Preserve identity alongside the retried frame or requeue it only if no newer frame took ownership; test fail-once→success for a paused seek and final non-loop frame.
- Confidence: Static error-path trace; actual RMT fault timing not hardware reproduced.

### FW-A11 [P2] The advertised aggregate host test command cannot link the battery tests
- Location: `tools/protocol_selftest.py:25` (parent-owned tool); `esp32s3_firmware/test/host/battery_calibration_test.cpp:1`–3 documents the required implementation TU.
- Trigger: Run python3 tools/protocol_selftest.py from a fresh checkout.
- Evidence: Runner compiles every *_test.cpp as a standalone TU, but battery_calibration_test.cpp calls definitions from src/battery_calibration.cpp. Parent ran it and observed undefined-symbol linker failure before remaining suites run. Individual battery test invocation correctly links the implementation.
- Fix: Give this test its production .cpp dependency (or a small explicit build manifest) so the one documented suite command runs every test. Parent owns integration/verification.

### FW-A12 [P3] Overlay ordering contradicts the documented hint precedence
- Location: `esp32s3_firmware/src/led_renderer.cpp:358`–383; `test/host/group_identify_test.py:79`–88 locks in current ordering.
- Trigger: A control-mode pencil hint is active while a physical brightness/mode/interval overlay is shown.
- Evidence: docs/RINALINK_PROTOCOL_V1.md §9.2 states identify > hint > button overlay > content. Renderer draws hint only in the non-overlay else branch, so button overlay suppresses it. The test comment claims the spec ordering while asserting overlay comes before hint.
- Impact: Hint command can return shown:true while hint is hidden for the overlay's duration. Low-priority visible mismatch.
- Fix: Apply hint after whichever content/button overlay is selected (unless identify), or deliberately revise the contract and shown semantics if overlay priority is intended.

## Standards and architecture lens (suggestions, not automatically requested refactors)

1. **Deepen the playback module at its actual seam.** ScrollSession already owns cursor/buffer but exposes start/stop/timing helpers and mutable RuntimeState; faces.cpp, protocol.cpp, button_animations.cpp, scroll.cpp, storage.cpp coordinate the same ownership/pause semantics. Introduce a small command interface (load/transition/snapshot/tick) that owns effective loop, output takeover, and coherent publication. Keep hardware emission outside its locked implementation. This earns locality for FW-A2/A3/A8/A10; avoid a pass-through interface around each existing helper.
2. **Deepen Wi-Fi configuration instead of adapter-local validation.** Both HTTP and RinaLink really vary at this seam. One validated operation should return persistence/application results and actual state; adapters only decode/encode. Keep profile selection separate from presentation-capped scan results. This localizes FW-A4/A5/A6.
3. **Make client lifetime identity part of the transport interface.** The current interface makes callers know that slot reuse, deferred teardown and host callbacks must be ordered. A connection token (slot+generation), or a registry that owns the entire lifecycle until carrier removal, hides that implementation invariant and tests through the same interface as carriers.
4. **Give face identity validation one storage seam.** Import, incremental edits, apply-by-id and startup fallback should agree on unique ids, effective schema, and preserved defaults. Do not layer duplicate lookup rules in handlers.
5. **Auth threat-model decision is missing, not a spec violation.** BLE deliberately requests no security and RX is unencrypted; TCP has no credential gate; setup mutation handlers are enabled on STA as well as AP and have no authentication or origin token. Anyone reachable over the LAN/AP or nearby BLE can change credentials/mode, reboot, and replace stored faces. No plaintext passwords are returned in status. Recommend an explicit ownership/provisioning decision (physical setup window + authenticated owner token or equivalent) before claiming these surfaces are private. The no-bonding implementation is intentional in source, so this is separated from correctness defects.
6. **Source-pattern tests overstate behavioral coverage.** Host tests are a useful regression set, but many extract individual function bodies and replace state structs, mutexes, group cursor, hardware and dependencies; several only search exact strings. These cannot establish full translation-unit linkage, callback lifetime races, Wi-Fi mode/application outcomes, overlay output, or end-state transitions. Test production behavior at the modules' interfaces for the defects above. Existing pure math/stream tests provide meaningful behavior evidence and need not be replaced by redundant tests.

## Review coverage

- Read every production .cpp/.h under esp32s3_firmware/src (52 files), both config/build files, all three firmware tools, all 17 host tests (2542 lines), firmware metadata dotfiles, README.md, and docs/RINALINK_PROTOCOL_V1.md.
- saved_faces.json is a literal frame table: enumerated all 11 face records and all frame lengths/ranges/padding programmatically; read document structure and all non-frame metadata. All frames have 47 bytes, valid 0..255 values, and zero unused tail bits. Startup id exists. This is the only declared generated/literal-table inspection exception; no generated include source exists under src.
- Read battery_calib.json and runtime_settings.json fully.
- esp32s3_firmware/plan.md is a historical reconstruction document (1470 lines, old removed HTTP/WebUI architecture). Consulted its rendered recovery/testing/reconstruction sections only; parent owns repository-wide documentation coverage. It was not treated as a current specification over the implemented protocol.
- PlatformIO-generated .pio/dependencies excluded from exhaustive source coverage; inspected local pinned Arduino AP implementation narrowly to validate FW-A4. .DS_Store is binary OS metadata and excluded.

## Verification and limits

- Reviewer executed `python3 /tmp/rina-audit-probes.py`, which extracts actual production function bodies, compiles two C++17 host probes, and runs them. Outputs establish FW-A1 and FW-A2 and show FW-A3's mismatched stored booleans. First probe compile needed a correction to its fake constrain template; final probes both compile/run.
- Parent reports all 12 Python host scripts passed independently, aggregate protocol_selftest linker failure, and PlatformIO firmware build in progress. This report makes no broader build claim.
- No hardware, RTOS timing/ISR measurements, physical battery/LED validation, AP reconnection, NVS/LittleFS full/power-loss fault injection, live BLE callback scheduling, HTTP slow-body stress, or on-device allocator fault injection performed. Those findings marked static are trace-based, not reproduced hardware incidents.
- No current unsafe OOB write established in protocol blob chunks/bitmap expansion: capped frame counts, 64-bit offset bounds, staging before END and packed-frame tail validation are present. All reviewed transport frames are bounded to MAX_PAYLOAD_BYTES; oversized inbound frames close the carrier.
- No repo code changes, commits, pushes or external actions.

## Exhaustive reviewed file inventory

- `esp32s3_firmware/src/battery_calibration.cpp`
- `esp32s3_firmware/src/battery_calibration.h`
- `esp32s3_firmware/src/ble_frame_sender.h`
- `esp32s3_firmware/src/board_identity.cpp`
- `esp32s3_firmware/src/board_identity.h`
- `esp32s3_firmware/src/button_animations.cpp`
- `esp32s3_firmware/src/button_animations.h`
- `esp32s3_firmware/src/buttons.cpp`
- `esp32s3_firmware/src/buttons.h`
- `esp32s3_firmware/src/config.cpp`
- `esp32s3_firmware/src/config.h`
- `esp32s3_firmware/src/faces.cpp`
- `esp32s3_firmware/src/faces.h`
- `esp32s3_firmware/src/group_math.h`
- `esp32s3_firmware/src/inbound_frame.h`
- `esp32s3_firmware/src/led_driver.cpp`
- `esp32s3_firmware/src/led_driver.h`
- `esp32s3_firmware/src/led_presentation.h`
- `esp32s3_firmware/src/led_renderer.cpp`
- `esp32s3_firmware/src/led_renderer.h`
- `esp32s3_firmware/src/main.cpp`
- `esp32s3_firmware/src/power_monitor.cpp`
- `esp32s3_firmware/src/power_monitor.h`
- `esp32s3_firmware/src/protocol.cpp`
- `esp32s3_firmware/src/protocol.h`
- `esp32s3_firmware/src/psram_json.h`
- `esp32s3_firmware/src/scroll.cpp`
- `esp32s3_firmware/src/scroll.h`
- `esp32s3_firmware/src/scroll_session.cpp`
- `esp32s3_firmware/src/scroll_session.h`
- `esp32s3_firmware/src/serial_console.cpp`
- `esp32s3_firmware/src/serial_console.h`
- `esp32s3_firmware/src/serial_log.cpp`
- `esp32s3_firmware/src/serial_log.h`
- `esp32s3_firmware/src/state.cpp`
- `esp32s3_firmware/src/state.h`
- `esp32s3_firmware/src/storage.cpp`
- `esp32s3_firmware/src/storage.h`
- `esp32s3_firmware/src/sync.cpp`
- `esp32s3_firmware/src/sync.h`
- `esp32s3_firmware/src/tcp_frame_sender.h`
- `esp32s3_firmware/src/transport.h`
- `esp32s3_firmware/src/transport_ble.cpp`
- `esp32s3_firmware/src/transport_ble.h`
- `esp32s3_firmware/src/transport_tcp.cpp`
- `esp32s3_firmware/src/transport_tcp.h`
- `esp32s3_firmware/src/utils.cpp`
- `esp32s3_firmware/src/utils.h`
- `esp32s3_firmware/src/web_setup.cpp`
- `esp32s3_firmware/src/web_setup.h`
- `esp32s3_firmware/src/wifi_manager.cpp`
- `esp32s3_firmware/src/wifi_manager.h`
- `esp32s3_firmware/tools/build_ark12_merged.py`
- `esp32s3_firmware/tools/compile_ark_bdf.py`
- `esp32s3_firmware/tools/merge_mona12_emoji.py`
- `esp32s3_firmware/test/host/audit_protocol_test.py`
- `esp32s3_firmware/test/host/battery_calibration_test.cpp`
- `esp32s3_firmware/test/host/ble_frame_sender_test.cpp`
- `esp32s3_firmware/test/host/blob_ownership_test.py`
- `esp32s3_firmware/test/host/face_identity_test.py`
- `esp32s3_firmware/test/host/group_identify_test.py`
- `esp32s3_firmware/test/host/group_math_test.cpp`
- `esp32s3_firmware/test/host/group_start_range_test.py`
- `esp32s3_firmware/test/host/hint_led_test.py`
- `esp32s3_firmware/test/host/inbound_recovery_test.py`
- `esp32s3_firmware/test/host/output_mode_test.py`
- `esp32s3_firmware/test/host/playback_ownership_test.py`
- `esp32s3_firmware/test/host/presentation_telemetry_test.py`
- `esp32s3_firmware/test/host/rmt_recovery_test.py`
- `esp32s3_firmware/test/host/serial_network_scheduling_test.py`
- `esp32s3_firmware/test/host/stream_transport_test.cpp`
- `esp32s3_firmware/test/host/stress_findings_test.py`
- `esp32s3_firmware/platformio.ini`
- `esp32s3_firmware/partitions.csv`
- `esp32s3_firmware/.gitattributes`
- `esp32s3_firmware/.gitignore`
- `esp32s3_firmware/.vscode/extensions.json`
- `esp32s3_firmware/data/resources/battery_calib.json`
- `esp32s3_firmware/data/resources/runtime_settings.json`
- `esp32s3_firmware/data/resources/saved_faces.json`
- `README.md`
- `docs/RINALINK_PROTOCOL_V1.md`
