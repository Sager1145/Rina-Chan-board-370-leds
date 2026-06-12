# Text Scroll 6.4 — Source-Text Sync Plan v4 (final, supersedes v2/v3)

Core model unchanged: WebUI uploads generated M370 frames **plus** Unicode source
text + metadata; firmware stores both in RAM; WebUI rebuilds preview locally from
text; firmware never sends frames/bitmaps back; only frameIndex syncs during
playback.

## Changes from v3 (per third audit, tags C1–C10 / H-A..H-D)

```text
C1  codepoint cap removed — bytes (4096) are the only hard text limit
C2  scroll.framesTimelineId separates preview-frame identity from firmware
    timeline identity (prevents stale-frame reuse)
C3  localTimelineMatchesMeta requires uploadComplete && frameCount > 0
C4  restore triggers regen immediately when 6.4 is already the active page
    (NOTE: ensureScrollFontsLoaded() returns undefined, not a Promise — the
    fix calls restoreScrollPreviewIfNeeded() directly; prepare awaits the font)
C5  unsent-local-edit guard applies to ALL restore paths and runs BEFORE any
    metadata is bound (pendingScrollMeta / timelineId / restoredSourceText)
C6  frames-only append:false upload explicitly clears old text metadata
C7  chunkIndex mandatory for timeline-backed appends
C8  reject U+0000 / control chars in sourceText; IDs restricted to safe ASCII
C9  stopScroll()/GPIO reset do NOT clear scroll.timelineId (prevents old text
    auto-restoring after an intentional stop); only pending/restored state clears
C10 full retry regenerates a FRESH timelineId from chunk 0
H-A first-chunk frame count chosen by measured JSON byte budget
H-B meta.frameIndex applied immediately after restore regen (poll refines later)
H-C /api/scroll/meta checks doc.capacity() and doc.overflowed() -> 507
H-D commandStartScroll validations under one scrollMutex snapshot
```

---

## 0. Hard rules

```text
- sourceText is required ONLY for preview restore. Playback (start_scroll, pause,
  resume, step, stop) keeps working for frames-only uploads.
- No ark12.json fetch / frame regen during WebUI startup. Regen happens on 6.4
  entry — or immediately after restore if 6.4 is already active (C4).
- Identity = fontId + generatorVersion strings. No runtime hashing.
- Text hard limit: MAX_SCROLL_TEXT_BYTES = 4096 UTF-8 bytes. No code-point cap
  (C1). validateUtf8 still rejects malformed sequences.
- Two identities on the WebUI (C2):
    scroll.timelineId       = timeline of the current firmware upload/session
    scroll.framesTimelineId = timeline that produced scroll.frames ("" if none)
- All metadata + source-text access under scrollMutex; copy under lock,
  serialize outside.
- uploadComplete true ONLY while the frame buffer is valid; independent of
  hasSourceText.
- No Unicode normalization anywhere; upload post-sanitize text; sanitize must
  be idempotent.
- Matrix dims fixed 22x18 / 370 LEDs — not metadata.
```

---

## 1. Firmware changes

### 1.1 config.h

```cpp
constexpr uint16_t MAX_SCROLL_TEXT_BYTES        = 4096;
constexpr uint8_t  MAX_SCROLL_TIMELINE_ID_CHARS = 47;
constexpr uint8_t  MAX_SCROLL_FONT_ID_CHARS     = 47;
constexpr uint8_t  MAX_SCROLL_GENERATOR_CHARS   = 47;
// no MAX_SCROLL_TEXT_CODEPOINTS (C1)
```

### 1.2 state.h — ScrollTimelineMeta (unchanged from v3)

