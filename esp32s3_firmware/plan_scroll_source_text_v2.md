# Text Scroll 6.4 — Source-Text Sync Plan v2 (audit-corrected)

Core model unchanged from v1: WebUI uploads generated M370 frames **plus** the Unicode
source text + generation metadata; firmware stores both in RAM; WebUI rebuilds its
preview locally from text; firmware never sends frames/bitmaps back; only frameIndex
is synced during playback.

This v2 fixes the audit findings: sourceText must not gate playback, no frame
regeneration at startup, no runtime sha256, firmware `\uXXXX` decoding gap, code-point
rule mismatch, wrong matrix dims, status payload bloat, undefined meta lifecycle,
missing lock contract, and pseudocode that referenced nonexistent functions.

---

## 0. Hard rules

```text
- sourceText is required ONLY for preview restore. Playback (start_scroll, pause,
  resume, step, stop) must keep working for frames-only uploads (backward compat
  with scripts / third-party API clients).
- No ark12.json fetch and no frame regeneration during WebUI startup. ark12.json is
  2.5 MB and stays lazy-loaded on page-6.4 entry (existing ensureScrollFontsLoaded).
  Startup restores only the text into #scroll-text.
- Identity = fontId + generatorVersion strings. No runtime hashing.
- Hard firmware text limit is BYTES (MAX_SCROLL_TEXT_BYTES). Code-point checks must
  match the WebUI rule (visible chars excluding emoji format controls) or be lenient.
- All new metadata fields live under the existing scrollMutex contract (state.h).
- Matrix dims are fixed 22x18 / 370 LEDs — not part of upload metadata.
```

---

## 1. Firmware changes

### 1.1 config.h

```cpp
constexpr uint16_t MAX_SCROLL_TEXT_BYTES        = 4096; // UTF-8 bytes, hard limit
constexpr uint16_t MAX_SCROLL_TEXT_CODEPOINTS   = 2048; // lenient raw-codepoint cap
constexpr uint8_t  MAX_SCROLL_TIMELINE_ID_CHARS = 47;
constexpr uint8_t  MAX_SCROLL_FONT_ID_CHARS     = 47;
constexpr uint8_t  MAX_SCROLL_GENERATOR_CHARS   = 47;
```

`MAX_SCROLL_TEXT_CODEPOINTS` is deliberately above the UI's 1000 visible-char limit:
the WebUI excludes VS15/16, ZWJ, skin tones, and tag chars from its count
(`truncateScrollText` / `isEmojiFormatControl`), so raw code points can exceed 1000
for valid input. Bytes are the real guard.

### 1.2 state.h — ScrollTimelineMeta

```cpp
struct ScrollTimelineMeta {
    char     timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
    char     fontId[MAX_SCROLL_FONT_ID_CHARS + 1]         = {0};
    char     generatorVersion[MAX_SCROLL_GENERATOR_CHARS + 1] = {0};
    uint16_t sourceTextByteLength   = 0;   // 0 == no source text stored
    uint16_t totalFramesExpected    = 0;   // from first chunk
    uint16_t framesReceived         = 0;
    uint16_t nextChunkIndex         = 0;   // strict sequencing
    uint8_t  uiFps                  = 0;   // echo-only, for input-field restore
    bool     uploadComplete         = false;
    bool     hasSourceText          = false;
};
```

- `sourceTextUtf8` buffer (`MAX_SCROLL_TEXT_BYTES + 1`) is NOT a static array in
  RuntimeState. Allocate it in `RuntimeStore::initScrollFrameBuffer()` alongside
  `scrollFrameBits_` (PSRAM-preferred, same pattern). Accessors:
  `runtimeScrollSourceText()` / `runtimeScrollMeta()`.
- Timing stays single-source-of-truth: `scrollIntervalMs` (existing field) is
  canonical; `uiFps` is stored only to restore the `#scroll-speed` input exactly.
- Lock contract (extend the comment block in state.h): ScrollTimelineMeta and the
  source-text buffer are guarded by `scrollMutex`, same as `firmwareScroll*` /
  `scrollFrame*`. Every read/write goes through `withScrollLock`.

### 1.3 web_json.cpp — fix `\uXXXX` decoding

`extractJsonStringAt()` currently drops the backslash on `\uXXXX` (default case),
corrupting text from any standards-escaping client. Add:

```text
case 'u':
  - read 4 hex digits -> code unit U1
  - if U1 is a high surrogate and next chars are "\uXXXX" low surrogate U2:
      combine to code point, consume both
  - if lone surrogate: substitute U+FFFD
  - append code point as UTF-8 bytes
  - on malformed hex: return false (caller sends 400)
```

