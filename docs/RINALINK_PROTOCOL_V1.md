# RinaLink v1 — transport-agnostic control protocol (BLE + TCP)

Status: **v1 — implemented in firmware `rinalink-2.0.0`** — supersedes the HTTP/REST WebUI API (`/api/*`).
The firmware no longer serves any web content. One binary message format is carried
over three transports; the iOS app picks the transport, the firmware dispatches every
message through one `protocol.cpp` command handler.

## 1. Transports

| Transport | Carrier | Discovery | Notes |
|---|---|---|---|
| **BLE** | GATT service, 2 characteristics | BLE scan, service UUID filter | Always on. Used for first-time Wi-Fi provisioning, and can carry *all* features (slower for big uploads). |
| **Wi-Fi STA** | TCP :5370 on the user's LAN | mDNS/Bonjour `_rinalink._tcp.local`, host `rinaboard-<id>.local`, Bonjour instance `RinaBoard-<ID>`; manual IP fallback | Board joins the router with credentials provisioned over BLE. |
| **Wi-Fi hotspot ("direct")** | TCP :5370 on board SoftAP `RinaChanBoard-<ID>`, board IP `192.168.1.14` | Fixed IP; iOS joins via `NEHotspotConfiguration` | No router needed. iOS does not expose Wi-Fi Direct/P2P to apps, so the board's SoftAP *is* the direct link. |

Wi-Fi run mode is persisted in NVS: `off | ap | sta | sta_or_ap` (default `ap` until
credentials exist, then `sta_or_ap`: try STA for 15 s, fall back to AP). BLE is
independent and always advertising when no BLE central is connected.

**Board identity.** `<ID>` is 12 uppercase hex characters of the board's
Bluetooth MAC address (e.g. `80B54EF48E09`), computed once at boot and used
identically everywhere a board must be uniquely identified: the default BLE
name (`RinaBoard-<ID>`), `INFO.boardId` and `wifi_status.boardId` (§1.1, §4),
the SoftAP SSID (`RinaChanBoard-<ID>`), the mDNS hostname (lowercased,
`rinaboard-<id>.local`), and the Bonjour instance name (`RinaBoard-<ID>`).
This guarantees two boards can never be confused by the app. A previously
stored SoftAP SSID equal to the retired shared default `RinaChanBoard-V2`
migrates automatically to the board's unique default on the next boot.

### 1.1 BLE GATT layout

- Service UUID `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`-style custom: **`52494E41-0001-4C49-4E4B-000000000001`** (`"RINA"…"LINK"`).
- `RX`  (`…0002`): write / write-without-response. Central → board. Carries framed messages, split into ≤ (ATT_MTU−3) byte slices; slices are concatenated in order.
- `TX`  (`…0003`): notify. Board → central. Same framing + slicing.
- `INFO`(`…0004`): read. UTF-8 JSON `{ "proto":1, "device":"RinaChanBoard", "name":"<advertised name>", "fw":"<ver>", "mtu":<n>, "tcpPort":5370, "boardId":"<12 hex>" }`. No `wifi` object here — use `CMD wifi_status` (§4) for Wi-Fi state.
- **Advertised local name.** Default `RinaBoard-AABBCCDDEEFF`, using all six
  bytes of the factory BT MAC in uppercase hex, giving each ESP32 a stable
  identity without collisions from a shortened MAC suffix. Overridable at runtime with
  `CMD set_device_name` (§3.4); max **24 UTF-8 bytes** (`MAX_DEVICE_NAME_BYTES`),
  persisted in `runtime_settings.json`.
- **Advertising payload split (load-bearing).** The name is carried in the
  **scan response**, not the primary advertisement. A legacy advertisement is
  capped at 31 bytes, and flags (3) + the 128-bit service UUID (2 + 16 = 18)
  already costs 21; a 14-byte name needs another 16, for 37. NimBLE's
  `NimBLEAdvertisementData::addData()` rejects the overflowing field and returns
  false *without* failing `start()`, so the board would advertise the UUID and
  **no name at all** — every board then shows up unnamed and identical in the
  app. Keep the UUID in the advertisement (centrals scan by it) and the name in
  the scan response; iOS merges the two into
  `CBAdvertisementDataLocalNameKey`. Verified on hardware: with both in the
  primary payload the firmware logs `nameSet=0`.
