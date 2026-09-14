# WebUI feature inventory (source of truth for the iOS rewrite)

Verified against `data/index.html`, `data/app.js` (14,112 lines) and `plan.md` on 2026-09-11.
Every row must exist in the iOS app with the same behaviour. "API" names the old HTTP
call; the RinaLink equivalent is in `RINALINK_PROTOCOL_V1.md`.

## A. Page 1 — Basic control (`#page-basic`)

| # | Feature | What it does | Old API |
|---|---|---|---|
| A1 | Live LED preview | 22×18 grid (370 valid cells of 396) mirrors the frame the board is showing. Board-photo background. Diff-render per cell. | polls `/api/status`, `/api/preview_sync` (80 ms idle / 250 ms scrolling) |
| A2 | Brightness | Slider + number 10–200 (default 50), ±8 buttons, reset-to-50, preset row. Echo from firmware suppressed 2 s after local touch. | `set_brightness{raw}` |
| A3 | Manual/Auto toggle | Same path as physical B3: optimistic flip, blank + 90 ms deferred restore when non-face content was on screen. | `button{B3}` |
| A4 | Face prev/next | Wraps modulo face count; optimistic local preview; stops any scroll first and clears restoreAuto. | `button{B2}` / `button{B1}` |
| A5 | Auto interval | Slider 0.5–10 s step 0.1, ±0.5 s buttons, presets 0.5/1/2/3/5/7.5/10 s. Default 3000 ms. | `set_auto_interval{ms}` |
| A6 | Main colour | Hex text `#RRGGBB` + swatch. UI default `#ec3fc7`, firmware default `#f971d4` wins after first sync. | `set_color{hex}` |
| A7 | Colour presets | Two-level picker: 6 parent groups (default pink, μ's, Aqours, 虹咲学园, Liella!, 蓮ノ空) → 67 character colours. | `set_color{hex}` |
| A8 | Scroll text input | Textarea ≤1000 chars, default "RinaChanBoard 370 LED こんにちは 璃奈ちゃんボード". Emoji normalised to text presentation (VS15 added, VS16 stripped); ≤4096 UTF-8 bytes enforced client-side. | — |
| A9 | Scroll send | Rasterise text with the ark12 12-px bitmap font → one frame per 1-px horizontal offset (right-to-left) → upload in 24-frame chunks → start. Progress bar. Abort if >3072 frames or empty text. | `POST /api/scroll` ×N, `start_scroll{fps,intervalMs,sourceText}` |
| A10 | Scroll pause/resume | Toggles user-pause; 250 ms lock between flips; disabled while system-paused. | `pause_scroll` / `resume_scroll` |
| A11 | Scroll stop/clear | Clears display; restores auto mode if `restoreAutoAfterScroll`. | `stop_scroll{clear:true,restoreAuto}` |
| A12 | Scroll step ±1 | Forces pause, moves one frame. | `scroll_step{direction}` |
| A13 | Scroll speed | 1–60 fps slider/number, ±5, reset 10, presets 1/10/20/30/40/50/60. Live retune when a session exists. | `set_scroll_interval{fps,intervalMs}` |
| A14 | Scroll status readouts | Phase (IDLE/GENERATING/UPLOADING/STARTING/ACTIVE/STEPPING/STOPPING/RESTORING/STALE/DROPPED), frame index/count, measured fps (PLL speed lock on `presentedSeq`/`presentedAtUs`). | `preview_sync` |
| A15 | Scroll restore on reload | On launch, restore text/fps/frame index from firmware unless local unsent edits conflict (warn instead). | `GET /api/scroll/meta` |

## B. Page 2 — Custom expression / parts composer (`#page-parts`)

| # | Feature | What it does | Old API |
|---|---|---|---|
| B1 | Pixel editor | Tap-to-toggle 370 cells (no drag). Clear / Fill / Invert. | — |
| B2 | Send frame | Push editor frame to board. | `POST /api/frame` reason `custom_face_send` |
| B3 | Live mode | Default ON: every edit auto-sends (≥20 ms apart, queue depth 6, drop-oldest). | `POST /api/frame` reason `custom_live_send` |
| B4 | Parts composer | 4 groups: left eye ("0",101–127), right eye ("0",201–227), mouth ("0",301–332), cheek (400 empty–405). 92 stored part bitmaps OR-composited into one frame. Default {101,201,301,400}. | live-send |
| B5 | Random / Default | Random valid part per group; reset to default set. | live-send |
| B6 | Eye symmetry | Choosing a left-eye part mirrors to the right eye and vice-versa. | — |
| B7 | Revert edit | Back to the baseline captured when editing began. | — |
| B8 | Packed-frame text I/O | 94-hex textarea mirrors the editor; copy; import from hex / 47-int JSON / base64 with validation (47 B, zero tail bits). | — |
| B9 | Save to library | Name field (default `parts_face`); saves as `type:"parts"` (from parts) or `"custom"`; updates existing when editing; sequential `order`. | `POST /api/saved_faces` (whole document) |
| B10 | Face library | Rows: tap to apply, inline rename, drag reorder, edit-in-editor, delete (blocked for `type:"default"`; ≥1 default must remain). | `apply_saved_face{index}`, `POST /api/saved_faces` |
| B11 | Import / export library | Open a local `saved_faces.json` (then also save to it) / download whole document (`rina_packed_faces_370_v2`, version 4). | — (iOS: Files picker / share sheet) |

## C. Page 3 — Debug console (`#page-debug`)

| # | Feature | What it does | Old API |
|---|---|---|---|
| C1 | Debug preview | Same live matrix. | — |
| C2 | Device overview | Key/values from status; estimated power `lit×0.06×5×(brightness/255)×((r+g+b)/765)` W, banner above 40 W. | `/api/status` |
| C3 | Firmware health | Ping/refresh status & power, clear local API error, copy diagnostics JSON; client-side sent/dropped counters. | `/api/status`, `/api/power` |
| C4 | Power panel | vbat, vcharge, %, charging, validity flags; reset battery min / max; local-only ADC simulation inputs. | `/api/power`, `reset_battery_min/max` |
| C5 | Network panel | SSID / IP / domain / clients, show-password toggle, refresh. (iOS: becomes the Connection screen, §E) | `/api/status.ap` |
| C6 | Button simulator | B1 next, B2 prev, B3 A/M, B4 bright−, B5 bright+, B3B1 interval−, B3B2 interval+, B6 short = battery overlay single-shot, B6 long = battery details, pause scroll. | `button{…}`, `battery_overlay{singleShot}`, `pause_scroll` |
| C7 | Test patterns (preview only) | Off / checker / border / current saved face into local preview. | — |
| C8 | Test patterns (send) | Off / all-on (confirm + 40 W warning) / checker / border / saved face. | `POST /api/frame` reason `debug_*` |
| C9 | Packed-frame lab | Parse hex / int-array / base64 → validate → preview or send; copy. | `POST /api/frame` |
| C10 | Comms log | 500-line buffer, 120 shown, level filter (error / warn+ / normal / verbose), clear / copy / download. | — |
| C11 | Raw command | JSON textarea → validate → confirm checkbox → send any command. | `POST /api/command` |
| C12 | Danger zone | Clear all user faces (typed "CLEAR" confirmation); defaults kept. | `POST /api/saved_faces` |

## D. Global

| # | Feature | What it does |
|---|---|---|
| D1 | Boot loader animation | Avatar swap + halo breathe, then card waterfall reveal (115 ms stagger). iOS: launch/splash animation. |
| D2 | Navigation | 3 pages; re-sync preview on page entry. iOS: TabView. |
| D3 | Header badges | Online/offline, battery V + %, charging state. |
| D4 | Polling | Status 1 Hz, preview_sync 80/250 ms, power 1 Hz; paused when hidden. iOS: replaced by pushed events (`EV_*`). |
| D5 | Offline / reconnect | Retain state, retry, rate-limited error log, restore scroll session. |
| D6 | Rate limiting | Frames ≥20 ms apart (depth 6), commands ≥120 ms apart (depth 4), drop-oldest. |
| D7 | Language | Simplified Chinese UI. iOS: zh-Hans strings with an English localisation. |
| D8 | Persistence | None client-side; everything rebuilt from the board. iOS adds: known boards, Wi-Fi mode preference, last transport. |

## E. New in the iOS app (transport layer, replaces C5)

| # | Feature |
|---|---|
| E1 | Bluetooth scan / connect to the board (CoreBluetooth); all features work over BLE. |
| E2 | Wi-Fi provisioning over BLE: scan networks, enter password, choose mode (off / hotspot / home Wi-Fi / Wi-Fi with hotspot fallback). |
| E3 | Home-Wi-Fi connection over TCP: Bonjour discovery of `rinaboard-<id>.local`, manual IP fallback. |
| E4 | Hotspot ("direct") connection: join the board's SoftAP via `NEHotspotConfiguration`, TCP to `192.168.4.1`. |
| E5 | Transport switcher with live status, auto-fallback BLE ⇄ Wi-Fi, per-board memory of the preferred transport. |

## F. Static data to port from `app.js`

| Data | Source | Size |
|---|---|---|
| Matrix geometry + serpentine map (`XY_TO_INDEX`, `INDEX_TO_XY`, `PHYSICAL_TO_LOGICAL_INDEX`, row lengths `[18,20,20,20,22×9,20,20,20,18,16]`) | app.js ~3262–3310 | 370 entries |
| `EXPRESSION_PARTS` (layout boxes, call ids, 92 parts) | app.js 203–~3047 | ~2,800 lines |
| `parent_color_groups` / `child_color_groups` | app.js 3140–3260 | 6 + 67 |
| `WEBUI_CONFIG` constants | app.js 26–202 | ~30 leaf values |
| Default faces | `data/resources/saved_faces.json` | 11 faces |
| ark12 bitmap font | `data/resources/fonts/ark12.json` | 2.5 MB, 24,408 glyphs + emoji |
| Board photo, loader icons | `data/resources/pictures`, `loading` | 3 PNG |

## G. Packed frame (M370)

47 bytes = 370 bits, logical LED index, LSB-first in each byte: LED *i* → byte `i>>3`,
mask `1<<(i&7)`; top 6 bits of byte 46 must be zero. Encodings: raw binary (RinaLink),
94 hex chars, 47-int JSON array (`saved_faces.json`). Colour and brightness are global.

### Notes for the port (verified 2026-09-11)
- Each part's `strip_indices` are **physical** serpentine LED positions; convert through `physical_to_logical_index` before setting frame bits (LSB-first). All 92 parts' precomputed `frame` fields match under that rule; a naive pack mismatches 54 of 92.
- Extracted resources live in `ios/RinaBoard/Resources/` (see its README); regenerate with `tools/extract_webui_assets.py`.
- Brightness presets: 10, 25, 50, 80, 128, 160, 200.