```cpp
struct ScrollTimelineMeta {
    char     timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1]     = {0};
    char     fontId[MAX_SCROLL_FONT_ID_CHARS + 1]             = {0};
    char     generatorVersion[MAX_SCROLL_GENERATOR_CHARS + 1] = {0};
    uint16_t sourceTextByteLength = 0;
    uint16_t totalFramesExpected  = 0;
    uint16_t framesReceived       = 0;
    uint16_t nextChunkIndex       = 0;
    uint8_t  uiFps                = 0;
    bool     uploadComplete       = false;
    bool     hasSourceText        = false;
};
```

- Source-text buffer allocated in `RuntimeStore::initScrollFrameBuffer()`
  (PSRAM-preferred). Accessors `runtimeScrollMeta()` / `runtimeScrollSourceText()`.
- Lock-contract comment: meta + text buffer guarded by `scrollMutex`.

Two helpers, both called inside `withScrollLock`:

```cpp
// whenever the frame buffer is cleared/invalidated (append:false reset,
// m370ToPackedBits failure path at web_api.cpp ~729, future clears):
static void invalidateScrollUploadLocked() {
    meta.uploadComplete      = false;
    meta.framesReceived      = 0;
    meta.totalFramesExpected = 0;
    meta.nextChunkIndex      = 0;
    // hasSourceText / timelineId / text untouched
}

// C6: full reset at the start of EVERY append:false upload:
static void clearScrollTimelineMetaLocked() {
    invalidateScrollUploadLocked();
    meta.timelineId[0] = meta.fontId[0] = meta.generatorVersion[0] = '\0';
    meta.sourceTextByteLength = 0;
    meta.hasSourceText = false;
    meta.uiFps = 0;
    if (runtimeScrollSourceText()) runtimeScrollSourceText()[0] = '\0';
}
```

### 1.3 web_json.cpp — `\uXXXX` decoding (unchanged from v3)

`case 'u':` in `extractJsonStringAt()`: 4 hex digits, surrogate-pair combine,
U+FFFD for lone surrogates, UTF-8 append, false on malformed hex (caller 400s).

### 1.4 utils — validators (C8)

```cpp
// rejects invalid UTF-8, overlong encodings, surrogates, > U+10FFFF,
// U+0000, and C0 controls EXCEPT '\n' (textarea allows newlines):
bool validateScrollSourceText(const char* s, size_t len);

// timelineId / fontId / generatorVersion: nonempty, printable safe ASCII only:
// [A-Za-z0-9._:-]
bool validateMetaIdString(const char* s, size_t maxLen);
```

### 1.5 /api/scroll upload handler

First chunk (`append:false`), strict order:

```text
1. Read timelineId / sourceText / fontId / generatorVersion / fps / intervalMs /
   totalFrames from body (raw helpers, safe after 1.3).
2. Validate BEFORE touching state:
   - totalFrames <= MAX_SCROLL_FRAMES                         -> else 413
   - if timelineId present: validateMetaIdString              -> else 400
   - if fontId/generatorVersion present: validateMetaIdString -> else 400
   - if sourceText present:
       * source-text buffer allocated?                        -> else 507
       * byte length <= MAX_SCROLL_TEXT_BYTES                 -> else 413
       * validateScrollSourceText passes                      -> else 400
3. stopFirmwareScroll(false); reset frame counters (existing behavior).
4. withScrollLock: clearScrollTimelineMetaLocked();           // C6 — always
   then, only for fields actually present in this request:
   store timelineId / fontId / generatorVersion / uiFps;
   if sourceText present: store it, hasSourceText = true;
   totalFramesExpected = totalFrames; nextChunkIndex = 1.
5. Stream/decode frames as today. m370ToPackedBits failure path also calls
   invalidateScrollUploadLocked().
6. framesReceived = count; if totalFramesExpected > 0 &&
   framesReceived >= totalFramesExpected: uploadComplete = true.
```

Append chunk (`append:true`) — C7 strict rule:

```text
if meta.timelineId is non-empty (timeline-backed upload):
    timelineId missing                     -> 409 "timeline required"
    timelineId != meta.timelineId          -> 409 "timeline mismatch"
    chunkIndex missing                     -> 409 "chunk index required"
    chunkIndex != meta.nextChunkIndex      -> 409 "chunk out of order"
else (legacy frames-only):
    timelineId/chunkIndex optional; if chunkIndex present it must equal
    meta.nextChunkIndex                    -> else 409
decode frames; framesReceived += count; nextChunkIndex++
if totalFramesExpected > 0 && framesReceived >= totalFramesExpected:
    uploadComplete = true
```

Auto-start logic unchanged. Reply gains `timelineId` + `uploadComplete`.
Recovery from any upload error = full re-Send with a FRESH timelineId (C10).

### 1.6 Metadata lifecycle

```text
created/replaced : first chunk of append:false upload (always full clear first, C6)
survives         : stop_scroll, pause/resume, GPIO stop, /api/frame, mode switch
uploadComplete   : forced false by invalidateScrollUploadLocked() on any frame-
                   buffer invalidation; hasSourceText not cleared by that
cleared fully    : only by clearScrollTimelineMetaLocked() (next append:false
                   upload) or reboot
```

### 1.7 /api/status — only 3 new fields (unchanged)

`ScrollStateSnapshot` + `addScrollStateFields` gain:
`scrollTimelineId, scrollUploadComplete, scrollHasSourceText`.

### 1.8 GET /api/scroll/meta

Copy under lock, serialize outside (v3 pattern), plus H-C:

```cpp
PsramJsonDocument doc(16384);
if (doc.capacity() == 0) { sendError(507, "metadata json alloc failed"); return; }
// ... fill fields from the locked copies ...
if (doc.overflowed())    { sendError(507, "metadata json overflow"); return; }
sendJsonDocument(200, doc);
```

Fields: `ok, scrollTimelineId, hasSourceText, sourceText, sourceTextBytes,
fontId, generatorVersion, uiFps, scrollIntervalMs, frameCount, frameIndex,
uploadComplete, firmwareScrollActive, firmwareScrollPaused`.
Empty meta → `{"ok":true,"hasSourceText":false,"scrollTimelineId":""}`.
Register route + OPTIONS.

### 1.9 commandStartScroll — atomic (H-D)

All checks under ONE `withScrollLock` snapshot:

```cpp
bool ok = false; String err;
withScrollLock([&]() {
    const bool hasFrames = runtimeState().scrollFrameCount > 0 &&
                           runtimeScrollFrameBufferReady();
    if (payloadTimelineId.length()) {
        if (payloadTimelineId != meta.timelineId) { err = "timeline mismatch"; return; }
        if (!meta.uploadComplete)                 { err = "upload incomplete"; return; }
    }
    if (!hasFrames) { err = "no cached scroll frames"; return; }
    ok = true;
});
if (!ok) { /* 409 for timeline errors, 400 otherwise */ }
startFirmwareScroll(iMs);   // re-validates internally as today
```

NO sourceText requirement.

---

## 2. WebUI changes (data/app.js)

### 2.1 Constants

```js
const SCROLL_GENERATOR_VERSION = "webui-scrollgen-6.4.2";
const SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES = 12 * 1024;   // H-A
// fontId = TEXT_SCROLL_FONT_MODEL. Bump SCROLL_GENERATOR_VERSION on any change
// to TEXT_SCROLL_CHAR_SPACING, blank margins, textScrollVerticalOffset(), or
// extractFrameFromTextImage. Bump fontModel when ark12.json changes.
```

### 2.2 scroll state additions (C2, C9)

```js
scroll.timelineId = "";          // firmware/current upload timeline
scroll.framesTimelineId = "";    // timeline that produced scroll.frames (C2)
scroll.uploadGeneration = 0;
scroll.restoredSourceText = "";
scroll.restoredFromFirmwareMeta = false;
scroll.restoreWarning = "";      // rendered by updateScrollUi (+ warning line
                                 //  in index.html 6.4 page)
let pendingScrollMeta = null;
let scrollMetaFetchInFlight = false, lastScrollMetaFetchAt = 0;
```