This fix benefits every existing string field (`source`, `storage`, …), not just
sourceText.

### 1.4 utils — UTF-8 validator

`bool validateUtf8(const char* s, size_t len, uint16_t& codePoints)`:
rejects invalid sequences, overlong encodings, surrogates (U+D800–DFFF), and
> U+10FFFF. Returns raw code-point count.

### 1.5 /api/scroll upload handler (web_api.cpp)

Keep the existing manual frame streaming (no full-body ArduinoJson parse). Metadata
fields on the first chunk are read with the raw helpers (`jsonStringField`,
`jsonUintField`), which are safe after 1.3.

First chunk (`append:false`), in order:

```text
1. Read timelineId / sourceText / fontId / generatorVersion / fps / intervalMs /
   totalFrames from body.
2. Validate BEFORE touching current state:
   - timelineId present, length <= MAX_SCROLL_TIMELINE_ID_CHARS
   - if sourceText present:
       byte length <= MAX_SCROLL_TEXT_BYTES        -> else 413
       validateUtf8 passes                          -> else 400
       codePoints <= MAX_SCROLL_TEXT_CODEPOINTS     -> else 413
   - totalFrames <= MAX_SCROLL_FRAMES               -> else 413
3. stopFirmwareScroll(false) + clear frame counters (existing behavior).
4. withScrollLock: reset meta, store timelineId/fontId/generatorVersion/uiFps/
   sourceText, hasSourceText, totalFramesExpected, nextChunkIndex = 1,
   uploadComplete = false.
5. Stream/decode frames exactly as today.
6. framesReceived = count; if totalFrames>0 && framesReceived >= totalFrames:
   uploadComplete = true.
```

`sourceText` is OPTIONAL. A frames-only first chunk (no timelineId/sourceText) is
accepted exactly as today; meta is reset with `hasSourceText=false` and an empty
timelineId.

Append chunk (`append:true`):

```text
- if body has timelineId and it != meta.timelineId      -> 409 "timeline mismatch"
- if body has chunkIndex and it != meta.nextChunkIndex  -> 409 "chunk out of order"
  (distinct messages so the WebUI knows to restart from chunk 0 with append:false)
- decode frames as today; framesReceived += count; nextChunkIndex++
- when framesReceived >= totalFramesExpected (>0): uploadComplete = true
```

Auto-start (`shouldStart`) logic unchanged. Add `timelineId` and `uploadComplete`
to the reply JSON.

Failure/retry rule: any upload error leaves `uploadComplete=false`; recovery is
always a full re-Send (first chunk, `append:false`). No partial resume.

### 1.6 Metadata lifecycle

```text
created/replaced : first chunk of a new upload (append:false)
survives         : stop_scroll, pause/resume, GPIO button stop, /api/frame posts,
                   mode switches (frames stay cached today; meta follows frames)
cleared          : only by the next append:false upload (or reboot)
```

`scrollHasSourceText` in status stays true after stop so a refreshed WebUI can still
restore the text while frames are cached.

### 1.7 /api/status — keep it light

Extend `ScrollStateSnapshot` + `addScrollStateFields` (renderer object — this
automatically covers `/api/status` AND `/api/command` replies) with ONLY:

```text
scrollTimelineId       (string, "" if none)
scrollUploadComplete   (bool)
scrollHasSourceText    (bool)
```

No fontId / generatorVersion / text bytes / sourceText in status — those live in
`/api/scroll/meta` only. The snapshot is already taken under `withScrollLock`.

### 1.8 New endpoint GET /api/scroll/meta

- `PsramJsonDocument doc(8192)` (text can be 4 KB; ArduinoJson escapes on
  serialize, so stored UTF-8 round-trips correctly).
- Snapshot everything under one `withScrollLock` (incl. frameIndex), then serialize.
- Response:

```json
{
  "ok": true,
  "scrollTimelineId": "scroll-1710000000000-a3f9",
  "hasSourceText": true,
  "sourceText": "你好 Rina 🐯",
  "sourceTextBytes": 18,
  "fontId": "ark_pixel_12px_fusion_bitmap_v4",
  "generatorVersion": "webui-scrollgen-6.4.1",
  "uiFps": 20,
  "scrollIntervalMs": 50,
  "frameCount": 120,
  "frameIndex": 57,
  "uploadComplete": true,
  "firmwareScrollActive": true,
  "firmwareScrollPaused": false
}
```