- Requests MTU 247+ (NimBLE default 255).
- One central at a time. TCP and BLE may be connected simultaneously; the firmware is the single source of truth and pushes events to every connected client.
- A new BLE link must send a complete framed request within 15 seconds;
  enabling TX notifications alone does not complete initialization. Otherwise
  the firmware disconnects it and resumes
  advertising. Initialized BLE links have no idle timeout. Failed advertising
  starts are retried after 250 ms. Disabling TX notifications after enabling
  them releases the link so the board can advertise again.
- Clients should enable TX notifications and verify a `PING` reply before
  reporting the board ready. On service discovery, notification setup, or
  handshake failure, cancel the physical BLE connection before retrying.
  A terminal reply-notification failure also closes the firmware connection,
  including failures before the first byte was sent.
- The firmware sends no events over BLE until the client has enabled TX
  notifications. Status, preview, power, and Wi-Fi state remain pending after a
  failed send and retry; intermediate states may be coalesced. Logs are transient.
  Replies are always sent. Read state explicitly after subscribing
  (`GET_STATUS` / `GET_FRAME` / `GET_PREVIEW_SYNC`) rather than waiting for a
  first event. Pushing events during service discovery starved the central's
  GATT procedures and broke reconnects after an app force-quit.

### 1.2 TCP framing

Plain TCP, same message framing as BLE, no slicing needed. Keep-alive: client sends
`PING` every 5 s if idle; firmware drops a socket idle for 20 s. Max 2 TCP clients.

## 2. Message framing (identical on both transports)

```
offset  size  field
0       1     magic      0xA5
1       1     type       message type (§3)
2       1     seq        request sequence id (client-chosen, echoed in the reply; events use 0)
3       1     flags      bit0 = MORE (reply continues in the next message of the same seq/type)
4       2     length     payload length, little-endian, 0..4096
6       n     payload
```

Maximum payload 4096 B, measured after JSON/UTF-8 encoding, including every field,
quote, separator, and escape. Clients must reject an oversized encoded request
before writing any bytes. Larger bodies (saved-faces JSON, scroll frame sets) go through
the **blob** messages (§3.3), which are chunked by design and acked per chunk so BLE
flow control is implicit. Replies always carry the request's `type | 0x80` and `seq`.
A single reply whose serialized JSON exceeds 4096 B (e.g. `GET_SCROLL_META` with a
large `sourceText`) is split across multiple frames of the same `type | 0x80` and
`seq`, with the MORE flag (bit0) set on every frame but the last; clients must
concatenate payloads across MORE-flagged frames before parsing.
Errors reply with type `0xFF` and JSON `{"ok":false,"error":"...","code":<int>}`
(codes mirror the old HTTP statuses: 400 bad request, 404, 409 conflict, 413 too
large, 500, 507 no memory).

Both transports carry a byte stream: a successful send must deliver the complete
frame, or close the carrier on a partial write. After a valid header, payload bytes
may contain `0xA5`, so a truncated payload followed immediately by another frame
cannot be distinguished from a single fragmented frame. Do not scan that payload
for apparent new packets; recover at a timeout or a new carrier connection.
The firmware attempts to reply ERR 413 with the request's own sequence to a
header declaring a payload larger than 4096 B and closes that carrier; clients
may observe the close without the reply. A BLE write that does not fit the
inbound buffer also closes the carrier.

Sequence 0 is reserved for events. The 255 request sequence IDs must not be shared
by outstanding requests; clients must report busy when none is available. Replies
must match both the expected type and the sequence. In particular, `SET_FRAME` and
`GET_FRAME` replies share type values with events, so type alone is insufficient.
RinaLink v1 carries no session nonce: a delayed same-type reply is indistinguishable
after its sequence is reused. Carrier teardown and rejection of callbacks from old
connections are part of recovery, not a substitute for a wire-level session ID.

## 3. Message types

### 3.1 Control (JSON payloads, UTF-8)

