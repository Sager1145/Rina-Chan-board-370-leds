# Page 6.5 — Device Diagnostics / Debug Console Rewrite Plan

**Status:** Plan only. No code changed. Audit before implementation.
**Target files:** `data/index.html` (`#page-debug`, currently ~lines 531–642), `data/app.js` (~10,214 lines), `data/styles.css` (~3,250 lines).
**Constraint:** Implementable with **zero firmware changes**. All data already comes from existing endpoints (`/api/status`, `/api/power`, `/api/saved_faces`, `/api/command`, `/api/frame`) and existing JS objects (`state`, `firmware`, `currentFrame`, `EXPRESSION_PARTS`, resource constants).

---

## Audit Corrections (v2 — verified against code)

This section is the **authoritative source of truth**. Where any detail below conflicts with §1–§15, this section wins. Every rule here was re-verified against `data/app.js` at the cited lines.

### Critical implementation rules (must hold)

1. **Separate debug preview buffer — do not reuse `currentFrame`.** `MATRIX_VIEW_CONFIGS` (app.js:3235) points **both** `matrix-basic` and `matrix-debug` at `() => currentFrame`, and `updateDps()` (app.js:~5172) computes from `currentFrame`. Mutating `currentFrame` for a preview would pollute the 6.1 basic preview, DPS state, copied M370, and any later "send current frame" action. Introduce:
   ```js
   let debugPreviewFrame = blankFrame();
   let debugPreviewSource = "none";   // local | firmware | saved face | M370 input | debug pattern
   let debugPreviewReason = "init";
   let debugPreviewUpdatedAt = null;
   ```
   Re-point the debug matrix at the new buffer: change `MATRIX_VIEW_CONFIGS` entry (app.js:3235) and the `initMatrix("matrix-debug", …)` call (app.js:~9814) from `() => currentFrame` to `() => debugPreviewFrame`.
   - **Preview-only** actions update **only** `debugPreviewFrame` + preview metadata, then call `renderMatrices()` to repaint `#matrix-debug` (verified: `renderMatrices()` at app.js:6515 iterates `matrixViews`, reads each `frameProvider()`, dirty-diffs, and skips hidden matrices — since `currentFrame` is untouched, `matrix-basic` will not change). They must **not** call `setCurrentFrame()`, **not** `queueFirmwareFrame()`, **not** `updateDps()` (DPS reflects firmware output, not preview), and **not** touch `currentFrame`. The `() => debugPreviewFrame` closure reads the live `let`, so reassigning `debugPreviewFrame = cloneFrame(frame)` is picked up on next repaint.
   - **Send-to-firmware** actions call the existing `setCurrentFrame(frame, reason, playback)` (which already queues), then mirror the frame into `debugPreviewFrame` and set source = `firmware`.

2. **Do not infer source from label text. Replace `getDebugValueSource(label)` with explicit per-row metadata.** Labels repeat across panels and a label alone cannot distinguish live firmware / config fallback / stale-last-known. Use a row builder:
   ```js
   buildDebugRow({ label, value, source, stale = false, note = "" })
   // source ∈ "Firmware" | "Browser" | "Resource" | "Config" | "Computed" | "Fallback"
   ```
   `renderDebugKvList(targetId, rows)` consumes these objects and renders the value + a source chip + optional stale marker. `getDebugValueSource` is **removed** from §8.

3. **AP source must be tracked, not guessed.** `state.apIp`/`state.apDomain` start as config defaults (app.js:3464 region) and are overwritten by `/api/status` inside `applyFirmwareRuntimeState` (app.js:~4582, the `data.ap?.ip` / `data.ap?.domain` block). Add explicit flags set at those exact assignment sites:
   ```js
   state.apIpSource = "Config";      // → "Firmware" when set from data.ap.ip
   state.apDomainSource = "Config";  // → "Firmware" when set from data.ap.domain
   ```
   Pass `source: state.apIpSource` (and `stale: !firmware.online`) into the Network panel rows.

4. **Render boundary — `renderState()` must not rebuild interactive debug controls.** Both `apiGet` (app.js:4210) and `apiPost` (app.js:4252) call `renderState()` *before* every request, and `syncRuntimeStateFromFirmware` (app.js:5681) calls it after full responses. If `renderState()` rebuilt the M370 textarea, raw-JSON textarea, or confirmation checkbox, every poll/command would wipe user input. Rule:
   - Interactive controls (`#debug-m370`, `#debug-raw-json`, the raw-command checkbox, log filter) are **static HTML built once**, wired in `initializeDebugControls()`, and **never** re-`innerHTML`'d by a render function.
   - `renderState()` may only call **read-out renderers** that rewrite `.kv`/badge/preview-meta containers: `renderDebugDeviceSummary`, `renderDebugFirmwareHealth`, `renderDebugPowerPanel` (readout rows only), `renderDebugNetworkPanel` (value spans only, not the input), `renderDebugResourcePanel`, `renderDebugPreviewPanel` (meta + matrix). Validation lines and result lines are written by their own action handlers, not by `renderState()`.
   - Guard: read-out renderers run only when `document.body.dataset.page === "debug"` to avoid wasted work (verified necessary — `renderState()` has **44 call sites** across the app).
   - **Shared, non-debug UI stays in `renderState()` unconditionally:** the battery/charge header badges (`#badge-battery-dot`/`#badge-battery-label`/`#badge-charging-dot`/`#badge-charging-label`, index.html:96–101, in the shared header — visible on every page) and `updateModeToggleUi()` are NOT page-gated and must continue to update on every `renderState()`. Do **not** move them into the debug-gated readouts.
   - **Hard rule:** after migration `renderState()` may call `renderDebugReadouts()` (page-gated) but must never directly rebuild an individual interactive debug panel's controls.

5. **`applySavedFace()` is a send path — do not use it for preview.** `applySavedFace(i)` (app.js:7037) sets `state.faceIndex`, calls `setCurrentFrame()` (queues a firmware frame), and re-renders saved faces. Add a pure helper and use it for preview:
   ```js
   function getSavedFaceFrame(i) {
     const face = getAllFaces()[i];
     return face ? m370ToFrame(face.m370) : blankFrame();
   }
   ```
   Preview-only → `applyDebugFrame(getSavedFaceFrame(state.faceIndex), "saved face", {send:false})`. Send → `setCurrentFrame(getSavedFaceFrame(state.faceIndex), "debug_send_saved_face", "idle")` (or keep `applySavedFace` for the send button, which is acceptable since it queues intentionally).

6. **DPS / all-on warning uses a shared, parameterized estimator.** `updateDps()` currently hardcodes `onCount(currentFrame)` against `LED_POWER_WARNING_WATTS` (=40, config `powerWarningWatts`) using `LED_ESTIMATED_WATTS_PER_CHANNEL`, `LED_CHANNEL_COUNT`, `LED_FULL_BRIGHTNESS` (app.js:~5172). Refactor the math into:
   ```js
   function estimateFrameWatts(frame, colorHex, brightness) { … same formula … }
   ```
   `updateDps()` calls it with `currentFrame`. The all-on send handler calls it with an all-on frame at current color/brightness:
   ```text
   Before sending all-on: if estimateFrameWatts(allOnFrame, state.color, state.brightness) >= LED_POWER_WARNING_WATTS,
   show a power-warning banner and require an explicit "Send all-on anyway" confirm.
   If firmware is offline, allow preview-only but block send-to-firmware with an offline error.
   ```

7. **DPS banner — resolve the duplicate-ID ambiguity.** The current single `#dps-warning` is toggled by `updateDps()` via `classList.toggle("show", …)`. Use **two distinct banner IDs** and a helper instead of a shared id:
   ```html
   <div class="warning" id="debug-summary-dps-warning">…</div>
   <div class="warning" id="debug-power-dps-warning">…</div>
   ```
   ```js
   function renderDpsWarning() {
     ["debug-summary-dps-warning","debug-power-dps-warning"].forEach(id =>
       $(id)?.classList.toggle("show", state.dpsActive));
   }
   ```
   Update `updateDps()` to call `renderDpsWarning()` instead of touching `#dps-warning`. The old `#dps-warning` element is removed.

8. **Staged migration must not create duplicate live IDs.** Preserved IDs (`#matrix-debug`, `#debug-m370`, `#log`, `#debug-refresh-power`, `#firmware-ping`, `[data-gpio]`) must appear **exactly once** in the DOM at all times — `$()` and `initMatrix` bind the first match. Therefore §12 step 3 is revised: **do not** render old and new structure simultaneously. Instead, replace `#page-debug`'s inner markup in one edit, and during the build keep the masonry functions as no-op stubs (rule 9) so no call site breaks. There is no "both visible" intermediate state.

9. **Masonry retirement — stub, then delete.** `setupDebugMasonryLayout` / `scheduleDebugMasonryLayout` (app.js:~5854) and the sizing code that `closest(".debug-measure-card")` (app.js:6375, 6483) are still referenced. Migration:
   - First make `setupDebugMasonryLayout()` and `scheduleDebugMasonryLayout()` no-op stubs (keeps `switchPage`/`renderState` call sites valid).
   - Give the new preview card (`#debug-preview-panel`) a sizing-compatible class so matrix fitting still works: include `.debug-measure-card` (or `.led-preview-card`) on the card, **or** add `#debug-preview-panel` to the two `querySelectorAll`/`closest` selectors at app.js:6375 and :6483. Do not remove `.debug-measure-card` from those selectors until `#matrix-debug`'s new wrapper carries an equivalent class.
   - Delete masonry functions and `.debug-layout`/`.debug-measure-*` CSS only in step 12, after the grid is confirmed working.

10. **Diagnostics copy — scopes + password exclusion.** `copyDebugDiagnostics(scope)` replaces `#debug-copy-status` (which copied raw `state`). Scopes:
    - `"summary"` — mode, face, brightness, color, playback, AP IP/domain (with source), battery summary.
    - `"firmware"` — `firmware` object + queue/dropped/sent counters + last request/status/error + `firmwareLastSyncAt`.
    - `"full"` — summary + firmware + power + resource metadata + debug-preview metadata.
    **Never include `DEVICE_AP_PASSWORD` in any scope.** Show the "may contain SSID/IP/domain" notice on copy.

### Useful-information improvements (adopted)

