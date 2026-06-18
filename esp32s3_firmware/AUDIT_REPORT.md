# esp32s3_firmware — Code Audit Report

Scope: full repo audit for real bugs, UB, data races, memory corruption, protocol/API mismatches, build/parse failures, and hardware-safety edge cases. Files read in full: `platformio.ini`, all `src/*.h` and `src/*.cpp`, `data/index.html`, `data/app.js` (verified parse only — 352 KB), `data/resources/*.json`, `tools/test_m370_boundary.js`, and the matrix config in `data/app.js`.

Checks run:

Second-pass verification (2026-06-18):
- Codex bundled Node runtime: `node --check data/app.js` **pass**.
- Codex bundled Node runtime: `node tools/test_m370_boundary.js` **pass** ("M370 boundary tests passed").
- `pio run` **pass** (RAM 17.3%, flash 42.5%).
- `pio run -t buildfs` **pass** (LittleFS image built; gzip asset hooks completed).
- `data/resources/*.json` parse with PowerShell `ConvertFrom-Json`: **pass** for `battery_calib.json`, `runtime_settings.json`, and `saved_faces.json`.

Original check notes from the first audit:
- `node --check data/app.js` → **pass** (clean parse, no unterminated strings; the "mojibake" is valid UTF-8 Chinese in string/comment literals).
- `node tools/test_m370_boundary.js` → **pass** ("M370 boundary tests passed").
- `index.html`: balanced `<script>`/`</script>`, valid DOCTYPE, 30.7 KB.
- All three `data/resources/*.json` parse; `saved_faces.json` has 11 valid default faces (`category=unified_saved_faces`).
- `pio run` / `pio run -t buildfs`: **not runnable in this environment** (no PlatformIO toolchain/SDK). Recommended to run locally — see notes per finding.

---

## CRITICAL

### C1 — `loadSavedFaces()` writes past the fixed `autoFaces_[MAX_AUTO_FACES]` array (heap/data corruption)

- Severity: **Critical** (memory corruption; persistent; remotely reachable)
- Files / lines:
  - `src/storage.cpp:284-305` (the load loop, write at `:293`)
  - `src/storage.cpp:181-224` (`validateSavedFaces` — missing the same limit)
  - Backing storage: `src/state.h:177` (`RuntimeFace autoFaces_[MAX_AUTO_FACES]`, `MAX_AUTO_FACES = 128`, `config.h:112`)

Why it is a real bug
The load loop iterates over *every* element of the JSON `faces` array and, for each face whose `m370` normalizes, writes:
```cpp
RuntimeFace& runtime = runtimeAutoFaces()[runtimeAutoFaceCount()++];   // storage.cpp:293
```
There is no `runtimeAutoFaceCount() < MAX_AUTO_FACES` guard. `autoFaces_` is a fixed array of 128 `RuntimeFace`. `RuntimeFace` contains three heap-backed `String` members (`id`, `name`, `m370`). Once the index reaches 128, the code constructs/assigns `String`s into memory beyond the array — directly into adjacent `RuntimeStore` members (`autoFaceCount_`, `frameBits_`, `scrollFrameBits_` pointer, `scrollMeta_`, …) and then past the object. This is out-of-bounds write of String objects (writes heap pointers/lengths) → memory corruption, and on the `m370` assignment can free/overwrite arbitrary heap.

`validateSavedFaces()` (the gate for `POST /api/saved_faces`) also enforces no upper bound, so the corrupt file is accepted, **persisted to LittleFS**, then immediately loaded:
`web_api.cpp:1462` validate → `:1464` `writeSavedFaces` → `:1467` `loadSavedFaces(false)` → overflow. Because it is persisted, the device then **overflows on every subsequent boot** (`main.cpp:56 loadSavedFaces(true)`).

Minimal repro
`POST /api/saved_faces` with a body containing 129+ faces, each with `type:"default"`, a valid `order>=1`, and a valid 93-hex `m370` (at least one `type:"default"` already required). Validation passes, the file is written, `loadSavedFaces` runs, and the 129th valid face writes past `autoFaces_[127]`.

Expected vs actual
Expected: loader caps at `MAX_AUTO_FACES` (drop/reject extras), validator rejects > `MAX_AUTO_FACES`. Actual: unbounded write → corruption / crash / persisted brick.

Suggested fix
```cpp
// storage.cpp load loop:
for (JsonObject face : faces) {
    if (runtimeAutoFaceCount() >= MAX_AUTO_FACES) {
        Serial.printf("saved_faces.json exceeds MAX_AUTO_FACES=%u; extra faces ignored\n", MAX_AUTO_FACES);
        break;
    }
    ...
}
```
And reject at validation time so nothing over the limit is ever persisted:
```cpp
// validateSavedFaces(): count faces, then
if (faceCount > MAX_AUTO_FACES) { error = "too many faces; max is 128"; return false; }
```