| type | name | request payload | reply payload |
|---|---|---|---|
| 0x01 | `CMD` | `{"cmd":"…", …fields}` — exact same command set as the old `/api/command` (§3.4) | same JSON as the old `reply()` object |
| 0x02 | `GET_STATUS` | `{}` or `{"lite":true}` | old `/api/status` JSON (full) or the `renderer`+`power` subset when `lite` |
| 0x03 | `GET_POWER` | — | old `/api/power` JSON |
| 0x04 | `GET_SCROLL_META` | — | scroll source/timeline metadata plus the current cursor, active/pause flags, and `scrollLoop` |
| 0x05 | `GET_PREVIEW_SYNC` | — | lightweight actually-presented frame telemetry (also pushed as event 0x90; the pull form exists for reconnect anchoring and BLE clients that disable notifications) |
| 0x06 | `PING` | — | `{"ok":true,"uptimeMs":n}` |

`GET_SCROLL_META` includes `firmwareScrollUserPaused`,
`firmwareScrollSystemPaused`, and `scrollLoop` in addition to the historical
scroll-meta fields. Its `frameIndex` is the current firmware cursor sampled
atomically with those flags; clients that need the last frame physically latched
by the LEDs use `GET_PREVIEW_SYNC` after restoring/rasterizing the source text.

`GET_PREVIEW_SYNC` includes `scrollAdvanceSeq`, `presentedAtUs`, and
`sampledAtUs`. `scrollAdvanceSeq` is a boot-lifetime unsigned 32-bit sequence
that advances only when an automatic `scroll_tick` context reaches a successful
LED latch. Compute its delta with modulo-2^32 unsigned subtraction after checking
the timeline identity; unlike the ring frame index, it still counts multiple
complete wraps between samples. `presentedAtUs` and `sampledAtUs` are unsigned
64-bit microseconds from the same ESP monotonic boot clock, so
`sampledAtUs - presentedAtUs` is the age of the presented position when the
reply was assembled. `presentedSeq` still counts every valid presentation,
including starts, seeks, and manual frames, and must not be used as a scroll
advance count. The active/pause flags and `scrollLoop` are freshly sampled
control state; presentation identity and timing remain tied to the last
successful LED latch.

`GET_STATUS.version` is a runtime state-change counter, not the protocol version.
Use `CMD get_info`'s `proto` (or BLE INFO's `proto`) for the protocol version.
Lite status replies and `EV_STATUS` omit full-snapshot fields; clients merge them
into the current connection's snapshot rather than clearing omitted fields.

The `GET_STATUS.renderer` object and `GET_PREVIEW_SYNC` also expose the current
`outputMode` (`control`, `text`, `lipSync`, `performance`, or `video`),
`outputStreamID`, and `outputPositionMs`. Unlike `lastReason`, this ownership
metadata survives brightness/colour changes and link loss. Native face/mode
takeovers and firmware scrolling replace it, so a reconnecting app must read
the board before restoring local playback. The fields are optional for clients
supporting older firmware and reset when the board restarts.

Phone-driven streams attach `<reason>:<UUID>:<positionMs>` to `SET_FRAME`:
`lipsync`, `live_preset`, and `video` are the supported reason prefixes. The
position is the media offset of that frame (zero for microphone input), not a
clock that advances while the phone is disconnected. The phone retains the
same UUID when restoring that stream and only resumes matching local material.
The board does not store audio or video files. Legacy unqualified frame reasons
remain supported, but cannot identify the original media across clients.

### 3.2 Frames (binary payloads)

| type | name | request payload | reply |
|---|---|---|---|
| 0x10 | `SET_FRAME` | `u8 playback` (0 idle, 1 paused, 2 scroll, 3 auto) · `u8 reasonLen` · `reason[reasonLen]` · `47 B packed frame` | JSON: old `/api/frame` POST reply |
| 0x11 | `GET_FRAME` | — | `47 B` current frame (binary) |

Packed frame: 47 bytes = 370 bits, logical LED index, LSB-first per byte, tail bits
zero (validated exactly as `validatePackedFrame`). Reasons prefixed `custom_` /
`parts_` / `debug_` force mode→manual (not persisted), unchanged from HTTP.

### 3.3 Blob upload / download (chunked, acked)

Used for **scroll frame sets** and **saved-faces JSON**.