- If no meta / frames: `{"ok":true,"hasSourceText":false,"scrollTimelineId":""}`.
- Register route + OPTIONS in `startWebServer()`.

### 1.9 commandStartScroll — backward compatible

```text
if payload has timelineId:
    must match meta.timelineId            -> else 409
    meta.uploadComplete must be true      -> else 409
always (existing): scrollFrameCount > 0 && buffer ready
NO sourceText requirement — playback never depends on text. (v1 §5 contradicted
its own §16 and broke frames-only clients.)
```

---

## 2. WebUI changes (data/app.js)

### 2.1 Constants

```js
const SCROLL_GENERATOR_VERSION = "webui-scrollgen-6.4.2";
// fontId = TEXT_SCROLL_FONT_MODEL (already "ark_pixel_12px_fusion_bitmap_v4").
// Rule: bump SCROLL_GENERATOR_VERSION whenever TEXT_SCROLL_CHAR_SPACING,
// leading/trailing blank margins, textScrollVerticalOffset(), or
// extractFrameFromTextImage logic changes. Bump fontModel when ark12.json changes.
```

### 2.2 scroll state additions

```js
scroll.timelineId = "";               // current local timeline
scroll.restoredFromFirmwareMeta = false;
scroll.restoreWarning = "";           // shown by updateScrollUi
// reset all three in resetScrollControlsAfterButton(), stopScroll(), and whenever
// a timeline mismatch is detected.
```

### 2.3 Upload (uploadFirmwareScrollTimeline)

- Generate `scroll.timelineId = `scroll-${Date.now()}-${rand4}`` at the start of
  each Send.
- First chunk only, add:

```js
timelineId: scroll.timelineId,
sourceText: sanitizeScrollTextInput(true),
fontId: TEXT_SCROLL_FONT_MODEL,
generatorVersion: SCROLL_GENERATOR_VERSION,
fps: getScrollFps(),
intervalMs: getScrollFrameIntervalMs(),
source: "webui_text_scroll_frames_with_source_text",
```

- Later chunks add `timelineId` (cheap, lets firmware reject stale appends).
- `start_scroll` payload gains `timelineId: scroll.timelineId`.
- On a 409 chunk error: restart the whole upload once from chunk 0
  (`append:false`); on second failure, surface the existing alert path.

### 2.4 Startup — text-only restore (NO regen, NO font fetch)

Hook into the existing boot flow after `preloadFirmwareRuntimeState()` resolves
(inside `runPostBootDeferredReads`), not a new phase:

```js
async function restoreScrollTextFromFirmware(source = "post_boot") {
  // gate on the lightweight status fields:
  // renderer.scrollHasSourceText && renderer.scrollTimelineId &&
  // renderer.scrollTimelineId !== scroll.timelineId
  const meta = await apiGet("/api/scroll/meta");
  if (!meta?.ok || !meta.hasSourceText) return false;
  const el = $("scroll-text");
  if (el && !el.value) {
    el.value = meta.sourceText;          // programmatic set fires no input event,
    sanitizeScrollTextInput(true);       //  so scroll.dirty is untouched — good
    applyTextScrollInputFont();
    autoResizeScrollTextInput();
  }
  if (Number.isFinite(meta.uiFps) && meta.uiFps > 0) syncScrollFpsUi(meta.uiFps);
  scroll.timelineId = String(meta.scrollTimelineId || "");
  scroll.restoredFromFirmwareMeta = true;
  pendingScrollMeta = meta;              // module-level, consumed on 6.4 entry
  if (meta.fontId !== TEXT_SCROLL_FONT_MODEL ||
      meta.generatorVersion !== SCROLL_GENERATOR_VERSION) {
    scroll.restoreWarning = "文字已从硬件恢复，但字体/生成器版本不同，预览可能与 LED 不一致。";
  }
  updateScrollUi();
  return true;
}
```

`scroll.active/paused/firmwareBacked` need no special handling here — the existing
`applyFirmwareRuntimeState()` already derives them from status on every poll.

### 2.5 Page 6.4 entry — regen here (switchPage "scroll" branch)