Reset rules:

```text
markScrollTextDirty()            : also scroll.framesTimelineId = "" (C2)
stopScroll() / GPIO reset path   : clear pendingScrollMeta, restoredSourceText,
                                   restoredFromFirmwareMeta, restoreWarning.
                                   DO NOT clear scroll.timelineId or
                                   scroll.framesTimelineId (C9 — firmware meta
                                   survives stop; retained identity means the
                                   mismatch refetch does not re-restore old text)
new Send (startScroll)           : fresh scroll.timelineId; framesTimelineId set
                                   after frames are (re)generated for this send
```

### 2.3 Upload

- Generation guard (unchanged): `const generation = ++scroll.uploadGeneration;`
  checked before each chunk POST and before `start_scroll`.
- Fresh `scroll.timelineId = `scroll-${Date.now()}-${rand4}`` per Send; after
  `prepareTextScrollTimelineAsync` succeeds, `scroll.framesTimelineId =
  scroll.timelineId`.
- First chunk adds `timelineId, sourceText (post-sanitize), fontId,
  generatorVersion, fps, intervalMs,
  source: "webui_text_scroll_frames_with_source_text"`.
- EVERY chunk carries `timelineId` AND `chunkIndex` (C7 makes both mandatory).
- H-A byte-budget first chunk:

```js
function chooseFirstChunkFrames(firstChunkPayloadBuilder) {
  let count = SCROLL_UPLOAD_CHUNK_FRAMES;            // 24
  while (count > 1) {
    const bytes = new TextEncoder()
      .encode(JSON.stringify(firstChunkPayloadBuilder(count))).length;
    if (bytes <= SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) break;
    count--;
  }
  return count;   // min 1; firmware does not support 0-frame first chunks
}
```

- `start_scroll` payload gains `timelineId`.
- Retry (C10): on 409 from any chunk OR `start_scroll`, restart ONCE from
  chunk 0 with `append:false` and a FRESH timelineId (and bumped generation);
  second failure → existing alert path.

### 2.4 Startup — text restore (C5 guard first, then bind)

Hook into `runPostBootDeferredReads`. Gate on status renderer fields:
`scrollHasSourceText && scrollTimelineId && scrollTimelineId !== scroll.timelineId`.

```js
function setScrollTextFromFirmware(text) {        // never marks dirty (verified)
  const el = $("scroll-text");
  if (!el || el.value) return false;
  el.value = text;
  sanitizeScrollTextInput(true);
  applyTextScrollInputFont();
  autoResizeScrollTextInput();
  return true;
}

async function restoreScrollTextFromFirmware(source = "post_boot") {
  if (scrollMetaFetchInFlight) return false;
  scrollMetaFetchInFlight = true;
  try {
    const meta = await apiGet("/api/scroll/meta");
    lastScrollMetaFetchAt = performance.now();
    if (!meta?.ok || !meta.hasSourceText) return false;

    // C5: guard BEFORE binding any metadata, on ALL restore paths
    const currentValue = $("scroll-text")?.value || "";
    const restoredText = String(meta.sourceText ?? "");
    const hasLocalUnsentText =
      scroll.dirty || (currentValue && currentValue !== restoredText);
    if (hasLocalUnsentText) {
      scroll.restoreWarning =
        "硬件有滚动文字可恢复，但输入框已有未发送内容，未自动覆盖。";
      updateScrollUi();
      return false;
    }

    // bind only after the guard passes
    scroll.restoredSourceText = restoredText;
    pendingScrollMeta = meta;
    scroll.timelineId = String(meta.scrollTimelineId || "");
    scroll.restoredFromFirmwareMeta = true;
    setScrollTextFromFirmware(restoredText);
    syncScrollFpsUi(
      clamp(Number(meta.uiFps) || DEFAULT_SCROLL_FPS, SCROLL_FPS_MIN, SCROLL_FPS_MAX));
    if (meta.fontId !== TEXT_SCROLL_FONT_MODEL ||
        meta.generatorVersion !== SCROLL_GENERATOR_VERSION) {
      scroll.restoreWarning =
        "文字已从硬件恢复，但字体/生成器版本不同，预览可能与 LED 不一致。";
    }
    updateScrollUi();

    // C4: if 6.4 is already the active page, regen now. NOTE:
    // ensureScrollFontsLoaded() returns undefined — do not chain .then() on it.
    // restoreScrollPreviewIfNeeded() awaits the font itself via
    // prepareTextScrollTimelineAsync -> ensureArkPixelFontReady().
    if (isScrollPageActive()) {
      ensureScrollFontsLoaded();                       // kicks off lazy loads
      restoreScrollPreviewIfNeeded().catch(() => {});  // awaits font internally
    }
    return true;
  } finally { scrollMetaFetchInFlight = false; }
}
```

