# RinaLink v1 — transport-agnostic control protocol (BLE + TCP)

Status: **v1 — implemented in firmware `rinalink-2.0.0`** — supersedes the HTTP/REST WebUI API (`/api/*`).
The firmware no longer serves any web content. One binary message format is carried
over three transports; the iOS app picks the transport, the firmware dispatches every
message through one `protocol.cpp` command handler.

## 1. Transports

| Transport | Carrier | Discovery | Notes |
|---|---|---|---|
| **BLE** | GATT service, 2 characteristics | BLE scan, service UUID filter | Always on. Used for first-time Wi-Fi provisioning, and can carry *all* features (slower for big uploads). |
| **Wi-Fi STA** | TCP :5370 on the user's LAN | mDNS/Bonjour `_rinalink._tcp.local`, host `rinaboard.local`; manual IP fallback | Board joins the router with credentials provisioned over BLE. |
| **Wi-Fi hotspot ("direct")** | TCP :5370 on board SoftAP `RinaChanBoard-V2`, board IP `192.168.1.14` | Fixed IP; iOS joins via `NEHotspotConfiguration` | No router needed. iOS does not expose Wi-Fi Direct/P2P to apps, so the board's SoftAP *is* the direct link. |

Wi-Fi run mode is persisted in NVS: `off | ap | sta | sta_or_ap` (default `ap` until
credentials exist, then `sta_or_ap`: try STA for 15 s, fall back to AP). BLE is
independent and always advertising when no BLE central is connected.

### 1.1 BLE GATT layout

- Service UUID `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`-style custom: **`52494E41-0001-4C49-4E4B-000000000001`** (`"RINA"…"LINK"`).
- `RX`  (`…0002`): write / write-without-response. Central → board. Carries framed messages, split into ≤ (ATT_MTU−3) byte slices; slices are concatenated in order.
- `TX`  (`…0003`): notify. Board → central. Same framing + slicing.
- `INFO`(`…0004`): read. UTF-8 JSON `{ "proto":1, "device":"RinaChanBoard", "fw":"<ver>", "mtu":<n>, "tcpPort":5370 }`. No `wifi` object here — use `CMD wifi_status` (§4) for Wi-Fi state.
- Advertised local name: `RinaBoard-XXXX` (last 2 MAC bytes). Requests MTU 247+ (NimBLE default 255).
- One central at a time. TCP and BLE may be connected simultaneously; the firmware is the single source of truth and pushes events to every connected client.

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

Maximum payload 4096 B. Larger bodies (saved-faces JSON, scroll frame sets) go through
the **blob** messages (§3.3), which are chunked by design and acked per chunk so BLE
flow control is implicit. Replies always carry the request's `type | 0x80` and `seq`.
A single reply whose serialized JSON exceeds 4096 B (e.g. `GET_SCROLL_META` with a
large `sourceText`) is split across multiple frames of the same `type | 0x80` and
`seq`, with the MORE flag (bit0) set on every frame but the last; clients must
concatenate payloads across MORE-flagged frames before parsing.
Errors reply with type `0xFF` and JSON `{"ok":false,"error":"...","code":<int>}`
(codes mirror the old HTTP statuses: 400 bad request, 404, 409 conflict, 413 too
large, 500, 507 no memory).

## 3. Message types

### 3.1 Control (JSON payloads, UTF-8)

| type | name | request payload | reply payload |
|---|---|---|---|
| 0x01 | `CMD` | `{"cmd":"…", …fields}` — exact same command set as the old `/api/command` (§3.4) | same JSON as the old `reply()` object |
| 0x02 | `GET_STATUS` | `{}` or `{"lite":true}` | old `/api/status` JSON (full) or the `renderer`+`power` subset when `lite` |
| 0x03 | `GET_POWER` | — | old `/api/power` JSON |
| 0x04 | `GET_SCROLL_META` | — | old `/api/scroll/meta` JSON |
| 0x05 | `GET_PREVIEW_SYNC` | — | old `/api/preview_sync` JSON (also pushed as event 0x90; the pull form exists for BLE clients that disable notifications) |
| 0x06 | `PING` | — | `{"ok":true,"uptimeMs":n}` |

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

Limits unchanged: ≤ 3072 scroll frames, `sourceText` ≤ 4096 B, ≤ 128 faces.
`chunkMax` is 4032 B (= 85 frames·47 B + slack) on TCP, `min(2048, 8·(MTU−3))` on BLE.
A second `BLOB_BEGIN{"kind":"scroll"}` from another client while one scroll upload
is already in progress is rejected with `0xFF ERR code:409`.

### 3.4 `CMD` command set (unchanged from `/api/command`)

`set_color{hex}`, `set_brightness{raw}`, `set_mode{mode}`, `set_auto_interval{ms}`,
`set_scroll_interval{intervalMs|fps}`, `start_scroll{intervalMs|fps,sourceText?}`,
`scroll_step{direction}`, `pause_scroll`, `resume_scroll`, `stop_scroll{restoreAuto?,clear?}`,
`pause`, `resume`, `apply_saved_face{index,reason?,playback?}`, `button{button}`,
`terminate_other_activities{targetMode?}`, `reset_battery_min`, `reset_battery_max`,
`battery_overlay{singleShot?}` — plus new device commands:
`reboot`, `get_info` (fw/build/led backend/heap/psram), `wifi_*` (§4).

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

## 4. Wi-Fi provisioning & management (`CMD wifi_*`, normally over BLE)

| cmd | payload | reply |
|---|---|---|
| `wifi_status` | — | `{"ok":true,"mode":"off|ap|sta|sta_or_ap","staConnected":bool,"ssid":"…","ip":"…","rssi":n,"apActive":bool,"apSsid":"RinaChanBoard-V2","apIp":"192.168.1.14","hostname":"rinaboard","tcpPort":5370,"clients":n}` |
| `wifi_scan` | — | async: `{"ok":true,"scanning":true}` immediately (or `500` if a scan could not be started); the result (≤ 20 networks, sorted by RSSI) arrives as `EV_WIFI_SCAN` (§3.5) when the scan completes. If a scan is already in progress, replies `{"ok":true,"scanning":true}` and the caller becomes the new requester for the in-flight scan's `EV_WIFI_SCAN`. |
| `wifi_scan_result` | — | `{"ok":true,"scanning":bool,"networks":[…]}` — the last completed scan's results (or empty if none yet), without starting a new scan |
| `wifi_set_credentials` | `{"ssid":"…","password":"…"}` | `{"ok":true}` — stored in NVS namespace `rinawifi` |
| `wifi_clear_credentials` | — | `{"ok":true}` |
| `wifi_set_mode` | `{"mode":"off|ap|sta|sta_or_ap"}` | `{"ok":true}` — persisted; applied immediately |
| `wifi_connect` | — | `{"ok":true}`; result arrives as `EV_WIFI` |
| `wifi_set_ap` | `{"ssid":"…","password":"…"|""}` | `{"ok":true}` — SoftAP name/password (default `RinaChanBoard-V2` / `rinachan`; open when empty) |

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
hot reload → faces `gen`++), and reply `{ok, v, gen, count}`; errors 400/404/409/500.
| cmd | payload | rule |
|---|---|---|
| `face_rename` | `{id, name}` | name ≤ 64 chars |
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