| type | name | request payload | reply |
|---|---|---|---|
| 0x20 | `BLOB_BEGIN` | JSON `{"kind":"scroll"|"faces","totalBytes":n, …meta}` — scroll meta = `{append,intervalMs|fps,totalFrames,timelineId,fontId,generatorVersion}` (same semantics as old `/api/scroll` query args) | `{"ok":true,"chunkMax":<bytes>,"offset":<resume offset>}` |
| 0x21 | `BLOB_CHUNK` | `u32 offset LE` · bytes (for `scroll` the chunk must be a whole number of 47-byte frames) | `{"ok":true,"offset":<next>,"frames":<count so far>}` |
| 0x22 | `BLOB_END` | JSON `{"start":bool}` (scroll) / `{}` (faces) | scroll: old `/api/scroll` 200 JSON; faces: `{"ok":true,"v":n,"bytes":n}` after validate + atomic write + hot reload |
| 0x23 | `BLOB_ABORT` | — | `{"ok":true}` |
| 0x24 | `GET_FACES` | `{"offset":n,"gen"?:n}` | `u32 gen LE` · raw `saved_faces.json` bytes from `offset`, MORE flag set while more remain; last message has MORE=0 |

`BLOB_BEGIN`'s reply `offset` is always 0 — it never resumes a prior session (a
fresh upload always starts at offset 0). `GET_FACES` replies are prefixed with the
current `saved_faces.json` generation counter; if the request includes `gen` and it
no longer matches (the file changed mid-transfer), the board replies `0xFF ERR`
with `code:409` instead of a data frame, so a multi-chunk download never silently
splices together two different documents.

Limits: ≤ 3072 scroll frames, stored `sourceText` ≤ 4096 UTF-8 bytes,
≤ 128 faces, and saved-face JSON ≤ 256 KiB. The complete `CMD` or `BLOB_BEGIN`
metadata must also fit the 4096-byte payload limit. Thus a text string at the
storage limit cannot necessarily be sent: for example, the
`{"cmd":"start_scroll","sourceText":"…","intervalMs":100}` wrapper leaves
4041 bytes for unescaped text, and additional fields or JSON escapes reduce that
space. `face_reorder` likewise must fit as a complete JSON request, even for a
library within the face-count limit.
`chunkMax` is 4032 B (= 85 frames·47 B + slack) on TCP, `min(2048, 8·(MTU−3))` on BLE.
A second `BLOB_BEGIN{"kind":"scroll"}` from another client while one scroll upload
is already in progress is rejected with `0xFF ERR code:409`.
Raw scroll uploads stage their bytes separately from the active timeline; the
new timeline is committed at END. Abort or disconnection before END leaves the
previous timeline intact, as with bitmap uploads.

### 3.4 `CMD` command set (unchanged from `/api/command`)

`set_color{hex}`, `set_brightness{raw}`, `set_mode{mode}`, `set_auto_interval{ms}`,
`set_scroll_interval{intervalMs|fps}`, `start_scroll{intervalMs|fps,sourceText?,loop?}`
(here and in scroll `BLOB_BEGIN` meta, an explicit `intervalMs` wins; `fps` alone
sets the interval to `round(1000/fps)`, and only a request with neither keeps the
current interval — clients should send both),
`scroll_step{direction}`, `scroll_seek{frameIndex}`, `set_scroll_loop{loop}`,
`pause_scroll`, `resume_scroll`, `stop_scroll{restoreAuto?,clear?}`,
`pause`, `resume`, `apply_saved_face{index,reason?,playback?}`, `button{button}`,
`terminate_other_activities{targetMode?}`, `reset_battery_min`, `reset_battery_max`,
`battery_overlay{singleShot?}` — plus new device commands:
`reboot`, `get_info` (fw/build/led backend/heap/psram/name), `set_device_name{name}`,
`wifi_*` (§4).

**`scroll_seek{frameIndex}`** — jumps the loaded scroll timeline to an absolute
frame, clamped to `0…frameCount−1`, and presents it immediately. A playing
scroll keeps playing from there, holding the new frame for one full interval. A
paused one stays paused. With no active session it latches paused on that frame,
the same as `scroll_step`. The presented sample carries `source:"scroll_step"`, so
clients snap to it instead of phase-correcting. Does nothing when no timeline
is loaded.