- **Diagnostic conclusion rows** in Device Summary (panel 1), above the raw value rows — derived one-line verdicts: Firmware Link (Online/Offline/Error), Output State (Showing face / Scrolling text / Paused / Unknown), Power State (Battery / Charging / Unpowered-lock / Unknown), Frame Pipeline (Local preview only / Firmware frame sent / Queue dropping — from `firmware.droppedFrames`/`droppedCommands`), Network (Firmware IP known / Config fallback — from `state.apIpSource`).
- **Per-panel "Last updated" timestamps.** Set in `applyFirmwareRuntimeState` (on success → `firmwareLastSyncAt` / `state.lastStatusSyncAt`, and AP block → `state.lastNetworkSyncAt`) and in `applyPowerData`/`refreshPowerStatusFromFirmware` (→ `state.lastPowerSyncAt`). Show on panels 1, 2, 3, 4. Without these, stale values look current.

### Offline behavior per action (authoritative table)

| Action | Offline behavior |
|---|---|
| Refresh firmware status | Allowed; shows failure + sets stale |
| Refresh power status | Allowed; shows failure |
| GPIO simulator (B1…B6+B3) | Button stays enabled. Two distinct offline cases (verified app.js:4852/5001): **(a) offline HTML mode** — `sendButtonCommand` returns a synchronous packet with no `.promise` and runs its local fallback; `sendAuxCommand` always POSTs, its `apiPost` rejects, and the `.catch` sets `lastStatus:"offline html mode"`. **(b) ordinary network failure (`firmware.online===false`)** — neither helper short-circuits; the `apiPost` promise rejects and surfaces as `command failed`. The result line must therefore handle: missing promise (offline-html button) → show "offline (local fallback)"; rejected/failed promise → show the error; resolved → success. Do not assume a clean offline short-circuit for aux commands. |
| LED preview-only | Allowed (local buffer only) |
| LED send-to-firmware | Disabled when `firmware.online === false` or `isOfflineHtmlMode()`; show offline error |
| M370 parse-preview | Allowed |
| M370 parse-send | Disabled offline |
| Raw command send | Disabled offline (already errors via `apiPost` offline path) |
| Reset battery min/max | Disabled offline — `resetBatteryVoltageRecord` already alerts and returns on `isOfflineHtmlMode()` (app.js:9817) |
| Clear user faces | Allowed (verified) — `userFaces` is browser state; `persistFaceDocuments` (app.js:7457) is offline-tolerant: it attempts local-file save and a firmware POST but `.catch`es failure, setting `savedFacesSync` to "saved locally; firmware offline" / "save failed/offline; use JSON download/import". The in-memory clear always succeeds; no live firmware write is required. |

### Corrections to specific findings