No regen unless 6.4 is active.

### 2.5 Page 6.4 entry — regen (C2, C3, H-B)

Call from `switchPage`'s `if (id === "scroll")` branch after
`ensureScrollFontsLoaded()`:

```js
function localTimelineMatchesMeta(meta) {            // C2 + C3
  return meta.uploadComplete === true &&
         Number(meta.frameCount || 0) > 0 &&
         scroll.framesTimelineId === String(meta.scrollTimelineId || "") &&
         scroll.frames.length === Number(meta.frameCount || 0);
}

async function restoreScrollPreviewIfNeeded() {
  setScrollTextFromFirmware(scroll.restoredSourceText);   // late DOM fill
  if (!pendingScrollMeta) return;
  const meta = pendingScrollMeta;
  if (localTimelineMatchesMeta(meta)) { pendingScrollMeta = null; return; }
  try {
    await prepareTextScrollTimelineAsync(true);       // boolean force; reads
  } catch (_) { return; }                             //  #scroll-text
  pendingScrollMeta = null;
  scroll.framesTimelineId = String(meta.scrollTimelineId || "");   // C2
  if (scroll.frames.length !== Number(meta.frameCount || 0)) {
    scroll.restoreWarning =
      "文字已恢复，但本地重新生成的帧数与硬件不一致；预览仅供参考。";
    scroll.framesTimelineId = "";    // frames do not represent this timeline
  }
  // H-B: apply meta frameIndex immediately (poll refines afterwards)
  scroll.frameIndex = clamp(Number(meta.frameIndex) || 0,
                            0, Math.max(0, scroll.frames.length - 1));
  if (scroll.active && !scroll.paused) restartScrollPreviewTimer();
  setScrollPreviewFrame(scroll.frames[scroll.frameIndex] || blankFrame(),
                        "text_scroll_restore_preview",
                        scroll.paused ? "scroll_paused"
                                      : (scroll.active ? "scroll" : "idle"));
  updateScrollUi();
}
```

`prepareTextScrollTimeline` sets `signature`/`dirty=false` itself, so restored
text is not an unsent edit afterward.

### 2.6 Timeline-mismatch refetch (guarded; C5 guard lives inside restore)

```js
const fwTimelineId = String(renderer.scrollTimelineId ?? "");
if (fwTimelineId && renderer.scrollHasSourceText &&
    fwTimelineId !== scroll.timelineId &&
    !scrollMetaFetchInFlight &&
    performance.now() - lastScrollMetaFetchAt > 5000) {
  restoreScrollTextFromFirmware("timeline_mismatch")
    .then((ok) => { if (ok && isScrollPageActive()) restoreScrollPreviewIfNeeded(); });
}
```

C9 makes this safe after a local stop: `scroll.timelineId` is retained, so no
false mismatch fires and old text is not auto-refilled.

### 2.7 No other sync changes

Polling, visibilitychange, pause/resume/step index sync unchanged.

