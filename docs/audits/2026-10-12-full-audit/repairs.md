# Audit repairs and deployment — 2026-10-12

This follows the full-source audit at `e6ac30b3b727fbbafd4fd16dfc8cb47b98dff297`, including the user's existing working-tree changes. No commits, pushes, merges, factory resets or filesystem uploads were performed. Original audit records remain historical evidence.

## Repairs

| Area | Result |
|---|---|
| Firmware FW-A1–A3 | Battery overlays retain their sampled values; already-ended group playback becomes paused; group playback and controls share the effective loop preference. |
| Firmware FW-A4–A6 | Central AP validation and application result; rejected reconfiguration preserves an existing hotspot and its HTTP/DNS recovery; configured profiles are considered across the full scan; temporary scanning restores an off radio. |
| Firmware FW-A7–A12 | Reject ambiguous face identities before committing; render-task failure runs the same service on the main loop; carrier teardown precedes registry reuse; failed LED refresh retains presentation ownership; aggregate host dependencies link correctly; hint rendering has its specified priority. |
| iOS LOGIC-1/2 | CloudKit fetched-batch decode/validation failures block checkpoints until durable replay; cancelled group starts clean up accepted members in a fresh, bounded task with the existing lease/epoch guards. |
| iOS UI-1–5 | Lip sync deduplicates the composed frame; media sliders implement explicit accessibility adjustment; diagnostics retain board/session provenance; passive watch echoes bypass crown input; terminal queries/settings preserve active producers. |
| Video playback | Native AVPlayer decoding replaces the failing composition/output combination; frame processing preserves orientation/reflection; still generation uses the upright sampling box; waiting and failed playback states are handled correctly. |
| Test software | Real board-identity permutations, reordered distinct replies, actual BLE bookkeeping and waiter phases, real sink deallocation, running watch-option locks, meaningful rendered-starfield assertions, isolated defaults, current UI semantics and deterministic animation fixtures. |
| Host tools | Per-board emulator state and serialized writes; short-audio correlation; dependency-aware C++ builds; XCTest/Swift Testing skip-aware and mixed-framework gates; explicit FaceSync/guard/UI lanes; archived child/CSV failure propagation; one-time soak records; optional positive-delivery oracle contracts. |
| Archived Swift harnesses | Current reflected bookkeeping, checked throwing encoders, group ownership cases, and XCTest failures for every recorded FAIL; all nine sources typecheck without errors/warnings. Historical outputs are unchanged. |
| Catalog | Nine active keys no longer marked stale; existing translations and catalog formatting preserved. |
| Hardware-discovered startup issue | Decoded the actual matching-ELF `ipc0` stack-canary panic in the SDK BLE interrupt allocator. A reviewed linker wrapper gives only the SDK IPC tasks a 2048-byte minimum; other task creation arguments/budgets remain unchanged. Final deployment verification is recorded below. |

The detailed repair and independent-review records sit beside this report: `repair-firmware.md`, `repair-ios-behavior.md`, `repair-tests.md`, `repair-archived-ios.md`, `review-repair-tools.md`, `review-repair-firmware.md`, `review-repair-video.md`, and `hardware-boot-diagnosis.md`. Independent review found the AP activity rollback, portrait still-size and verification-gate issues; all were corrected.

## Software verification

| Check | Evidence |
|---|---|
| Full Core suite | 373 reported, 11 skipped, 362 bodies, zero failures. `ios_test_counts.py` was corrected so XCTest skips are not counted a second time as Swift Testing skips. |
| FaceSync package and firmware guard | 69 Swift Testing tests and 19 C++ preflight assertions passed. |
| Full app unit suite | 631 tests, zero failures, Xcode exit 0. Latest video changes additionally passed all 17 video tests, including a nonsquare 90° asset. |
| App concurrency build | Passed; distinct diagnostic sites reduced from 50 to 29 and the gate baseline lowered to 29. This is not a claim of Swift 6 migration or zero warnings. |
| UI verification | Five final acceptance tests passed sequentially; eight snapshot/workspace tests passed; repaired phone navigation tests passed separately; three iPad rotation tests passed. Four physical-board UI tests skipped on the simulator. An earlier concurrent UI run failed; its final partial summary is not presented as a passing full run. |
| Firmware host suite | Aggregate suite passed; production-TU ASan/UBSan regressions cover audit fixes and the independently discovered AP rollback; the new IPC wrapper regression reproduced the old budget, then passed. |
| CloudKit reference integration | Real malformed/invalid-batch checkpoint/restart/replay checks passed; the complete delegate typechecked against the Apple SDK in Swift 6. It remains outside shipping targets. |
| Other checks | Sixteen host-tool regressions, nine i18n tool tests, opt-in release DSP gate, and current catalog check passed. |
| Local media | All eight AAC transcodes correlated at zero-sample lag, correlation ≥0.998; copied MP3 decoded. Used resident byte snapshots after requesting iCloud materialization, because the host was evicting inputs between decoder calls. The inherited LUMF timeline exceeds its upstream audio by about one second and is reported as source-data behavior. |

Raw logs remain under `/tmp/rina-*`; durable deployment summaries and image hashes are saved beside this report. Grok's bounded concurrency offload reached its turn limit without edits; Codex completed and verified that work locally. Three repair subagents and independent cross-reviews were used alongside the Matt Pocock, iOS, debugging, planning, TDD and verification skills.

## Deployment verification

Final IPC-fix firmware built successfully (`esp32s3-rmt-dma`, Arduino 3.3.9 / IDF 5.5.4). ELF disassembly proves `esp_ipc_init` calls `__wrap_xTaskCreatePinnedToCore`, which forwards to the original allocator. Final application SHA-256: `0787c69f14091a1462f26217b06c06d391f28f7a958c806adffb38cf3341f8d3`.

Both boards were reflashed with that image; esptool returned exit 0 and verified each written hash. Three new boots per board passed: correct board identity, BLE advertising, RMT DMA ready, zero refresh failures, zero panics, and the prior 11 saved faces plus brightness/color/mode/face selection/interval preserved. Six boot results are in `deployment-boot-verification.json`; image and backup hashes are in `deployment-image.json` and `deployment-backups.json`. Raw protected data backups remain in `/tmp`; no saved data was erased.

The preceding image's second-board startup panic was decoded and corrected before this final deployment. Repeated successful boots are bounded runtime evidence, not a guarantee against every future hardware failure.

USB identities: `/dev/cu.usbmodem5AE70745091` hardware MAC `80:b5:4e:f4:8e:08`, and `/dev/cu.usbmodem5AE70735521` hardware MAC `80:b5:4e:f7:48:00`. The firmware's BLE-derived board IDs end in `...09` and `...01` respectively.

Their partition tables match the build layout. Complete NVS/OTA and LittleFS backups were read at 115200 baud before uploads. High-speed read-only backups failed and were replaced with verified complete slow transfers. Uploads write only bootloader, partition table and application; NVS, OTA metadata and LittleFS are excluded.

## Practical limits

VoiceOver and WatchConnectivity hardware interaction, real CloudKit account synchronization, radio interruption, battery/flash power-loss and long-duration hardware stress were not exercised. The simulator's physical-board random walk is not a positive-delivery hardware oracle; the archived oracle now exposes explicit action/state/delta contracts for that purpose. Architectural suggestions and the intentional unauthenticated control policy were not converted into unrelated redesigns.