- **`syncRuntimeSummaryFromFirmware` exists** (app.js:5701; used by poller at :5732). The §7 page-enter call is valid as written — no rename or wrapper needed. (Auditor finding #1 does not apply.)
- **Reset battery min/max are Firmware-backed** (verified app.js:9817 → `reset_battery_min`/`reset_battery_max` aux commands, offline-guarded). Tag them **Firmware** in §3, not Browser.
- **`#firmware-pause` lands in panel 5 (GPIO/Button Simulator)** as a labelled "Pause scroll" command button (it is a real one-click control sending `sendAuxCommand("pause_scroll")`), with the same busy/result feedback as other simulator commands. It is **not** a health-panel control and is **not** demoted to raw-command-only.
- **Raw command examples are hardcoded safe samples** (no dynamic listing claim — firmware exposes no command-list endpoint): `{"cmd":"pause_scroll"}`, `{"cmd":"battery_overlay","singleShot":true}`, `{"cmd":"button","button":"B1"}`.

### Minor wording corrections

- Panel 2 (Firmware Health): controls "do not mutate device output; they refresh/read firmware or clear local error state" (not "mutate browser state only").
- "Refresh runtime summary only" means specifically: call `syncRuntimeSummaryFromFirmware(reason)` and let its read-out renderers update panels 1/2; do not call full `syncRuntimeStateFromFirmware` after lightweight commands.
- "Copy log" and "Copy diagnostic JSON (scopes)" are **new** conveniences, not preserved behavior.
- Log "category filter" is **optional/deferred** — current `logs[]` are plain timestamped strings (app.js:`log()`), so filtering needs either a category prefix convention or is skipped for v1.
- Clear-user-faces uses **typed confirmation** (e.g. type `CLEAR`) via `confirmDangerAction`, not a plain `confirm()`. Test must assert default-face count is unchanged after clearing.

---

## Grounding: what exists today (verified from source)

**HTML** — `#page-debug` is a `.debug-layout` masonry of 6 `.card`s:
- "主控制 / 状态信息" → `#state-kv` + `#dps-warning`
- "GPIO / 按钮辅助指令" + "LED / 协议测试" (same card) → `[data-gpio]` buttons, `#debug-all-off/-all-on/-checker/-border/-current-face`, `#debug-m370`, `#debug-apply-m370`, `#debug-copy-status`, `#debug-reset-storage`
- "状态 / ADC / 网络" → `#debug-kv`, `#debug-refresh-power`, `#debug-reset-battery-min/-max`, `#battery-v`, `#charge-v`, `#update-adc`, `#matrix-debug`
- "通信日志" → `#serial-input`, `#serial-send`, `#log-clear`, `#log-download`, `#log`
- "固件接口" → `#firmware-kv`, `#firmware-ping`, `#firmware-pause`
- "资源 / 系统" → `#resource-kv`

**JS** — one `renderState()` (app.js ~6586–6712) fills `#state-kv`, `#debug-kv`, battery/charge badges, `#resource-kv`, `#firmware-kv` in a single block, then calls `scheduleDebugMasonryLayout()`. Controls wired in `initializeDebugControls()` (~9845) and a `[data-gpio]` loop. `switchPage("debug")` (~5955) already runs `setupDebugMasonryLayout(true)` and `refreshPowerStatusFromFirmware("debug_page_enter", true)`.

**Reusable primitives already present:** `kvRows()`, `escapeHtml()`, `$()`, `setClickHandlers()`, `m370ToFrame()`, `frameToM370()`, `setCurrentFrame()`, `makePatternFrame()`, `blankFrame()`, `onCount()`, `sendButtonCommand()`, `sendAuxCommand()`, `apiPost()`/`apiGet()`, `applyFirmwareRuntimeState()`, `refreshPowerStatusFromFirmware()`, `syncRuntimeStateFromFirmware()`, `log()`/`renderLog()`, `formatVolts()`/`formatMilliVolts()`/`formatBatteryPercent()`/`batteryPowerText()`/`formatChargingState()`, `initMatrix()`.

**Reusable CSS already present:** `.card`, `.card h3/h4`, `.kv`/`.kv .k`, `.row`, `.stack`, `.control-panel`, `.badge`, `.status-dot{.dim|.warn|.danger}`, `.warning`/`.warning.show`, `button.danger`, `button:disabled`, `.hint`, `.mono`, `.matrix`/`.matrix-wrap`, `.field`.

The rewrite **reuses all of the above** and adds a small, contained set of helpers and CSS. No new visual language.

---

## 1. Executive Summary

**Why current 6.5 is hard to use.** A single `renderState()` builds five unrelated key-value blocks at once, so live device state, browser-side queue counters, raw ADC millivolts, AP credentials, hardcoded resource metadata, and protocol constants all render as visually identical `.kv` rows. Destructive "清空用户表情" sits in the same button row as harmless test patterns. The AP password is printed in plaintext by default. There is no labelling of whether a value is live firmware data, a browser-local guess, or a hardcoded constant — so a value like `当前 AP IP` looks authoritative even when it's a config fallback. Buttons give no per-action success/error feedback and can be spammed. The "LED/协议测试" group does not distinguish a local preview from a frame actually pushed to firmware. Diagnosing a single real problem (e.g. "is the board charging-detecting wrong?") means scanning the entire dump.

**What the new page accomplishes.** A purpose-ordered set of panels, most-useful-first: device summary → firmware link health → power/battery/ADC → network → button simulator → LED/M370 lab → debug preview → resources → log → raw command → danger zone. Every displayed value carries a source tag (Firmware / Browser / Resource / Config / Computed / Fallback). Read-only status is separated from state-mutating controls, which are separated again from destructive actions. M370 is validated before any send; LED tests label preview-only vs send-to-firmware; "all on" warns about power. Each command shows pending/success/error feedback and disables its button while in flight. The page stays usable and clearly "stale" when firmware is offline, and never polls full LED frames.

**What stays.** Every current data point and control is preserved (see §3 mapping) — nothing useful is deleted. Mode/face/brightness/color/playback/AP/battery summary, the GPIO simulator set, LED test patterns, M370 textarea, copy-status, firmware health counters, power/ADC values, AP info, resource metadata, communication log, raw command sender, and clear-user-faces all remain.

**What moves / becomes advanced.** Raw ADC millivolts and protection thresholds move under an "Advanced ADC details" collapsible. Resource/matrix/protocol metadata moves near the bottom (rarely needed for live diagnosis). The raw `/api/command` JSON sender moves out of the main log card into a near-bottom "Advanced Raw Command" panel behind a confirmation checkbox. The ADC simulation inputs (`#battery-v`/`#charge-v`/`#update-adc`) move into the Advanced ADC block and are clearly labelled as a browser-local simulation, not live data.

**What becomes safer.** Clear-user-faces moves to an isolated, danger-styled "Danger Zone" with typed/explicit confirmation. AP password masked by default with a show/hide toggle. Raw command requires valid JSON containing a string `cmd` plus an "I understand" checkbox. "All on" shows a power warning. All command buttons disable while busy. Copy-diagnostics/logs warn that output may contain network info (SSID/IP/domain).

---

## 2. New Panel Layout

Panel order (top → bottom). All panels are `.card` blocks inside `#page-debug`. The existing JS masonry (`setupDebugMasonryLayout`) is **replaced by a deterministic single-column-on-mobile / two-column-on-desktop CSS grid** (see §10) so panel order is predictable and "most useful first" is honoured top-to-bottom in source order.

| # | Panel | Container ID | Auto-refresh | Mutates state? |
|---|-------|--------------|--------------|----------------|
| 1 | Device Summary | `debug-device-summary` | On enter + low-rate timer (summary only) | Read-only |
| 2 | Firmware Link / API Health | `debug-firmware-health` | On enter + low-rate timer | Controls mutate (refresh/clear-error) |
| 3 | Power / Battery / ADC | `debug-power-panel` | On enter + low-rate power timer | Refresh read-only; ADC sim is browser-local |
| 4 | Network / Access Point | `debug-network-panel` | On enter | Refresh read-only; reveal toggle browser-local |
| 5 | GPIO / Button Simulator | `debug-button-simulator` | No | Sends firmware commands |
| 6 | LED Test / M370 Protocol Lab | `debug-protocol-lab` | No | Preview-only OR sends frames |
| 7 | Debug LED Preview | `debug-preview-panel` | Event-driven only | Read-only render |
| 8 | Resource / Matrix / Face Library | `debug-resource-panel` | On enter (from loaded resources) | Read-only |
| 9 | Communication Log | `debug-log-panel` | Append-on-event | Browser-local only |
| 10 | Advanced Raw Command | `debug-raw-command-panel` | Never | Sends raw `/api/command` |
| 11 | Danger Zone | `debug-danger-zone` | Never | Destructive |

### Panel detail

**1. Device Summary — `debug-device-summary`**
*Purpose:* the at-a-glance live state.
*Fields:* firmware online/offline (badge); mode Manual/Auto/Scroll/Unknown (badge); current face index `n / total`; face name; face type (`faceTypeLabel`); playback state (badge); brightness `b/255`; current color (swatch + hex); text scroll active/inactive (badge); actual FPS (`state.actualFps`); AP IP; battery percent / powered state (badge). DPS warning shown as a banner here if active.
*Controls:* none (read-only). Operational controls live on 6.1.
*Data source:* `state` (firmware-synced via `applyFirmwareRuntimeState`) + `getAllFaces()`.
*Refresh:* on page enter (`syncRuntimeSummaryFromFirmware`) + low-rate timer while page active.
*Read-only.* *Useful because:* answers "is it on, what mode, what face, what frame brightness/colour" in one glance with no noise.

**2. Firmware Link / API Health — `debug-firmware-health`**
*Purpose:* is the browser talking to firmware correctly.
*Fields:* firmware online (badge); last request (`firmware.lastRequest`); last HTTP/status result (`firmware.lastStatus`); last error (`firmware.lastError`); last successful sync time (new timestamp, see §8); sent frames (`firmware.sentFrames`); sent commands (`firmware.sentCommands`); frame queue depth (`firmware.frameQueue/WEBUI_M370_QUEUE_MAX`); button/command queue depth (`firmware.buttonQueue/WEBUI_BUTTON_COMMAND_QUEUE_MAX`); dropped frames (`firmware.droppedFrames`); dropped commands (`firmware.droppedCommands`); saved-faces sync status (`firmware.savedFacesSync`).
*Controls:* Refresh firmware status (`syncRuntimeStateFromFirmware`); Refresh power status (`refreshPowerStatusFromFirmware`); Clear local API error (resets `firmware.lastError` + `lastApiErrorLogAt`); Copy firmware/API diagnostic JSON (`copyDebugDiagnostics("firmware")`).
*Data source:* `firmware` object. **Queue/sent/dropped counters are explicitly labelled "Browser queue diagnostics"** — they are WebUI-side pump counters, not firmware counters. `online`/`lastStatus` reflect actual HTTP results.
*Refresh:* on enter + low-rate timer. No GPIO/LED actions here.
*Controls mutate browser state only (and trigger reads).* *Useful because:* shows dropped frames/commands and queue backpressure — the clearest signal the browser↔firmware link is degraded.

**3. Power / Battery / ADC — `debug-power-panel`**
*Purpose:* diagnose power/battery/charging/undervoltage/DPS.
*Subgroups:*
- *Battery State (friendly, shown first):* powered/not powered (badge); battery display text (`batteryPowerText()`); battery percent; Vbat filtered (`state.batteryV`); Vbat instant (`state.batteryLastInstantVbat`); Vbat min (`state.batteryMinV`); Vbat max (`state.batteryMaxV`).
- *Advanced ADC details (collapsible `<details>`, collapsed by default):* battery ADC raw/current (`state.batteryAdcMv`); previous battery ADC raw (`state.batteryPrevAdcMv`); charge ADC raw (`state.chargeAdcMv`); Vcharge (`state.chargeV`); charging state (`formatChargingState`); low-voltage unpowered lock (`state.batteryLowVoltageUnpowered`); unpowered low threshold (`state.batteryUnpoweredLowThreshold`); disconnect drop + threshold (`state.batteryDisconnectDropMv` / `...ThresholdMv`); disconnect low ADC threshold (`state.batteryDisconnectLowThresholdMv`); reconnect ADC threshold (`state.batteryReconnectThresholdMv`); DPS active (`state.dpsActive`); estimated power-warning state. Also hosts the **ADC simulation** inputs `#battery-v`/`#charge-v`/`#update-adc`, labelled "Browser-local ADC simulation (does not read hardware)".
*Controls:* Refresh power status (`refreshPowerStatusFromFirmware("debug_refresh_power", true)`); Reset battery min/max (`resetBatteryVoltageRecord`); ADC simulation update.
*Data source:* `/api/power` + `state.battery*`/`state.charge*`. *Refresh:* on enter + low-rate power timer.
*Rules:* friendly values first; raw/thresholds collapsed; **DPS warning shown as a banner** when `state.dpsActive`; unpowered state shown clearly via badge.
*Refresh read-only; ADC sim is explicitly browser-local.* *Useful because:* separates "what's the battery doing" (top) from calibration internals (collapsed), so wrong charge detection is visible without wading through millivolts.

**4. Network / Access Point — `debug-network-panel`**
*Fields:* AP SSID (`DEVICE_AP_SSID`); AP password (`DEVICE_AP_PASSWORD`) **masked by default** (`••••••••`); show/hide toggle; AP domain (`state.apDomain`); AP IP (`state.apIp`).
*Controls:* Network info refresh (`syncRuntimeStateFromFirmware("debug_network_refresh")`); show/hide password.
*Data source:* `state.apIp`/`state.apDomain` are **firmware-backed when `applyFirmwareRuntimeState` populated them from `/api/status` `data.ap`**, otherwise **Config fallback** (`DEFAULT_AP_IP`/`DEVICE_AP_DOMAIN`). SSID/password are **Config** constants. The source tag flips to "Firmware" only after a successful status sync set `ap.ip`/`ap.domain`.
*Refresh:* on enter only.
*Rules:* password masked by default; small warning that copied logs/diagnostics may include network info; firmware-vs-config-fallback labelled per-row.
*Refresh read-only; reveal is browser-local.* *Useful because:* confirms the AP the phone should join, and whether IP/domain are live or guessed.

**5. GPIO / Button Simulator — `debug-button-simulator`**
*Purpose:* simulate physical button input.
*Single Button Actions:* B1 next face, B2 previous face, B3 Manual/Auto toggle, B4 brightness down, B5 brightness up, B6 short battery overlay.
*Combo / Special Actions:* B3+B1 interval down, B3+B2 interval up, B6 long battery details, B6+B3 network information.
*(Existing `data-gpio` codes: `B1 B2 B3 B4 B5 B6S B6L B3B1 B3B2 B6B3`.)*
*Controls:* the buttons above, in two labelled subgroups, under a heading "Simulated hardware button input".
*Data source:* sends via `sendButtonCommand` (B1/B2/B3/B4/B5/B3B1/B3B2) or `sendAuxCommand("battery_overlay", …)` (B6S/B6L) / `syncRuntimeStateFromFirmware` (B6B3).
*Refresh:* none on timer; after each command, refresh runtime summary only.
*Rules:* visually distinct from normal user controls (muted/secondary styling + section label); per-action result line shows command sent / success|failure / last response or error / whether runtime state was refreshed; button disabled while its command is in flight (`setDebugActionBusy`); on success refresh only runtime summary fields, not heavy data.
*Mutates device state via firmware.* *Useful because:* lets you exercise real button logic without the physical board and see the exact firmware response.

**6. LED Test / M370 Protocol Lab — `debug-protocol-lab`**
*Purpose:* controlled LED/protocol tests.
*Safe LED Test Patterns:*
- Preview only: all off / checker / border / current saved face — apply to the debug preview via `applyDebugFrame(frame, source, {send:false})`, **no firmware write**.
- Send to firmware: all off / all on / checker / border / current saved face — `applyDebugFrame(frame, source, {send:true})` → `setCurrentFrame`/`queueFirmwareFrame`.
*M370 Input:* `#debug-m370` textarea; validation result line (valid/invalid, normalized length, expected length = 93, whether `M370:` prefix detected); buttons Parse to preview only / Parse and send to firmware / Clear input / Copy debug preview as M370 (`frameToM370(debugPreviewFrame)`).
*Controls:* the above. *Data source:* `debugPreviewFrame` (preview/parse) + `m370ToFrame`/`frameToM370`; send path routes through `setCurrentFrame` → existing frame queue.
*Refresh:* updates preview source label; refresh status only if needed.
*Rules:* preview-only vs send-to-firmware visually separated into two sub-blocks; **"All on" shows a power warning banner** (full matrix at current brightness/colour → DPS risk) before sending; any full-frame send shows clear feedback; M370 validated before send via `validateM370Input` — invalid input never sends and shows the exact error; accepted format `93` hex chars or `M370:<93 hex>`; preview source label set to one of `M370 input | test pattern | saved face | firmware status | local current frame`.
*Preview-only is read-only; send mutates output.* *Useful because:* lets you isolate "is it the data or the hardware" — preview the frame the browser would send, then optionally push it.

**7. Debug LED Preview — `debug-preview-panel`**
*Purpose:* show the current debug frame clearly, distinct from the 6.2 editor preview.
*Fields:* LED matrix preview (`#matrix-debug` re-pointed at `debugPreviewFrame`, same `initMatrix` scale rules as other previews); source label (`debugPreviewSource`: `local frame | firmware last frame | saved face | M370 input | debug pattern`); last update reason (`debugPreviewReason`); last update timestamp (`debugPreviewUpdatedAt`); debug preview M370 length/status (`frameToM370(debugPreviewFrame)`); optional "Copy debug preview M370" button.
*Controls:* copy debug preview M370 (optional). *Data source:* `debugPreviewFrame` (Computed) + `applyDebugFrame` metadata.
*Refresh:* event-driven only — when a local debug action changes the frame, or when `/api/status` supplies a last frame. **No full-frame polling.**
*Read-only render.* *Useful because:* shows exactly what the debug pipeline is rendering, labelled so it is never confused with the editor.

**8. Resource / Matrix / Face Library — `debug-resource-panel`**
*Purpose:* static / semi-static configuration metadata. Placed low because rarely needed live.
*Matrix / Protocol:* LED count (`TOTAL_LEDS`); matrix cols×rows (`COLS`×`ROWS`); irregular-370 layout note; M370 length (`93 hex + M370:`); physical wiring mode (`SERPENTINE_WIRING`); compose mode.
*Resource JSON:* JSON format (`EXPRESSION_PARTS.format`); version; stored unique parts; callable ids; stored group counts eye_left/eye_right/mouth; callable group count cheek.
*Face Library:* default face count (`defaultFaces.length`); user saved face count (`userFaces.length`); saved face source path (`firmware.savedFacesPath`); saved face sync status (`firmware.savedFacesSync`); parts symmetry flag (`partsSymmetry`).
*Controls:* none. *Data source:* mix of **Config/hardcoded** (matrix/protocol constants, layout notes) and **Resource-derived** (`EXPRESSION_PARTS`, face counts). Each row tagged accordingly.
*Refresh:* on enter, from already-loaded resources (no fetch).
*Read-only.* *Useful because:* confirms the board's geometry/protocol assumptions and face inventory when a face renders wrong.

**9. Communication Log — `debug-log-panel`**
*Fields:* local log display (`#log`); optional category filter (API / frame / command / saved faces / power / error).
*Controls:* Clear log (`#log-clear`), Download log (`#log-download`), Copy log (new).
*Data source:* browser-local `logs[]`. *Refresh:* appends on event; never auto-clears.
*Rules:* labelled browser-side; note that logs may contain IP/domain/SSID; **the raw `/api/command` sender is removed from this card** (moves to panel 10); scrollable, readable.
*Browser-local only.* *Useful because:* the timeline of WebUI activity for bug reports.

**10. Advanced Raw Command — `debug-raw-command-panel`**
*Purpose:* manual `/api/command` testing. Collapsed by default / near bottom.
*Fields:* JSON textarea (was `#serial-input`); example format (`{"cmd":"pause_scroll"}`); last raw command result line.
*Controls:* Validate JSON; Send raw command (disabled until "I understand this hits /api/command directly" checkbox is ticked); the existing parse/POST logic from `#serial-send`.
*Data source:* posts to `API_ENDPOINTS.command`. *Refresh:* never auto.
*Rules:* must be valid JSON; object must contain string `cmd` (existing guard); invalid never sends and shows the parse error; warning text + confirmation checkbox; styled as advanced, not a normal control.
*Mutates device state via raw firmware command.* *Useful because:* power-user escape hatch, safely gated.

**11. Danger Zone — `debug-danger-zone`**
*Purpose:* isolate destructive actions.
*Fields/Controls:* Clear user faces (was `#debug-reset-storage`); placeholder for future reset/destructive actions.
*Data source:* mutates `userFaces` + `persistFaceDocuments`. *Refresh:* never auto.
*Rules:* visually separated (danger border/heading); danger button styling (`button.danger`); confirmation via `confirmDangerAction` stating exactly what changes ("This permanently clears all user-saved faces. Default faces are not affected."); Cancel does nothing; on success refresh saved-face/resource metadata + show result.
*Destructive.* *Useful because:* keeps the one irreversible action far from everyday test buttons.

---

## 3. Field-by-Field Mapping

Type legend: **FW** firmware-backed · **BR** browser-local · **CMP** computed · **RES** resource-derived · **CFG** config/hardcoded · **DES** destructive.
Decision legend: keep · redesign · move · advanced · danger · remove.

### Main State (current `#state-kv`)
| Old label/control | Old section | New panel | Source / function | Type | Decision | Notes |
|---|---|---|---|---|---|---|
| 当前模式 | Main State | 1 Device Summary | `state.mode` via `applyFirmwareRuntimeState` | FW | redesign | Render as badge; map auto/manual/scroll/unknown |
| 当前表情序号 | Main State | 1 | `state.faceIndex`+`getAllFaces()` | FW | keep | `n / total` |
| 当前表情名称 | Main State | 1 | `getAllFaces()[idx].name` | FW/RES | keep | |
| 当前表情属性 | Main State | 1 | `faceTypeLabel(type)` | RES | keep | |
| 当前亮度 | Main State | 1 | `state.brightness` | FW | keep | `b/255` |
| 当前颜色 | Main State | 1 | `state.color` | FW | redesign | Add colour swatch |
| 当前播放状态 | Main State | 1 | `state.playback` | FW | redesign | Badge |
| 当前 AP Domain | Main State | 4 Network | `state.apDomain` | FW/CFG | move | Source tag flips on status sync |
| 当前 AP IP | Main State | 1 + 4 | `state.apIp` | FW/CFG | keep/move | Summary shows IP; full detail in panel 4 |
| 刷新策略 | Main State | 7 Preview (meta) | `state.refreshPolicy` | BR | move | Demoted from summary |
| 最近刷新原因 | Main State | 7 Preview | `state.lastRefreshReason` | BR/CMP | move | "Last update reason" |
| 刷新计数 | Main State | 2 FW Health (advanced) | `state.refreshCount` | BR | advanced | Browser counter |
| DPS warning (`#dps-warning`) | Main State | 1 + 3 banner | `state.dpsActive`/`updateDps`→`renderDpsWarning()` | CMP | redesign | Old id removed; split into `#debug-summary-dps-warning` + `#debug-power-dps-warning` (v2 rule 7) |

### GPIO / Buttons
| Old control | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| B1 下一个 | 5 Simulator (Single) | `sendButtonCommand("B1")` | FW | keep | + result feedback, busy-disable |
| B2 上一个 | 5 (Single) | `sendButtonCommand("B2")` | FW | keep | |
| B3 A/M | 5 (Single) | `sendButtonCommand("B3")` | FW | keep | |
| B4 亮度- | 5 (Single) | `sendButtonCommand("B4")` | FW | keep | |
| B5 亮度+ | 5 (Single) | `sendButtonCommand("B5")` | FW | keep | |
| B6 短按电量 | 5 (Single) | `sendAuxCommand("battery_overlay",{singleShot:true})` | FW | keep | |
| B3+B1 间隔- | 5 (Combo) | `sendButtonCommand("B3B1")` | FW | keep | |
| B3+B2 间隔+ | 5 (Combo) | `sendButtonCommand("B3B2")` | FW | keep | |
| B6 长按详情 | 5 (Combo) | `sendAuxCommand("battery_overlay",{singleShot:false})` | FW | keep | |
| B6+B3 网络信息 | 5 (Combo) | `syncRuntimeStateFromFirmware` | FW | keep | |

### LED / Protocol
| Old control | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| 全黑 | 6 Lab (preview + send) | `blankFrame()` | CMP | redesign | Split preview-only vs send |
| 全亮 | 6 (send, warn) | `blankFrame().map(()=>true)` | CMP | redesign | Power warning before send |
| 棋盘 | 6 (preview + send) | `makePatternFrame("checker")` | CMP | redesign | |
| 边框 | 6 (preview + send) | `makePatternFrame("border")` | CMP | redesign | |
| 当前保存表情 | 6 (preview + send) | preview: `getSavedFaceFrame(state.faceIndex)` (pure, v2 rule 5); send: `setCurrentFrame(getSavedFaceFrame(...))` or `applySavedFace` | RES/CMP | redesign | **Do NOT use `applySavedFace` for preview — it queues a frame (app.js:7041)** |
| M370 textarea `#debug-m370` | 6 (M370 Input) | `m370ToFrame` | CMP | keep | + validation line |
| 解析并应用 M370 | 6 → 2 buttons | `validateM370Input`→`applyDebugFrame` | CMP | redesign | Split parse-preview vs parse-send |
| 复制状态 JSON `#debug-copy-status` | 2 FW Health | `copyDebugDiagnostics` | BR | move | Becomes "Copy diagnostic JSON" |
| 清空用户表情 `#debug-reset-storage` | 11 Danger Zone | `confirmDangerAction`→reset | DES | danger | Isolated + explicit confirm |

### Debug Status / ADC / Network (current `#debug-kv`)
| Old label | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| LED 数量 | 8 Resource | `TOTAL_LEDS` | CFG | move | |
| 矩阵 | 8 | `COLS`×`ROWS` | CFG | move | |
| M370 长度 | 8 | const | CFG | move | |
| 亮度 raw | 1 Summary | `state.brightness` | FW | keep | Merged into brightness row |
| DPS 状态 | 3 Power (advanced) | `state.dpsActive` | CMP | keep | + banner |
| 播放状态 | 1 Summary | `state.playback` | FW | keep | Dedup with main state |
| 文字滚动 | 1 Summary | `state.textScrollActive` | FW | keep | Badge |
| 实际 FPS | 1 Summary | `state.actualFps` | FW/CMP | keep | |
| 电池状态 | 1 + 3 | `batteryPowerText()` | FW | keep | Badge in summary |
| 低压未上电锁定 | 3 (advanced) | `state.batteryLowVoltageUnpowered` | FW | advanced | |
| Vbat | 3 Battery State | `state.batteryV`/percent | FW | keep | Friendly group |
| 电池瞬时电压 | 3 Battery State | `state.batteryLastInstantVbat` | FW | keep | |
| 未上电电压阈值 | 3 (advanced) | `state.batteryUnpoweredLowThreshold` | FW/CFG | advanced | |
| 电池最低电压记录 | 3 Battery State | `state.batteryMinV` | FW | keep | |
| 电池最高电压记录 | 3 Battery State | `state.batteryMaxV` | FW | keep | |
| 电池 ADC raw | 3 (advanced) | `state.batteryAdcMv` | FW | advanced | |
| 上次电池 ADC raw | 3 (advanced) | `state.batteryPrevAdcMv` | FW | advanced | |
| 断电快速压降 | 3 (advanced) | `state.batteryDisconnectDropMv`/threshold | FW | advanced | |
| 断电低 ADC 阈值 | 3 (advanced) | `state.batteryDisconnectLowThresholdMv` | FW | advanced | |
| 恢复 ADC 阈值 | 3 (advanced) | `state.batteryReconnectThresholdMv` | FW | advanced | |
| Vcharge | 3 (advanced) | `state.chargeV`/`formatChargingState` | FW | advanced | |
| 充电 ADC raw | 3 (advanced) | `state.chargeAdcMv` | FW | advanced | |
| AP SSID | 4 Network | `DEVICE_AP_SSID` | CFG | move | |
| AP 密码 | 4 Network | `DEVICE_AP_PASSWORD` | CFG | redesign | Masked + toggle |
| AP Domain | 4 Network | `state.apDomain` | FW/CFG | move | dedup |
| AP IP | 4 Network | `state.apIp` | FW/CFG | move | dedup |
| `#battery-v`/`#charge-v`/`#update-adc` | 3 (advanced) | local sim | BR | move | Labelled "browser-local simulation" |
| `#debug-refresh-power` | 3 controls | `refreshPowerStatusFromFirmware` | FW | keep | |
| `#debug-reset-battery-min/-max` | 3 controls | `resetBatteryVoltageRecord` → `reset_battery_min`/`max` aux cmd | FW | keep | Verified firmware-backed + offline-guarded (app.js:9817) |
| `#matrix-debug` | 7 Preview | `initMatrix(...debugPreviewFrame)` | CMP | redesign | Re-parented to preview panel; frame provider re-pointed `currentFrame`→`debugPreviewFrame` (v2 rule 1) |

### Firmware Interface (current `#firmware-kv`)
| Old label | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| online | 2 FW Health + 1 Summary | `firmware.online` | FW | keep | Badge |
| lastRequest | 2 | `firmware.lastRequest` | BR/FW | keep | |
| lastStatus | 2 | `firmware.lastStatus` | FW | keep | |
| lastError | 2 | `firmware.lastError` | FW | keep | + Clear-error control |
| sentFrames | 2 | `firmware.sentFrames` | BR | keep | Label "Browser queue diag" |
| sentCommands | 2 | `firmware.sentCommands` | BR | keep | Browser counter |
| frameQueue | 2 | `firmware.frameQueue/MAX` | BR | keep | Browser counter |
| buttonQueue | 2 | `firmware.buttonQueue/MAX` | BR | keep | Browser counter |
| droppedFrames | 2 | `firmware.droppedFrames` | BR | keep | Browser counter |
| droppedCommands | 2 | `firmware.droppedCommands` | BR | keep | Browser counter |
| savedFacesSync | 2 + 8 | `firmware.savedFacesSync` | FW/BR | keep | |
| 读取固件状态 `#firmware-ping` | 2 control | `syncRuntimeStateFromFirmware` | FW | keep | "Refresh firmware status" |
| 发送暂停指令 `#firmware-pause` | 5 Simulator | `sendAuxCommand("pause_scroll")` | FW | move | Lands in panel 5 as "Pause scroll" with busy/result feedback (v2). Not a health control |

### Communication / Raw command
| Old control | New panel | Source | Type | Decision | Notes |
|---|---|---|---|---|---|
| `#serial-input` | 10 Raw Command | textarea | BR | move | Renamed `debug-raw-json` |
| `#serial-send` | 10 | `apiPost(command)` w/ `cmd` guard | FW | move | Behind checkbox |
| `#log` | 9 Log | `logs[]` | BR | keep | |
| `#log-clear` | 9 | `logs=[]` | BR | keep | |
| `#log-download` | 9 | `downloadJsonFile` | BR | keep | + Copy log |

### Resource / System (current `#resource-kv`)
All move to panel 8, tagged Config or Resource:
JSON format, version, stored_unique_parts, callable_ids, eye_left/eye_right/mouth, cheek, default_faces, user_saved_faces (RES, keep) · interface_mode, face_library_json, physical_wiring, parts_compose, parts_eye_symmetry, preview_scale, basic_layout (CFG, keep — tag hardcoded). `preview_scale`/`basic_layout`/`interface_mode` are descriptive constants → keep but tag clearly as config notes.

---

## 4. Useful Information Rules

The page must, top-first, let the operator answer:
1. Is firmware online? — panel 1 + 2 online badge.
2. What mode is the board actually in? — panel 1 mode badge (firmware-synced).
3. What face/frame is shown? — panel 1 face rows + panel 7 preview with source label.
4. Is battery/charging detection wrong? — panel 3 friendly group, charging badge, advanced ADC for calibration.
5. Is AP/network info correct? — panel 4, with firmware-vs-fallback tag.
6. Can I simulate buttons safely? — panel 5 with per-action feedback + busy-disable.
7. Can I test LED output safely? — panel 6 preview-vs-send split + all-on warning.
8. Can I validate/send M370 safely? — panel 6 validation gate.
9. Are browser queues dropping data? — panel 2 dropped/queue counters.
10. Can I export logs/diagnostics for bug reports? — panel 2 copy-diagnostics, panel 9 copy/download log.

De-prioritised (moved down / collapsed / removed from summary): unlabelled internal counters; hardcoded values mixed with live values; raw ADC before human-readable power; destructive actions near normal buttons; AP password shown by default; the raw command sender in the main workflow.

**Source-of-truth labelling is mandatory:** every row renders a small source chip. Live firmware reads (FW) must never be visually identical to browser-local (BR), config (CFG), resource (RES) or computed (CMP) values.

---

## 5. UI/UX Rules

Reuse the existing system; add nothing that conflicts.
- **Card layout:** each panel is a `.card`; multi-control panels add `.stack`. New `.debug-grid` wrapper replaces `.debug-layout` masonry (deterministic order).
- **Section headings:** existing `.card h3` for panel titles; `.card h4` for subgroups (Battery State, Advanced ADC details, Single/Combo, Safe Patterns/M370 Input).
- **Key-value rows:** reuse `.kv`/`.kv .k` two-column grid via `kvRows()`/`renderDebugKvList`. Each row optionally carries a trailing source chip.
- **Badges:** reuse `.badge` + `.status-dot{.dim|.warn|.danger}` for online/offline, mode, playback, scroll, battery powered/unpowered, DPS. New helper `renderDebugBadge(value, type)` returns badge markup using these classes only.
- **Button groups:** reuse `.row` flex-wrap groups. Simulator buttons get a `.debug-sim` secondary style (muted) so they don't read as primary user controls.
- **Danger buttons:** reuse `button.danger`; Danger Zone card gets a `.debug-danger` red-tinted border.
- **Warning banners:** reuse `.warning`/`.warning.show` (already amber). New `.warning.danger` modifier (red) for all-on power warning if a stronger signal is wanted; otherwise reuse amber.
- **Collapsible advanced:** use native `<details><summary>` styled minimally (existing `summary` rule at styles.css ~347) for Advanced ADC details and Advanced Raw Command.
- **Textarea:** reuse existing `textarea` styling for `#debug-m370` and `#debug-raw-json`; keep `autoResizeTextarea` wiring.
- **Log display:** reuse `.log`/`.debug-log-card .log` scroll styling.
- **Mobile layout:** single column under existing breakpoint (~980px). Panels stack in source order so "most useful first" holds. Button groups wrap.
- **Spacing:** inherit `.card` padding (15px) + `.stack` gaps; no custom margins beyond existing.
- **Disabled/busy:** reuse `button:disabled` (opacity .42, grayscale). `setDebugActionBusy` toggles `disabled` + a `.busy` class.
- **Success/error feedback:** per-action result line uses a new `.debug-result{.ok|.err|.pending}` small text style (green/red/muted) — minimal, three colours only.

No separate design language. New CSS limited to grid, source chip, sim-button tint, danger card border, result line, and reuse of everything else.

---

## 6. Data Source Rules

Source of truth per value:
- `/api/status` (via `applyFirmwareRuntimeState`) → mode, faceIndex/name/type, brightness, color, playback, textScrollActive, actualFps, AP ip/domain, last frame. **FW**
- `/api/power` (via `refreshPowerStatusFromFirmware`/`applyPowerData`) → all `state.battery*`/`state.charge*`. **FW**
- `/api/saved_faces` / `/resources/saved_faces.json` → face library counts, `firmware.savedFacesSync`. **FW/RES**
- local `state` written only by browser actions (refreshPolicy, refreshCount, lastRefreshReason). **BR/CMP**
- local `firmware` pump counters (sent/dropped/queue). **BR**
- `currentFrame` (app-wide firmware output frame) and `debugPreviewFrame` (debug-only preview buffer) + `frameToM370`/`onCount`. Panel 7 and the M370 lab read/copy `debugPreviewFrame`; only send paths touch `currentFrame`. **CMP**
- `EXPRESSION_PARTS`, `TOTAL_LEDS`, `COLS`, `ROWS`, `SERPENTINE_WIRING`. **RES/CFG**
- `DEVICE_AP_SSID`/`DEVICE_AP_PASSWORD`/`DEFAULT_AP_IP`/`DEVICE_AP_DOMAIN`. **CFG**

Every displayed value is categorised **Firmware / Browser / Resource / Config / Computed / Unknown-Fallback** via the explicit `source` field on each `buildDebugRow({label,value,source,stale,note})` object (v2 rule 2 — never inferred from label text), rendered as the row's source chip. AP rows pass `source: state.apIpSource`/`state.apDomainSource`.

**When firmware is offline** (`firmware.online === false` or `isOfflineHtmlMode()`):
- Panels 1–4 show a "stale / last known" badge on FW rows; AP IP/domain show their Config-fallback tag.
- Do not relabel local values as live firmware. The mode/face/power rows keep their last synced value but the panel header shows an "Offline — values may be stale" notice.
- Local diagnostics (preview, M370 validation, log, queue counters, resource panel) remain fully usable.

---

## 7. Refresh Strategy

**On entering page 6.5** (extend existing `switchPage("debug")` block):
- `syncRuntimeSummaryFromFirmware("debug_page_enter")` (lightweight runtime status, already exists).
- `refreshPowerStatusFromFirmware("debug_page_enter", true)` (already called).
- Update firmware/API health from `firmware` object (no fetch).
- Update resource/face counts from already-loaded resources (no fetch).
- Do **not** force a heavy full-frame sync.

**After a GPIO/button command:** send → set button busy (`setDebugActionBusy`) → on success refresh runtime summary + show result via `showDebugActionResult` → on failure show error → do not refresh unrelated large data.

**After LED/M370 send:** validate frame → send → set preview source label → refresh status only if needed.

**On timer (only while page 6.5 active):** reuse/extend existing low-rate `firmwareStatusPollTimer`/`powerStatusPollTimer` to refresh API-health + power at their existing low rate. No full page rerender — call only the affected `renderDebug*` sub-renderers. **No LED bitmap/frame polling.**

**Never auto-refresh:** raw command panel, logs, destructive actions, AP password reveal state.

---

## 8. JavaScript Refactor Plan

Replace the debug portion of the monolithic `renderState()` with a dispatcher + per-panel renderers. `renderState()` keeps responsibility only for **non-debug** UI it still drives (mode toggle, badges shared with 6.1); its debug-only blocks (`#state-kv`, `#debug-kv`, `#resource-kv`, `#firmware-kv` population) are extracted into `renderDebugPage()` and its children, called from `renderState()` (or directly) only when `#page-debug` is active.

| Function | Purpose | Inputs | Output | DOM target | Side effects | Replaces | On failure |
|---|---|---|---|---|---|---|---|
| `renderDebugPage()` | Dispatcher; calls all panel renderers | none (reads `state`,`firmware`) | void | `#page-debug` | none | debug blocks of `renderState()` | guard each child in try/catch; never throw to caller |
| `renderDebugDeviceSummary()` | Panel 1 | `state`,`getAllFaces()` | void | `#debug-device-summary` | none | `#state-kv` block | render "—" on missing data |
| `renderDebugFirmwareHealth()` | Panel 2 | `firmware` | void | `#debug-firmware-health` | none | `#firmware-kv` block | show offline labels |
| `renderDebugPowerPanel()` | Panel 3 (+advanced) | `state.battery*`/`charge*` | void | `#debug-power-panel` | toggles DPS banner | `#debug-kv` battery rows | render "—" |
| `renderDebugNetworkPanel()` | Panel 4 | `state.apIp/apDomain`,AP consts | void | `#debug-network-panel` | respects mask flag | `#debug-kv` AP rows | Config-fallback tag |
| `renderDebugButtonSimulator()` | Panel 5 (static + result lines) | action state | void | `#debug-button-simulator` | none | `[data-gpio]` group | n/a |
| `renderDebugProtocolLab()` | Panel 6 (validation line) | `#debug-m370` value | void | `#debug-protocol-lab` | none | LED/M370 group | show validation error |
| `renderDebugPreviewPanel()` | Panel 7 meta | `debugPreviewFrame`,`debugPreviewSource`,`debugPreviewReason`,`debugPreviewUpdatedAt` | void | `#debug-preview-panel` | none | matrix-debug meta | "—" |
| `renderDebugResourcePanel()` | Panel 8 | `EXPRESSION_PARTS`,counts,consts | void | `#debug-resource-panel` | none | `#resource-kv` block | "—" |
| `renderDebugLogPanel()` | Panel 9 | `logs[]`,filter | void | `#debug-log-panel` | none | `renderLog` (debug view) | empty |
| `renderDebugRawCommandPanel()` | Panel 10 | last result | void | `#debug-raw-command-panel` | none | `#serial-*` | n/a |
| `renderDebugDangerZone()` | Panel 11 | none | void | `#debug-danger-zone` | none | reset button | n/a |
| `buildDebugKvRows()` | Build `[label,value,source]` arrays | data | rows[] | n/a | none | inline `kvRows` arrays | returns [] |
| `renderDebugKvList(target, rows)` | Render kv rows + source chips | id, rows | void | given id | sets innerHTML | extends `kvRows` | no-op if target missing |
| `renderDebugBadge(value, type)` | Badge markup | value,type | html string | n/a | none | inline badge code | "—" badge |
| `buildDebugRow({label,value,source,stale,note})` | Build one kv row with explicit source metadata (replaces label-inference; see v2 rule 2) | row spec | row object | n/a | none | (new) | renders "—" + "Unknown" source |
| `estimateFrameWatts(frame,color,brightness)` | Shared power estimate for DPS + all-on warning (v2 rule 6) | frame,hex,brightness | watts | n/a | none | inline `updateDps` math | returns 0 |
| `getSavedFaceFrame(index)` | Pure saved-face → frame, no side effects (v2 rule 5) | index | frame | n/a | none | (new) | `blankFrame()` |
| `renderDpsWarning()` | Toggle both DPS banners (v2 rule 7) | none | void | `#debug-summary-dps-warning`,`#debug-power-dps-warning` | none | `#dps-warning` toggle in `updateDps` | no-op |
| `renderDebugReadouts()` | Render-boundary wrapper: calls only read-out renderers when page active (v2 rule 4) | none | void | kv/badge/meta containers | none | debug blocks of `renderState()` | guarded |
| `setDebugActionBusy(actionId, busy)` | Toggle button busy/disabled | id,bool | void | button | disabled+`.busy` | (new) | no-op |
| `showDebugActionResult(actionId, result)` | Show ok/err/pending line | id,{ok,msg} | void | result span | sets text+class | (new) | no-op |
| `validateM370Input(text)` | Validate before send | string | {valid,normalizedLen,expectedLen:93,hadPrefix,error} | n/a | none | inline `m370ToFrame` try | returns invalid+error |
| `parseM370ToFrameOrError(text)` | Parse or structured error | string | {frame}|{error} | n/a | none | `m370ToFrame` | returns error, no throw |
| `applyDebugFrame(frame, source, options)` | Set debug preview ± send | frame,sourceLabel,{send} | void | `#matrix-debug`+preview meta | **preview-only (send=false): writes ONLY `debugPreviewFrame`+preview meta+matrix; never touches `currentFrame`/`setCurrentFrame`/`queueFirmwareFrame` (v2 rule 1)**. send=true: `setCurrentFrame(...)` then mirror into `debugPreviewFrame`, source="firmware" | (new) | guard + result line |
| `confirmDangerAction(options)` | Explicit destructive confirm | {title,body,confirmLabel} | bool | modal/`confirm` | none | inline `confirm()` | returns false |
| `copyDebugDiagnostics(scope)` | Copy diag/firmware JSON | "firmware"/"all" | void | clipboard | warns about network info | `#debug-copy-status` | toast error |

`applyDebugFrame` is the single chokepoint and the core preview/send distinction. **Per v2 rule 1, preview-only paths write ONLY the dedicated `debugPreviewFrame` buffer — never `currentFrame`** — because `matrix-basic` and `matrix-debug` both currently read `currentFrame` (app.js:3235) and `updateDps` computes from it. Send paths route through existing `setCurrentFrame` (which already queues), then mirror into `debugPreviewFrame`.

New tracking fields (browser-local): `debugPreviewFrame` (frame buffer, matrix-debug re-pointed here), `debugPreviewSource`, `debugPreviewReason`, `debugPreviewUpdatedAt`; `firmwareLastSyncAt`/`state.lastStatusSyncAt`/`state.lastNetworkSyncAt` (set in `applyFirmwareRuntimeState` on success), `state.lastPowerSyncAt` (set in power refresh); `state.apIpSource`/`state.apDomainSource` (set at the AP-assignment sites, app.js:~4582). These feed panels 1/2/3/4/7.

---

## 9. HTML Refactor Plan

New `#page-debug` body: replace `.debug-layout` masonry with `<div class="debug-grid">` containing eleven `.card` panels in the order of §2, each with the IDs:
`debug-device-summary`, `debug-firmware-health`, `debug-power-panel`, `debug-network-panel`, `debug-button-simulator`, `debug-protocol-lab`, `debug-preview-panel`, `debug-resource-panel`, `debug-log-panel`, `debug-raw-command-panel`, `debug-danger-zone`.

**Preserve these existing IDs** (JS/CSS already bind them — keep to avoid breakage):
- `#matrix-debug` — re-parent into `#debug-preview-panel`; keep the id, but **re-point its frame provider from `() => currentFrame` to `() => debugPreviewFrame`** in both `MATRIX_VIEW_CONFIGS` (app.js:3235) and the `initMatrix("matrix-debug", …)` call (app.js:~9814) per v2 rule 1. Give the new card a sizing-compatible class (v2 rule 9) so matrix fitting still works.
- `#debug-m370` — keep (validation + autoresize bindings).
- `#dps-warning` — **removed** (v2 rule 7). Replace with two distinct banners `#debug-summary-dps-warning` (panel 1) and `#debug-power-dps-warning` (panel 3); `updateDps()` calls the new `renderDpsWarning()` helper which toggles `.show` on both. No shared/ambiguous id remains.
- `#log` — keep (`renderLog`).
- `[data-gpio]` buttons — keep the attribute + codes; the existing delegated loop in `initializeDebugControls` still binds them.
- `#debug-refresh-power`, `#debug-reset-battery-min`, `#debug-reset-battery-max`, `#firmware-ping` — keep ids; move into new panels.

**Replace / rename:**
- `#state-kv`,`#debug-kv`,`#resource-kv`,`#firmware-kv` → removed; content rebuilt by panel renderers into new ids. Update `renderState()` to stop targeting them.
- `#serial-input`/`#serial-send` → `#debug-raw-json`/`#debug-raw-send` in panel 10 (update `initializeDebugControls`).
- `#debug-copy-status` → `#debug-copy-diag` in panel 2.
- `#debug-reset-storage` → `#debug-clear-user-faces` in panel 11.
- `#debug-all-off/-all-on/-checker/-border/-current-face` → split into preview + send variants (e.g. `#debug-preview-checker` / `#debug-send-checker`).
- `#battery-v`/`#charge-v`/`#update-adc` → keep ids, move into Advanced ADC `<details>`.

**Migrate event bindings safely:** all bindings live in `initializeDebugControls()` and the `[data-gpio]` loop. Update the `setClickHandlers([...])` array to the new ids in one place. Because `$()` returns null safely and `setClickHandlers` should skip missing ids, partial migration won't crash. Keep `initializeDebugControls` idempotent.

**Avoid breaking init:** `setupDebugMasonryLayout`/`scheduleDebugMasonryLayout` (app.js ~5854–5912) reference `#page-debug .debug-layout` and `.debug-layout .card`. After switching to `.debug-grid`, either (a) point these at `.debug-grid` and make them no-ops (CSS grid handles layout), or (b) delete the masonry calls from `switchPage` and `renderState`. Recommended: gut the masonry to a no-op stub first (keeps call sites valid), remove later in step 12.

---

## 10. CSS / Style Plan

Reuse existing classes (§5). Add only:
- `.debug-grid` — `display:grid; gap:14px;` one column default; `@media(min-width:981px){ grid-template-columns: minmax(0,1fr) minmax(0,1fr); align-items:start; }`. Panels 1/5/6/7 may span both columns via `.debug-span-2{ grid-column:1/-1; }` where wider is clearer (summary, simulator, lab, preview).
- `.debug-source` — small inline source chip: muted, 10–11px, rounded, reuse `.badge` sizing tokens; colour variants `.src-fw/.src-br/.src-res/.src-cfg/.src-cmp/.src-fallback` (subtle tint only).
- `.debug-sim` — secondary/muted button tint so simulator buttons don't read as primary.
- `.debug-danger` — red-tinted card border for Danger Zone (reuse `button.danger` palette).
- `.debug-result{.ok|.err|.pending}` — small status text (green/red/muted).
- `details.debug-advanced > summary` — minimal disclosure styling (reuse existing `summary` rule).
- `.debug-masked` — masked password row (monospace dots).
- `.debug-validation{.ok|.err}` — M370 validation message line.
- `.debug-log` (or reuse `.debug-log-card .log`) — console block.

No new colour system; all colours pulled from existing CSS variables / existing status colours. **Do not remove `.debug-measure-card` until `#matrix-debug`'s new wrapper carries an equivalent sizing class** — matrix fitting special-cases it at app.js:6375 (`closest(".led-preview-card,.debug-measure-card")`) and :6483 (`querySelectorAll(".matrix-wrap,.led-preview-card,.debug-measure-card")`). Either keep `.debug-measure-card` on `#debug-preview-panel` or add `#debug-preview-panel`/its wrapper to those two selectors (v2 rule 9). Remove obsolete `.debug-layout`, `.debug-measure-grid`, `.debug-measure-controls` rules in step 12 once unused.

---

## 11. Safety Plan

- **All-on LED test:** before send, compute `estimateFrameWatts(allOnFrame, state.color, state.brightness)` (the shared helper refactored out of `updateDps`, v2 rule 6); if `>= LED_POWER_WARNING_WATTS` (=40) show the power-warning banner and require an explicit "Send all-on anyway" click; never auto-send; blocked entirely when offline (send path disabled).
- **Clear user faces:** Danger Zone only; `confirmDangerAction` with body "This permanently clears all user-saved faces. Default faces are not affected."; Cancel = no-op; on success refresh saved-face/resource panels + result line.
- **Raw command sender:** valid JSON required; object must include string `cmd` (existing guard kept); "I understand this hits /api/command directly" checkbox gates the send button; invalid → no send + parse error shown.
- **Invalid M370:** `validateM370Input` gates both parse-preview and parse-send; invalid never sends; exact error displayed (wrong length / bad chars / prefix note).
- **AP password visibility:** masked by default; show/hide is browser-local and never persisted; reveal state not auto-refreshed.
- **Command spam:** `setDebugActionBusy` disables the in-flight button until its promise settles; existing pump queues (`buttonCommandPump`/`frameSendPump`) still cap depth.
- **Firmware offline:** FW rows tagged stale; local diagnostics stay usable. Note only `isOfflineHtmlMode()` (file://) gives a clean short-circuit; ordinary network-down (`firmware.online===false`) surfaces as a failed `apiPost` promise — result lines must handle both (see §7 offline table). Send-to-firmware controls are disabled when `firmware.online===false || isOfflineHtmlMode()`.
- **Stale-as-live:** mandatory source chips + offline header notice prevent mistaking last-known values for live reads.
- **Sensitive logs:** copy-log / copy-diagnostics / download-log show a one-line "may contain SSID/IP/domain" notice; **`DEVICE_AP_PASSWORD` is never written into any log or any `copyDebugDiagnostics` scope** (summary/firmware/full), per v2 rule 10.

---

## 12. Implementation Migration Steps

Each step ends with a test gate; do not proceed until it passes.
1. **Snapshot** current behaviour + all IDs/handlers (this doc's grounding section). *Test:* confirm every current control still works on a baseline build.
2. **Add reusable helpers** (`renderDebugKvList`, `buildDebugRow`, `renderDebugBadge`, `estimateFrameWatts`, `getSavedFaceFrame`, `renderDpsWarning`, `setDebugActionBusy`, `showDebugActionResult`, `validateM370Input`, `parseM370ToFrameOrError`, `applyDebugFrame`, `confirmDangerAction`, `copyDebugDiagnostics`) with no UI wired yet. *Test:* unit-call each from console; no regressions on existing page.
3. **Replace `#page-debug` inner markup in one edit** with the new grid + panels, masonry stubbed to no-op (v2 rule 8 — **no "both visible" state**, to avoid duplicate live IDs like `#matrix-debug`/`#debug-m370`/`#log`). *Test:* page loads; preserved-id handlers fire; `#matrix-debug` binds the single new node.
4. **Migrate Device Summary** (panel 1) + retire `#state-kv`. *Test:* mode/face/brightness/colour/playback/scroll/battery/AP IP/FPS all correct online; "—"/stale offline.
5. **Migrate Firmware Health** (panel 2) + retire `#firmware-kv`; wire refresh/clear-error/copy-diag. *Test:* counters update; clear-error works; copy produces JSON with network-info warning.
6. **Migrate Power/Battery/ADC (panel 3) + Network (panel 4)**; move ADC sim + thresholds into advanced; mask AP password. *Test:* friendly battery rows correct; advanced collapsed; DPS banner toggles; password masked; show/hide works; firmware-vs-fallback tag correct.
7. **Migrate GPIO simulator** (panel 5) with busy-disable + result lines. *Test:* every B-code sends, shows result, disables while busy, refreshes summary on success.
8. **Migrate LED/M370 lab** (panel 6) with preview/send split + validation + all-on warning. *Test:* preview-only does not queue a frame (verify via `firmware.sentFrames` unchanged); send increments it; invalid M370 blocked; all-on warns.
9. **Migrate Debug Preview** (panel 7); re-parent `#matrix-debug`; wire source label/reason/timestamp. *Test:* matrix renders; source label matches last action; no frame polling (watch network).
10. **Migrate Resource (panel 8) + Log (panel 9)**; retire `#resource-kv`; move raw sender out of log card. *Test:* resource rows correct + tagged; log clear/download/copy work; raw sender no longer in log card.
11. **Move destructive action to Danger Zone** (panel 11) + Advanced Raw Command (panel 10). *Test:* clear-faces confirm/cancel; raw send gated by checkbox + JSON/`cmd` validation.
12. **Remove obsolete render paths/CSS** (`#state-kv`/`#debug-kv` blocks from `renderState()`, masonry functions, `.debug-layout`/`.debug-measure-*` CSS). *Test:* no console errors; no dead ids referenced; other pages unaffected.
13. **Final visual polish** (spacing, source-chip alignment, mobile stacking, span-2 panels). *Test:* desktop + mobile screenshots match WebUI style.
14. **Regression test other pages** (6.1 basic, 6.2 editor, 6.3 parts, 6.4 scroll). *Test:* `renderState()` still drives shared badges/mode toggle; matrices on all pages render; no broken bindings.

---

## 13. Manual Test Checklist

Layout/nav: desktop layout; mobile layout (<980px single column, source order preserved); switching to/from 6.5 and back; matrices fit on switch.
Firmware link: online; offline (`isOfflineHtmlMode`); `/api/status` success; `/api/status` failure (lastError + stale tags); `/api/power` success; `/api/power` failure.
Summary: current mode display (manual/auto/scroll/unknown badge); current face index/name/type; brightness + colour swatch; text scroll active badge; battery powered/unpowered badge; charging display; DPS warning banner.
Network: AP password masked by default; show/hide toggle; AP IP/domain firmware-vs-config-fallback tag.
Simulator: B1/B2/B3/B4/B5 each send + result + busy-disable; B3+B1/B3+B2; B6 short/long; B6+B3 network; result line shows success/failure + whether refreshed.
LED/M370: all-off preview (no frame queued); all-off send; all-on warning then send; checker/border preview + send; current-saved-face preview + send; valid M370 parse-preview; valid M370 parse-send; invalid M370 blocked with exact error; copy debug preview M370 (copies `debugPreviewFrame`, not `currentFrame`).
Diagnostics: copy diagnostic JSON (firmware scope) + network-info warning; queue counters (sent/dropped/frame/button) update and labelled browser-side.
Raw command: valid JSON sends; invalid JSON blocked; object without string `cmd` blocked; send disabled until checkbox ticked.
Log: clear; download; copy; (optional) category filter.
Danger: clear user faces — cancel does nothing; confirm clears user faces only, refreshes panels, shows result.
Preview isolation (v2 rule 1): after any preview-only action, confirm `matrix-basic` (page 6.1) is unchanged, `currentFrame` is unchanged, `firmware.sentFrames` is unchanged, and DPS state did not shift from the preview; only `#matrix-debug`/`debugPreviewFrame` changed.
Render boundary (v2 rule 4): type text into `#debug-m370` and `#debug-raw-json`, trigger a status/power poll (or any `apiGet`/`apiPost`), and confirm the textareas and the raw-command checkbox are NOT cleared/rebuilt.
Saved-face preview (v2 rule 5): preview "current saved face" does not increment `firmware.sentFrames`; the send variant does.
Stale/perf: stale/fallback labels when offline; per-panel "Last updated" timestamps present; no full-frame polling on timer (verify via network panel); page does not heavy-rerender on low-rate timer.

---

## 14. Risk Analysis

| Risk | Mitigation |
|---|---|
| Breaking existing event bindings | All debug bindings centralised in `initializeDebugControls` + `[data-gpio]` loop; migrate id list in one edit; `$()`/`setClickHandlers` skip missing ids so partial states don't crash |
| Changing ids used by JS | Preserve `#matrix-debug`,`#debug-m370`,`#log`,`[data-gpio]`,`#debug-refresh-power`,`#firmware-ping`; `#dps-warning` is intentionally replaced by `#debug-summary-dps-warning`+`#debug-power-dps-warning` (update `updateDps`→`renderDpsWarning` same-commit); rename others deliberately and update bindings same-commit |
| `renderState()` renders multiple debug sections | Extract debug blocks into `renderDebug*`; `renderState()` keeps only shared non-debug UI; call `renderDebugPage()` when `#page-debug` active |
| Confusing browser-local vs firmware values | Mandatory source chips via explicit `buildDebugRow({source})` metadata (never label inference); `state.apIpSource`/`apDomainSource` flags; offline header notice; distinct chip colours |
| Stale status after command | After commands refresh runtime summary; result line states whether refreshed |
| Command spam | `setDebugActionBusy` disables in-flight buttons; existing pump queues cap depth |
| Accidental destructive action | Danger Zone isolation + `confirmDangerAction` explicit body + Cancel no-op |
| AP password exposure | Masked default; reveal browser-local, never logged or in diagnostics JSON |
| Excessive firmware traffic | Reuse existing low-rate pollers; only summary+power on timer; no per-render fetches |
| LED frame sync too heavy | `applyDebugFrame` preview path never queues; no full-frame polling; send path uses existing single-frame queue |
| Inconsistent style | Reuse `.card`/`.kv`/`.badge`/`.warning`/`button.danger`; minimal additive CSS only |
| Mobile crowding | `.debug-grid` single column; collapsible advanced; span-2 only where helpful |

---

## 15. Acceptance Criteria

- [ ] 6.5 organised into the eleven clear panels in §2 order.
- [ ] Most useful diagnostics (online, mode, face/frame, battery, network) appear at the top.
- [ ] Raw ADC/thresholds, resource metadata, and raw command moved to advanced/lower sections.
- [ ] Destructive clear-user-faces isolated in a danger zone with explicit confirmation.
- [ ] AP password masked by default with show/hide.
- [ ] M370 validated before any send; invalid never sends.
- [ ] GPIO simulation gives per-action command/success/error/refreshed feedback.
- [ ] LED tests clearly distinguish preview-only from send-to-firmware; all-on warns.
- [ ] Every value tagged Firmware / Browser / Resource / Config / Computed / Fallback.
- [ ] Page works and is honestly labelled "stale" when firmware is offline.
- [ ] No full LED-frame polling; firmware traffic stays at existing low-rate poll.
- [ ] Visual style matches other WebUI pages (existing card/kv/badge/danger classes).
- [ ] All current functionality preserved or explicitly replaced (per §3 — nothing useful removed).
- [ ] Implemented with no firmware changes (only `data/index.html`, `data/app.js`, `data/styles.css`).

---

## Integration Verification Appendix (full recheck vs. current code)

Every existing hook the plan depends on was re-verified in `data/app.js` / `data/index.html` / `data/styles.css`. **Result: the plan is integrable with no firmware changes and no missing dependencies.**

### Existing functions the plan reuses (all confirmed present)
`kvRows`, `escapeHtml`, `$`, `setClickHandlers` (3646 — safely skips missing ids: only sets `onclick` when `$(id)` exists, so partial id migration cannot throw), `m370ToFrame` (4139), `frameToM370` (4125), `blankFrame` (4095), `cloneFrame`, `onCount` (4103), `makePatternFrame` (10059), `setCurrentFrame` (5159, calls `guardBeforeOutput`+`queueFirmwareFrame`), `queueFirmwareFrame` (5017), `applySavedFace` (7037, **queues** — preview must use new `getSavedFaceFrame`), `sendButtonCommand` (5001), `sendAuxCommand` (4852), `apiGet` (4210)/`apiPost` (4252) (both call `renderState()` before fetch — drives the render-boundary rule), `applyFirmwareRuntimeState` (4572, AP-assignment block ~4582 is the hook for `apIpSource`/`apDomainSource`), `applyPowerData` (4421)/`refreshPowerStatusFromFirmware` (5742) (hooks for `lastPowerSyncAt`), `syncRuntimeStateFromFirmware` (5681), `syncRuntimeSummaryFromFirmware` (5701 — **exists**), `resetBatteryVoltageRecord` (9817, firmware-backed + offline-guarded), `persistFaceDocuments` (7457, offline-tolerant), `downloadJsonFile` (7496), `log`/`renderLog` (4167/4174), `updateDps` (5172; `$("dps-warning")` toggle at 5182 → swap to `renderDpsWarning()`), `renderMatrices` (6515), `initMatrix` (6322, `frameProvider` closure), `setupDebugMasonryLayout`/`scheduleDebugMasonryLayout` (5854 — stub then delete), `formatVolts`/`formatBatteryPercent`/`formatChargingState`/`batteryPowerText`/`formatMilliVolts`, `getAllFaces`/`faceTypeLabel`/`renderSavedFaces`, `updateModeToggleUi`.

### Existing constants/objects (confirmed)
`state` (3454), `firmware` (3533), `currentFrame` (let), `API_ENDPOINTS` (3229: frame/command/savedFaces/power/status), `MATRIX_VIEW_CONFIGS` (3235: `matrix-debug → () => currentFrame`, the re-point target), `EXPRESSION_PARTS`/`MATRIX`/`TOTAL_LEDS`/`COLS`/`ROWS`, `SERPENTINE_WIRING`, `DEVICE_AP_SSID`/`DEVICE_AP_PASSWORD`/`DEVICE_AP_DOMAIN`/`DEFAULT_AP_IP` (3215–3218), `WEBUI_M370_QUEUE_MAX`/`WEBUI_BUTTON_COMMAND_QUEUE_MAX` (3256/3258), `LED_POWER_WARNING_WATTS`/`LED_ESTIMATED_WATTS_PER_CHANNEL`/`LED_CHANNEL_COUNT`/`LED_FULL_BRIGHTNESS` (3208–3211, config `powerWarningWatts:40`), `firmwareStatusPollTimer`/`powerStatusPollTimer` (low-rate pollers exist), `PAGES`/`switchPage` (5921, already has a `debug` branch calling `setupDebugMasonryLayout(true)`+`refreshPowerStatusFromFirmware("debug_page_enter", true)`).

### Existing CSS classes reused (confirmed in styles.css)
`.card`/`.card h3`/`.card h4` (1213+), `.kv`/`.kv .k`, `.row`, `.stack`, `.control-panel`, `.badge` (1178), `.status-dot{.dim|.warn|.danger}` (2467+), `.warning`/`.warning.show` (1796/1807 — amber; the two new DPS banners reuse this), `button.danger` (509), `button:disabled` (opacity .42 grayscale), `.hint`, `.mono`, `.matrix`/`.matrix-wrap`, `.field`, `summary` (347). Matrix fitting special-cases `.debug-measure-card` at 6375 (`closest`) and 6483 (`querySelectorAll`) — handled by v2 rule 9.

### New code to add (none conflict with existing names)
State/buffers: `debugPreviewFrame`, `debugPreviewSource`, `debugPreviewReason`, `debugPreviewUpdatedAt`, `firmwareLastSyncAt`, `state.lastStatusSyncAt`, `state.lastPowerSyncAt`, `state.lastNetworkSyncAt`, `state.apIpSource`, `state.apDomainSource`. Functions: `renderDebugPage`/`renderDebugReadouts` + the eleven `renderDebug*` panel renderers, `buildDebugRow`, `renderDebugKvList`, `renderDebugBadge`, `estimateFrameWatts`, `getSavedFaceFrame`, `renderDpsWarning`, `setDebugActionBusy`, `showDebugActionResult`, `validateM370Input`, `parseM370ToFrameOrError`, `applyDebugFrame`, `confirmDangerAction`, `copyDebugDiagnostics`. (`getDebugValueSource` is **not** added — removed per v2 rule 2.)

### Touch points in existing functions (small, localized edits)
1. `MATRIX_VIEW_CONFIGS` (3235) + `initMatrix("matrix-debug", …)` (9814): provider `() => currentFrame` → `() => debugPreviewFrame`.
2. `updateDps` (5182): replace `$("dps-warning")` toggle with `renderDpsWarning()`; extract math into `estimateFrameWatts`.
3. `applyFirmwareRuntimeState` (~4582): set `apIpSource`/`apDomainSource`/`lastStatusSyncAt`/`firmwareLastSyncAt`/`lastNetworkSyncAt` at the existing `data.ap?.ip`/`data.ap?.domain`/success points.
4. `applyPowerData`/`refreshPowerStatusFromFirmware`: set `state.lastPowerSyncAt`.
5. `renderState`: remove the `#state-kv`/`#debug-kv`/`#resource-kv`/`#firmware-kv` blocks and the `scheduleDebugMasonryLayout()` call; keep the shared header battery/charge badge updates + `updateModeToggleUi()`; add a page-gated `renderDebugReadouts()` call.
6. `initializeDebugControls` (9845) + `[data-gpio]` loop: update the `setClickHandlers` id list to the new ids; add busy/result wrappers.
7. `switchPage` debug branch (5955): keep the page-enter refresh; replace masonry call with grid (stub masonry first).
8. `setupDebugMasonryLayout`/`scheduleDebugMasonryLayout` (5854): stub to no-op, delete in step 12.

### Confirmed behavioral facts that shaped the plan
- Both `apiGet` and `apiPost` call `renderState()` **before** the request → any debug rendering reachable from `renderState()` must be page-gated and must not rebuild interactive inputs (render boundary, v2 rule 4).
- `matrix-basic` **and** `matrix-debug` both read `currentFrame` today → separate `debugPreviewFrame` is mandatory (v2 rule 1).
- `applySavedFace` and `setCurrentFrame` queue firmware frames → preview must use pure `getSavedFaceFrame` (v2 rule 5).
- `sendAuxCommand` always POSTs (no offline short-circuit); only `sendButtonCommand` short-circuits `isOfflineHtmlMode()` and only for file:// mode → result lines handle missing-promise vs rejected-promise (v2 §7 offline table).
- `persistFaceDocuments` is offline-tolerant → clear-user-faces works offline.
- Header battery/charge badges are shared across pages → stay in `renderState()`.

### Residual risks / decisions for the implementer (none blocking)
- **Log category filter** stays optional: `logs[]` are plain timestamped strings (`log()` at 4167), so filtering needs a category-prefix convention added to `log()` or is deferred to v1+1. Not required for acceptance.
- **`estimateFrameWatts` color factor:** the existing DPS math multiplies by a color factor derived from `state.color`; the all-on warning should pass `state.color` so the estimate matches `updateDps` exactly.
- **`firmware-pause` placement** is decided (panel 5). If you prefer it under Advanced Raw Command instead, that is a one-line move; either is consistent with the plan.