**`set_scroll_loop{loop}`** — enables or disables looping of the current/next
scroll timeline; default is `true`. It is a RAM-only preference that survives
uploads and `stop_scroll`/`start_scroll` (not persisted across reboot).
`start_scroll` accepts an optional `loop` field that sets it in the same call.
With loop off, the scroll advances normally but holds on its last frame instead
of wrapping to frame 0: it goes into a paused state (`firmwareScrollPaused:true`,
status `playback:"scroll_paused"`), with the current `scrollLoop` value reported
in status. Calling `resume_scroll` or `resume` while sitting on the last frame
with loop off restarts playback from frame 0.

**`set_device_name{name}`** — sets the BLE advertised local name (§1.1). An
empty or omitted `name` clears the override and restores the MAC-derived
default. Limit is **24 UTF-8 bytes**, not characters (≈8 CJK characters); the
board rejects anything longer, or not valid UTF-8, with `ERR 400`. Takes effect
immediately — the firmware re-advertises without a reboot — and is persisted to
`runtime_settings.json`.

Reply: `{ "ok":true, "name":"<effective>", "customName":<bool>, "persisted":<bool> }`.
`persisted:false` means the name is live over BLE but the flash write failed, so
it will not survive a reboot — surface that rather than reporting plain success.

`get_info` additionally reports `name` (current advertised name), `defaultName`
(the MAC-derived fallback) and `customName` (whether an override is set).

### 3.5 Events (board → client, `seq`=0, unsolicited)

| type | name | payload | cadence |
|---|---|---|---|
| 0x90 | `EV_PREVIEW_SYNC` | old `/api/preview_sync` JSON | on every presented-frame change, rate-limited to 10 Hz (TCP) / 4 Hz (BLE) |
| 0x91 | `EV_STATUS` | `GET_STATUS lite` JSON | whenever `stateVersion` changes, ≤ 5 Hz |
| 0x92 | `EV_POWER` | `/api/power` JSON | 1 Hz, or immediately on charging-state change |
| 0x93 | `EV_WIFI` | §4 status JSON | on Wi-Fi state change |
| 0x94 | `EV_LOG` | `{"level":"I","tag":"…","msg":"…"}` | only after `CMD log_subscribe{on:true}`; replaces the debug page's log viewer |
| 0x95 | `EV_WIFI_SCAN` | `{"ok":true,"networks":[{"ssid","rssi","secure":bool}]}` | sent once when an async `wifi_scan` (§4) completes; delivered to the requesting client, or to all connected clients if the requester has since disconnected |

Clients enable/disable event classes with `CMD subscribe{preview:bool,status:bool,power:bool,log:bool}`; defaults: preview+status+power on, log off.

`/api/power` / `EV_POWER` also report the auto-learned battery calibration:
`battCalibMaxV`, `battCalibCutoffV` (span the LUT is normalized to), `battCalibMaxLearned`,
`battCalibCutoffLearned` (whether each was learned vs. still default), and
`batteryAdcSaturated` (true when the last battery ADC reading is at/near the ADC ceiling).

## 4. Wi-Fi provisioning & management (`CMD wifi_*`, normally over BLE)