```js
async function restoreScrollPreviewIfNeeded() {
  if (!pendingScrollMeta || scroll.frames.length) return;
  const meta = pendingScrollMeta;
  try {
    await prepareTextScrollTimelineAsync(true);   // boolean force — real signature;
  } catch (_) { return; }                         // reads #scroll-text, no override
  pendingScrollMeta = null;                       //  param needed
  if (scroll.frames.length !== meta.frameCount) {
    scroll.restoreWarning =
      "文字已恢复，但本地重新生成的帧数与硬件不一致；预览仅供参考。";
    // keep controls usable; do NOT clear frames or re-upload
  }
  // frameIndex: no manual fetch — the existing status poll writes
  // renderer.scrollFrameIndex into scroll.frameIndex once frames exist
  // (applyFirmwareRuntimeState), and setScrollPreviewFrame renders it.
  if (scroll.active && !scroll.paused) restartScrollPreviewTimer();
  else setScrollPreviewFrame(scroll.frames[scroll.frameIndex] || blankFrame(),
                             "text_scroll_restore_preview",
                             scroll.paused ? "scroll_paused" : "scroll");
  updateScrollUi();
}
```

Call it inside the existing `if (id === "scroll")` branch of `switchPage`, after
`ensureScrollFontsLoaded()` (chain on `ensureArkPixelFontReady()`; prepare already
awaits it).

Function-name map (v1 pseudocode → real code):

```text
renderScrollPreviewFrame(...)        -> setScrollPreviewFrame(frame, reason, playback)
startIndependentPreviewLoop()        -> restartScrollPreviewTimer()
prepareTextScrollTimelineAsync({..}) -> prepareTextScrollTimelineAsync(force:boolean)
showScrollPreviewWarning(...)        -> scroll.restoreWarning + updateScrollUi()
                                        (add a small warning line to the 6.4 page)
syncScrollIndexNow()                 -> not needed; existing poll handles it
```

### 2.6 Timeline-mismatch refetch (guarded)

In `applyFirmwareRuntimeState`, after the scroll block:

```js
const fwTimelineId = String(renderer.scrollTimelineId ?? "");
if (fwTimelineId && renderer.scrollHasSourceText &&
    fwTimelineId !== scroll.timelineId &&
    !scrollMetaFetchInFlight &&
    performance.now() - lastScrollMetaFetchAt > 5000) {   // debounce
  restoreScrollTextFromFirmware("timeline_mismatch")
    .then(() => { if (isScrollPageActive()) restoreScrollPreviewIfNeeded(); });
}
```

Guards (truthy id + hasSourceText + debounce) prevent the refetch loop when the
board has no timeline or a frames-only one.

### 2.7 No other sync changes

Periodic polling, visibilitychange, pause/resume/step index sync: already correct
today — frameIndex flows through the existing status poll. Do not add per-event
meta fetches.

---

## 3. Implementation order

```text
1. web_json.cpp: \uXXXX decoding + unit-style test via curl payloads
2. config.h limits; utils validateUtf8
3. state.h/state.cpp: ScrollTimelineMeta + source-text buffer alloc + lock docs
4. web_api.cpp: upload handler meta parsing/validation/lifecycle + 409s
5. web_api.cpp: status fields (ScrollStateSnapshot/addScrollStateFields),
   /api/scroll/meta endpoint, commandStartScroll timelineId check
6. app.js: constants, scroll fields, upload payload, 409 retry
7. app.js: restoreScrollTextFromFirmware (post-boot), restoreScrollPreviewIfNeeded
   (6.4 entry), mismatch refetch, warning line in index.html + updateScrollUi
8. Tests (below)
```

## 4. Test checklist

```text
Upload/playback
- ASCII, CJK, emoji (incl. ZWJ sequence 👨‍👩‍👧‍👦, VS16, skin tones): upload OK,
  byte/codepoint validation passes, LEDs play
- frames-only upload via curl (no timelineId/sourceText): plays; start_scroll,
  pause/resume/step/stop all work; status shows scrollHasSourceText=false
- oversized text (>4096 bytes) -> 413; invalid UTF-8 -> 400
- out-of-order chunk / wrong timelineId append -> 409; WebUI auto-restarts once
JSON escapes
- curl body with "sourceText":"你好" -> stored text is 你好
- lone surrogate -> U+FFFD, no corruption
Restore
- refresh mid-scroll: text appears in #scroll-text at boot WITHOUT ark12.json
  network fetch (verify in devtools); preview rebuilds on 6.4 entry; frame count
  matches; index converges via poll
- refresh while paused: paused frame rendered, controls work
- refresh after stop (frames cached): text restored, nothing auto-plays
- second device opens WebUI mid-scroll: same restore path
- fontId/generatorVersion mismatch (fake old value): text restored + warning,
  controls usable, no re-upload
- board with frames but no source text: "无法重建预览" notice, controls usable
Regression
- boot time unchanged when no scroll cached; /api/status size delta is 3 small
  fields; GPIO B1–B3 stop events still reset 6.4 UI
```