Caught by a test/build check? Not by `pio run`. Would be caught by a unit/integration test that loads a >128-face `saved_faces.json`, or by an on-device POST of 129+ faces. Recommend adding such a fixture test.

---

## MEDIUM

### M1 — Nested spinlocks: `readPowerStatusSnapshot()` called while holding `sAnimMux`

- Severity: **Medium** (no deadlock, but violates the project's own locking rules; long interrupts-disabled window on the WiFi/HTTP core)
- File / line: `src/button_animations.cpp:537-572`, offending call at `:542`

Why it is a real bug
`serviceButtonAnimations()` opens a critical section on `sAnimMux` at line 537, and inside it (battery-overlay-active branch) calls:
```cpp
const PowerStatus power = readPowerStatusSnapshot();   // :542
```
`readPowerStatusSnapshot()` (`power_monitor.cpp:451-461`) itself does `portENTER_CRITICAL(&sPowerStatusMux)` and copies the entire ~120-byte `PowerStatus` struct. So a second `portMUX` is taken nested inside the first, and a sizeable struct copy runs with interrupts disabled on Core 0 — the core that also runs WiFi/HTTP/DNS. `state.h`/`sync.h` explicitly document "Existing code intentionally avoids nested mutexes"; this is the spinlock analogue and the exact pattern the audit brief calls out ("critical sections that … lock another spinlock").

It is not a deadlock today (both spinlocks are only ever taken in this order, both on Core 0, and `power_monitor` never takes `sAnimMux`), so the impact is increased ISR/latency jitter, which can perturb the very WS2812/WiFi timing this design tries to protect.

Repro / trigger
Long-press B6 to start the repeating battery overlay (`batterySingleShot == false`); `serviceButtonAnimations()` then runs the nested-lock branch every loop iteration while the overlay is live.

Expected vs actual
Expected: snapshot power data *before* entering the `sAnimMux` critical section, then only copy small scalars under the lock. Actual: full power snapshot taken under two nested spinlocks.

Suggested fix
Hoist the read out of the critical section:
```cpp
PowerStatus power;
bool needPower = false;
portENTER_CRITICAL(&sAnimMux);
needPower = sAnim.active && sAnim.kind == OverlayKind::Battery && !sAnim.batterySingleShot;
portEXIT_CRITICAL(&sAnimMux);
if (needPower) power = readPowerStatusSnapshot();   // outside any spinlock
portENTER_CRITICAL(&sAnimMux);
// ...use `power` to update sAnim fields...
portEXIT_CRITICAL(&sAnimMux);
```

Caught by a test/build check? No — compiles and usually "works." Needs design review / lock-order lint.

---

## LOW

### L1 — `/api/status` truncates `lastReason` to 15 chars (`FrameStateSnapshot.lastReason[16]`)

- Severity: **Low** (no corruption — `strlcpy` is bounds-safe — but a silent API-contract drift)
- Files / lines: `src/state.h:81` (`char lastReason[16]`), `src/led_renderer.cpp:204` (`strlcpy(s.lastReason, … , sizeof(s.lastReason))`), consumed at `src/web_api.cpp:518`.

Why it matters
Runtime reasons are frequently far longer than 15 chars (e.g. `firmware_text_scroll_stop_default_saved_face`, `startup_sequence_complete_saved_face`, `..._B3_clear_before_saved_face`). In `/api/status` the `renderer.lastReason` field is therefore truncated (to `"firmware_text_s"`), while the same value is sent **untruncated** elsewhere (`buildCommandReply` → `reply["lastReason"]` and `scrollStopEvent.reason`, both raw `String`). Any UI logic that prefix-matches `lastReason` from `/api/status` (the app matches reason prefixes like `text_scroll_`, `custom_`, `debug_`) sees a different value than from `/api/command`.

Expected vs actual
Expected: consistent reason string across endpoints. Actual: `/api/status` value is silently clipped to 15 chars.

Suggested fix
Enlarge the snapshot buffer to cover the longest reason actually used (e.g. `char lastReason[48];`), or serialize `runtimeState().lastReason` directly in the status handler under the frame lock as the command path does.

Caught by a build check? No. Caught by an API contract test comparing `lastReason` from `/api/status` vs `/api/command`.

### L2 — `HTTP_ANY` routes don't reject inappropriate methods (degrade-only)

- Severity: **Low** (AP-only device; safe degradation, but inconsistent with the brief's expectation)
- File / lines: `src/web_api.cpp:1533-1539`. `/api/status`, `/api/power`, `/api/frame`, `/api/command` are registered `HTTP_ANY` and never check `server.method()`.

`/api/scroll` (`:665-666`), `/api/scroll/meta` (`:983-984`), and `/api/saved_faces` (`:1482-1486`) *do* validate the method and return 405/handle OPTIONS. The four that don't will still behave safely: a `GET /api/frame` or `GET /api/command` hits `parseJsonBody` and returns `400 "empty JSON body"`; `POST /api/status` just returns full status. No state corruption, but a `DELETE`/`PUT` to `/api/status` returns 200 and there is no CORS preflight (`OPTIONS`) handling on these four (OPTIONS falls through to the handler instead of `handleOptions`).

Suggested fix: add the same `method()==HTTP_OPTIONS → handleOptions()` / non-GET-or-POST → 405 guard used by the other routes, for consistency and correct CORS preflight.

---

## Checked and OK (suspected issues disproven)

- **M370 93-hex / 372-bit vs 370-LED boundary.** Decode (`led_renderer.cpp:323-337`) guards `if (bit < M370_BITS)`; encode in firmware never sets bits 370/371; browser `frameToM370`/`m370ToFrame` (`app.js:4138-4163`) pad the last two bits to `0` and slice to `TOTAL_LEDS`. `tools/test_m370_boundary.js` passes, including the explicit 369/370/371 padding cases. Consistent end-to-end.
- **`ROW_LENGTHS`/`ROW_OFFSETS` coverage.** Sum = 370; `static_assert` at `config.h:96` holds; `app.js` `EXPRESSION_PARTS.matrix.row_lengths` (`:203`) and `num_leds:370` (`:202`) match `config.h` byte-for-byte, including serpentine flags.
- **Mutex ordering Scroll→Frame→Storage→HardwareBus.** No nested *mutex* found; all multi-domain sequences release one lock before taking the next (`led_renderer.cpp:220/261`, `scroll.cpp:31/60`, `faces.cpp`, `web_api.cpp` scroll upload). The only true cross-core concurrency (Core 1 scroll task vs Core 0 HTTP) is correctly partitioned.
- **Scroll append writes the frame buffer outside `scrollMutex` (`web_api.cpp:909`).** Safe: appended frames go to indices `>= scrollFrameCount`, while Core 1 only reads `< scrollFrameCount` (mod count); `scrollFrameCount` is published last under the lock (`:930`). Buffer base pointer is allocated once at boot and never realloced.
- **`normalizeM370` `compact[94]` buffer (`led_renderer.cpp:285-304`).** Writes are guarded by `if (compactLen < M370_HEX_CHARS)`; over-length input is rejected (`compactLen != M370_HEX_CHARS`).
- **`web_json.cpp` custom scanner.** Depth-limited (`JSON_MAX_DEPTH=32`), integer overflow-guarded (`:350`), string escape/`\u` surrogate handling and UTF-8 emission are bounds-checked; `extractJsonStringAt` indices stay in range.
- **`validateScrollSourceText` / `validateMetaIdString` (`utils.cpp`).** Correct UTF-8 validation (overlong, surrogate, >U+10FFFF, truncation) and length/charset caps; `sourceText` memcpy (`web_api.cpp:828`) is bounded by the prior `length() <= MAX_SCROLL_TEXT_BYTES` check and the `+1` buffer.
- **`handleApiScrollMeta` heap pairing (`web_api.cpp:982-1060`).** Every early-return path frees `textCopy`; `const char*` assigned to the doc stays valid until after `serializeJson` (freed only after `sendJsonDocument`).
- **"All LEDs on" debug path.** Gated by a `confirm()` power-warning in the UI (`app.js:10364-10377`) *and* firmware clamps brightness to `MAX_BRIGHTNESS=200` (`led_renderer.cpp:421`), so the worst case is bounded below full-white draw. Not a firmware hazard.
- **`PowerStatus` partial-field tearing.** Consumer-visible fields (`vbat`, `charging`, percent, valid/disconnected flags) are committed under `sPowerStatusMux`; only benign debug fields update outside it, and float reads/writes are single-word aligned.
- **Saved-faces / scroll-meta fixed char fields.** `strncpy` + explicit NUL (`web_api.cpp:816-825`), `memcpy` of `timelineId` into equally-sized buffers, and `commandStartScroll`'s pre-lock length check (`:1136`) all respect `MAX_SCROLL_*_CHARS`.
- **`data/app.js` parse & `data/index.html`.** Clean parse; the apparent corrupted regex/attributes are display artifacts of UTF-8 Chinese + CRLF, not actual breakage.

---

## Recommended checks to add to CI
Second-pass note: `pio run` and `pio run -t buildfs` both pass locally as of 2026-06-18; keep them in CI as regression gates rather than treating them as unverified.
1. `pio run` and `pio run -t buildfs` (could not run here — no toolchain).
2. `node --check data/app.js` and `node tools/test_m370_boundary.js` (both pass today).
3. New fixture test: load a `saved_faces.json` with >128 valid faces and assert the loader caps at 128 (guards C1).
4. API-contract test asserting `lastReason` is identical between `/api/status` and `/api/command` (guards L1).