---

## 3. Implementation order

```text
1. web_json.cpp \uXXXX decoding (+ curl escape tests)
2. config.h limits; utils validateScrollSourceText / validateMetaIdString
3. state.h/.cpp: meta struct, text buffer alloc,
   invalidateScrollUploadLocked + clearScrollTimelineMetaLocked, lock docs
4. web_api.cpp: upload handler (C6 full clear, C7 strict append, B7 call
   sites, 507/413/400/409s)
5. web_api.cpp: status fields, /api/scroll/meta (H-C), commandStartScroll (H-D)
6. app.js: constants, scroll fields (C2/C9 reset rules), upload payload,
   H-A byte budget, generation guard, C10 fresh-id retry
7. app.js: setScrollTextFromFirmware / restoreScrollTextFromFirmware (C5, C4) /
   restoreScrollPreviewIfNeeded (C2/C3/H-B) / mismatch refetch;
   warning line in index.html
8. Tests
```

## 4. Test checklist

```text
Upload/playback
- ASCII, CJK, emoji (ZWJ 👨‍👩‍👧‍👦, VS16, skin tones): upload OK, plays
- 4096 bytes of ASCII: ACCEPTED (C1 — no codepoint cap)
- frames-only curl upload: plays; all commands work; scrollHasSourceText=false
- text upload, then frames-only append:false upload: scrollHasSourceText
  becomes false, old text NOT restored afterwards (C6)
- >4096-byte text -> 413; invalid UTF-8 -> 400; alloc failure -> 507
- sourceText containing   or C0 control (except \n) -> 400 (C8)
- timelineId/fontId/generatorVersion with control or non-safe chars -> 400 (C8)
- timeline-backed append: missing timelineId -> 409; missing chunkIndex -> 409;
  duplicate chunk (same index resent) -> 409, no duplicate frames (C7)
JSON escapes
- curl "sourceText":"你好" -> stored 你好; lone surrogate -> U+FFFD
Race / stale upload
- Send A, immediately Send B: A's late chunks rejected; stale generation aborts
  client-side; start_scroll 409 -> ONE full retry with FRESH timelineId (C10)
Large metadata
- ~4096-byte text: first chunk frame count auto-reduced, measured body
  <= 12 KB (H-A); /api/scroll/meta returns intact text, no overflow (H-C)
Restore
- refresh mid-scroll: text at boot, NO ark12.json request; regen on 6.4 entry;
  frameIndex applied from meta immediately (H-B), poll converges
- open WebUI DIRECTLY on 6.4 with active scroll: text restores AND preview
  regenerates without leaving/re-entering the page (C4)
- refresh while paused: paused frame at meta.frameIndex, not frame 0 (H-B)
- refresh after stop: text restored, nothing auto-plays
- second device mid-scroll: same restore path
- version mismatch: text restored + warning, controls usable, no re-upload
- frames but no sourceText: notice shown, controls usable
- uploadComplete=false + hasSourceText=true + frameCount=0: text restores and
  preview regenerates (match logic does NOT false-pass on 0==0) (C3)
Stale local frames
- old scroll.frames with SAME frameCount but different text/timeline: regen
  happens (framesTimelineId mismatch) (C2)
- user edits text -> framesTimelineId cleared -> next restore regenerates (C2)
Input overwrite
- user types unsent text BEFORE /api/scroll/meta returns: input not
  overwritten AND no metadata bound to local state (C5)
- unsent edit + other device starts new timeline: not overwritten, warning
Stop semantics
- local Stop, wait >5 s with polling active: old firmware text does NOT
  auto-refill the input (C9)
Buffer invalidation
- bad M370 mid-upload via curl: frameCount 0 AND scrollUploadComplete false;
  hasSourceText per lifecycle; restore still regenerates from text
Regression
- boot time unchanged with no cached scroll; status delta = 3 fields;
  GPIO B1–B3 stop still resets 6.4 UI
```