| cmd | payload | reply |
|---|---|---|
| `wifi_status` | — | `{"ok":true,"mode":"off|ap|sta|sta_or_ap","staConnected":bool,"ssid":"…","ip":"…","rssi":n,"apActive":bool,"apSsid":"RinaChanBoard-80B54EF48E09","apIp":"192.168.1.14","hostname":"rinaboard-80b54ef48e09","boardId":"80B54EF48E09","tcpPort":5370,"clients":n}` |
| `wifi_scan` | — | async: `{"ok":true,"scanning":true}` immediately (or `500` if a scan could not be started); the result (≤ 20 networks, sorted by RSSI) arrives as `EV_WIFI_SCAN` (§3.5) when the scan completes. If a scan is already in progress, replies `{"ok":true,"scanning":true}` and the caller becomes the new requester for the in-flight scan's `EV_WIFI_SCAN`. |
| `wifi_scan_result` | — | `{"ok":true,"scanning":bool,"networks":[…]}` — the last completed scan's results (or empty if none yet), without starting a new scan |
| `wifi_set_credentials` | `{"ssid":"…","password":"…"}` | `{"ok":true}` — stored in NVS namespace `rinawifi` |
| `wifi_clear_credentials` | — | `{"ok":true}` |
| `wifi_set_mode` | `{"mode":"off|ap|sta|sta_or_ap"}` | `{"ok":true}` — persisted; applied immediately |
| `wifi_connect` | — | `{"ok":true}`; result arrives as `EV_WIFI` |
| `wifi_set_ap` | `{"ssid":"…","password":"…"|""}` | `{"ok":true}` — SoftAP name/password (default `RinaChanBoard-<ID>` / `rinachan`; open when empty; sending the retired shared SSID `RinaChanBoard-V2` resets to the board's unique default) |

Flow in the app: BLE connect → `wifi_scan` → `wifi_set_credentials` →
`wifi_set_mode sta_or_ap` → wait `EV_WIFI staConnected` → app switches to TCP via
Bonjour or the reported `ip`. "Hotspot" flow: `wifi_set_mode ap` (or the default) →
app joins the SoftAP → TCP `192.168.1.14:5370`.

## 5. Firmware layout after the refactor

```
src/protocol.h/.cpp        one dispatcher: decode frame → handler → encode reply/events
src/transport.h            ITransport (send(bytes), onReceive callback), client registry, event fan-out
src/transport_ble.cpp      NimBLE service/characteristics, MTU slicing/reassembly
src/transport_tcp.cpp      WiFiServer :5370, 2 clients, idle timeout, mDNS
src/wifi_manager.h/.cpp    NVS creds + mode, STA/AP/APSTA state machine, scan, EV_WIFI
(blob sessions live inside protocol.cpp as `BlobSession`, one per client)
```
Removed: `web_api.*`, `data/index.html|app.js|styles.css`, `data/resources/fonts/*`,
`data/resources/loading|pictures`, `scripts/gzip_webui_assets.py`,
`scripts/patch_webserver_timeout.py`, `HTTP_MAX_*` flags, `RINACHAN_AP_ONLY`.
Kept on LittleFS: `resources/saved_faces.json`, `runtime_settings.json`, `battery_calib.json`.
Partition table changes: app0 grows to 4 MB (BLE+Wi-Fi image), LittleFS shrinks to the remainder.

## 6. What moves into the iOS app

- Scroll-text rasterizer (ark12 bitmap font → 22×18 frames), previously in `app.js`; `ark12.json` ships in the app bundle.
- Parts library (`EXPRESSION_PARTS`), LED coordinate map, color presets, default face rendering.
- Preview PLL / speed lock, timeline UI, all editors.

## 7. v1.1 additions — streaming optimisations and the Wi-Fi setup page

### 7.1 `BLOB kind:"scroll_bitmap"` (replaces per-frame scroll uploads)
Scroll frames are 1-px horizontal shifts of one 18-row bitmap, so the client sends the
**bitmap** and the firmware expands it. Upload size drops from `frameCount × 47 B`
(15 KB for the default text, up to 144 KB) to `18 × ceil(width/8)` bytes (< 1 KB typical).

- `BLOB_BEGIN` meta: `{"kind":"scroll_bitmap","width":W (22…3093),"rows":18,"totalBytes":18*stride,
  "intervalMs"|"fps", "timelineId","fontId","generatorVersion","sourceText"?}`.
  `stride = ceil(W/8)`. Reply `{ok, chunkMax, offset:0}`.
  Width outside 22…3093 is rejected at BEGIN with 400 (including 3094).
  The separate computed-frame-count guard returns 413 when more than 3072
  frames would be produced; it does not override width validation.
- `BLOB_CHUNK`: raw bitmap bytes, row-major, row `y` occupies bytes `[y*stride, (y+1)*stride)`,
  pixel `x` of row `y` = bit `(x & 7)` (LSB-first) of byte `y*stride + (x >> 3)`.
- `BLOB_END {"start":bool}`: firmware computes `frameCount = max(1, W-22) + 1` (→ 413 if
  > 3072), expands every offset into a packed frame through the LED index map (cells
  whose `offset + x ≥ W` are off), **rotates** the timeline so index 0 is the first frame
  with any lit LED (no rotation when nothing is lit), writes the frames into the scroll
  buffer, commits, optionally starts. Reply = the `scroll` END reply plus
  `"width":W, "rotation":r` (r = number of leading dark frames moved to the end). The
  client must apply the identical rotation to its local preview timeline; a mismatch is
  treated like a timeline identity mismatch.
- The old `kind:"scroll"` (raw frames) stays supported for arbitrary frame sequences.

### 7.2 Incremental saved-face commands (replace whole-document re-uploads)
All operate on `saved_faces.json` on the board (read → modify → validate → atomic write →
hot reload → faces `gen`++), and reply `{ok, v, gen, count}`; errors 400/404/409/413/500.
Names in rename/upsert requests must be 1–64 UTF-8 bytes.
Edits that would exceed the 256 KiB serialized document limit fail before replacing
the current file. A partial write never replaces the previous valid file.
| cmd | payload | rule |
|---|---|---|
| `face_rename` | `{id, name}` | name ≤ 64 UTF-8 bytes |
| `face_reorder` | `{ids:[…]}` | must list every face exactly once; assigns `order` 1…n |
| `face_delete` | `{id}` | 400 for `type:"default"` or when it would remove the last default |
| `face_upsert` | `{face:{id?, name, type:"custom"|"parts", frameHex (94 hex) or frameBytes[47], call?}}` | new id → appended with `order = max+1`, `savedAt` set; existing id → frame/name/call/type replaced, `updatedAt` set; defaults cannot be overwritten |
| `faces_clear_user` | — | deletes every non-default face |
`GET_FACES` (with `gen`) remains the bulk download; `BLOB kind:"faces"` remains for import.

### 7.3 Wi-Fi setup page (the only web UI left)
A ~10 KB single page embedded in flash (PROGMEM, no LittleFS assets), served on
`http://<board-ip>/` (port 80) whenever Wi-Fi is up; in hotspot mode the captive DNS maps
`rina.io` to the board so `http://rina.io/` works. It exists so a phone or laptop without
the app can put the board on a network. It exposes only:
`GET /api/wifi/status`, `POST /api/wifi/scan` (starts an async scan → `{scanning:true}`),
`GET /api/wifi/scan` (last result), `POST /api/wifi/credentials {ssid,password}` (stores
them, sets mode `sta_or_ap`, connects), `POST /api/wifi/mode {mode}`,
`POST /api/wifi/ap {ssid,password}`. Nothing else (no frames, faces or commands) is
reachable over HTTP. All handlers run in `loop()` and delegate to the Wi-Fi manager.

## 8. v1.2 — iPhone Personal Hotspot profile (auto-connect when no Wi-Fi is around)

The board keeps **two** station credential sets in NVS: `home` (router) and `hotspot`
(the phone's Personal Hotspot). Whenever it needs a station link it runs a scan and joins
the first configured network that is visible, preferring `home`; if neither is visible it
falls back to its own SoftAP (`sta_or_ap`) and re-scans every 60 s. This lets the board
follow the phone anywhere: at home it uses the router, outdoors it joins the phone.

iOS cannot read the Personal Hotspot password, and the hotspot name is only available as
the device name, so the app pre-fills the name, asks for the password once, stores it in
the Keychain, and provisions the board over BLE.

| cmd | payload | reply |
|---|---|---|
| `wifi_set_hotspot_credentials` | `{ssid, password}` | `{ok}` — stored under NVS keys `hssid`/`hpass` |
| `wifi_clear_hotspot_credentials` | — | `{ok}` |
| `wifi_status` | — | gains `homeSsid`, `hotspotSsid` (names only, never passwords), `activeProfile: "home"|"hotspot"|"none"`, `scanPending: bool` |

Selection algorithm (`wifi_manager`): on every STA attempt → async scan (≤3 s) → if
`homeSsid` visible join it; else if `hotspotSsid` visible join it; else (mode `sta_or_ap`)
keep/raise the SoftAP and retry the scan every `WIFI_STA_RETRY_MS`. A profile that fails
to associate 3 times in a row is skipped for one retry cycle. `EV_WIFI` is pushed on every
transition and carries `activeProfile` and the station `ip`.

App flow ("iPhone 热点" section of the Connection tab): user turns on Personal Hotspot →
app (connected over BLE) sends `wifi_set_hotspot_credentials` + `wifi_set_mode sta_or_ap` +
`wifi_connect` → waits for `EV_WIFI staConnected && activeProfile=="hotspot"` → opens TCP
to the reported `ip` (the phone is the hotspot gateway, so the board is directly reachable;
Bonjour also works on the hotspot interface) and remembers `hotspot-tcp` as the preferred
transport for that board.
