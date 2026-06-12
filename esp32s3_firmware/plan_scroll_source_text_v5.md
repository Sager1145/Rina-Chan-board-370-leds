# Text Scroll 6.4 — Source-Text Sync Plan v5 (final, supersedes v2–v4)

Core model unchanged: WebUI uploads generated M370 frames **plus** Unicode source
text + metadata; firmware stores both in RAM; WebUI rebuilds preview locally from
text; firmware never sends frames/bitmaps back; only frameIndex syncs during
playback.

## Changes from v4 (per fourth audit, tags D1–D10)

```text
D1  sourceText REQUIRES timelineId + fontId + generatorVersion (clean contract:
    frames-only = legacy playback cache; text-backed = restorable timeline)
D2  start_scroll checks uploadComplete whenever meta is timeline-backed,
    regardless of whether the command payload carries timelineId
D3  timeline-backed append rejected after uploadComplete; frame overrun
    (framesReceived + incoming > totalFramesExpected) -> 409
D4  chooseFirstChunkFrames throws a clear error if even 1 frame exceeds budget
D5  framesTimelineId bound ONLY on exact generator identity + frameCount match
D6  restoreWarning cleared at the start of every clean restore attempt
D7  new Send clears pendingScrollMeta / restored* state before upload
D8  start_scroll error reporting via enum, no String allocation inside scrollMutex
D9  test: TEXT_SCROLL_FONT_MODEL and SCROLL_GENERATOR_VERSION pass
    validateMetaIdString (verified: "ark_pixel_12px_fusion_bitmap_v4" and
    "webui-scrollgen-6.4.2" fit [A-Za-z0-9._:-])
D10 oversized third-party text: restore detects sanitizer truncation, warns,
    and never binds framesTimelineId (silent truncation impossible).
    NOTE — diverges from audit's preferred "never truncate": the 1000-visible-
    char cap is baked into the whole pipeline (prepareTextScrollTimeline ->
    sanitizeScrollTextInput(true); input listeners re-truncate on edit), so
    no-truncation is not implementable without changing the product limit.
    Contract: WebUI-generated sourceText is always <= UI limit; third-party
    text above it restores truncated WITH explicit warning + approximate
    preview, controls usable.
```

---

## 0. Hard rules

```text
- Playback never depends on sourceText. frames-only uploads (curl, scripts,
  legacy clients) keep working for start/pause/resume/step/stop.
- Text-backed uploads are all-or-nothing: sourceText requires timelineId,
  fontId, generatorVersion (D1). If meta is timeline-backed, incomplete frames
  are NEVER playable (D2) and appends after completion are rejected (D3).
- No ark12.json fetch / frame regen during WebUI startup. Regen on 6.4 entry,
  or immediately after restore if 6.4 is already active.
- Identity = fontId + generatorVersion strings; no runtime hashing.
- Text hard limit: MAX_SCROLL_TEXT_BYTES = 4096 UTF-8 bytes; no code-point cap.
- Two WebUI identities:
    scroll.timelineId       = current firmware/upload timeline
    scroll.framesTimelineId = timeline scroll.frames EXACTLY represent
                              ("" unless generator identity + frameCount match, D5)
- All metadata + text access under scrollMutex; copy under lock, serialize
  outside; no heap String writes inside the lock (D8).
- uploadComplete true ONLY while the frame buffer is valid; independent of
  hasSourceText.
- No Unicode normalization; upload post-sanitize text; sanitize idempotent.
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
```

### 1.2 state.h — ScrollTimelineMeta + helpers (unchanged from v4)

Struct as v4. Source-text buffer allocated in
`RuntimeStore::initScrollFrameBuffer()` (PSRAM-preferred). Lock-contract comment
extended. Helpers called inside `withScrollLock`:

```cpp
static void invalidateScrollUploadLocked();      // frame invalidation: clears
                                                 // uploadComplete/counters, keeps text
static void clearScrollTimelineMetaLocked();     // full clear incl. text; runs at
                                                 // the start of EVERY append:false
```

`invalidateScrollUploadLocked()` call sites: append:false reset, the existing
`m370ToPackedBits` failure path (web_api.cpp ~729), any future buffer clear.

### 1.3 web_json.cpp — `\uXXXX` decoding (unchanged)

Surrogate-pair combine, U+FFFD for lone surrogates, false on malformed hex.

### 1.4 utils — validators

```cpp
// rejects invalid UTF-8, overlong, surrogates, > U+10FFFF, U+0000,
// C0 controls except '\n':
bool validateScrollSourceText(const char* s, size_t len);

// nonempty, printable safe ASCII [A-Za-z0-9._:-] only:
bool validateMetaIdString(const char* s, size_t maxLen);
```

### 1.5 /api/scroll upload handler

First chunk (`append:false`), strict order:

```text
1. Read timelineId / sourceText / fontId / generatorVersion / fps / intervalMs /
   totalFrames (raw helpers, safe after 1.3).
2. Validate BEFORE touching state:
   - totalFrames <= MAX_SCROLL_FRAMES                       -> else 413
   - D1: if sourceText present:
       * timelineId present + validateMetaIdString          -> else 400
       * fontId present + validateMetaIdString              -> else 400
       * generatorVersion present + validateMetaIdString    -> else 400
       * source-text buffer allocated?                      -> else 507
       * byte length <= MAX_SCROLL_TEXT_BYTES               -> else 413
       * validateScrollSourceText passes                    -> else 400
   - if timelineId present WITHOUT sourceText: validateMetaIdString -> else 400
     (timeline-backed frames-only upload is allowed; restore simply
      reports hasSourceText=false)
3. stopFirmwareScroll(false); reset frame counters (existing behavior).
4. withScrollLock: clearScrollTimelineMetaLocked(); then store the fields
   present in this request; hasSourceText only when sourceText stored;
   totalFramesExpected = totalFrames; nextChunkIndex = 1.
5. Stream/decode frames as today; m370ToPackedBits failure path also calls
   invalidateScrollUploadLocked().
6. framesReceived = count; if totalFramesExpected > 0 &&
   framesReceived >= totalFramesExpected: uploadComplete = true.
```

Append chunk (`append:true`):

```text
if meta.timelineId is non-empty (timeline-backed):
    meta.uploadComplete == true            -> 409 "upload already complete" (D3)
    timelineId missing                     -> 409 "timeline required"
    timelineId != meta.timelineId          -> 409 "timeline mismatch"
    chunkIndex missing                     -> 409 "chunk index required"
    chunkIndex != meta.nextChunkIndex      -> 409 "chunk out of order"
    if totalFramesExpected > 0 &&
       framesReceived + incomingCount > totalFramesExpected
                                           -> 409 "too many frames" (D3)
else (legacy frames-only):
    timelineId/chunkIndex optional; chunkIndex if present must equal
    meta.nextChunkIndex                    -> else 409
    (MAX_SCROLL_FRAMES cap still applies as today)
decode frames; framesReceived += count; nextChunkIndex++
if totalFramesExpected > 0 && framesReceived >= totalFramesExpected:
    uploadComplete = true
```

Count incoming frames for the D3 overrun check during the existing streaming
parse: reject as soon as `framesReceived + parsedSoFar` would exceed
`totalFramesExpected` (no need to pre-count).

Auto-start logic unchanged. Reply gains `timelineId` + `uploadComplete`.
Recovery from any upload error = full re-Send with a FRESH timelineId.

### 1.6 Metadata lifecycle (unchanged from v4)

```text
created/replaced : append:false upload (full clear first)
survives         : stop_scroll, pause/resume, GPIO stop, /api/frame, mode switch
uploadComplete   : forced false on any frame-buffer invalidation
cleared fully    : only by clearScrollTimelineMetaLocked() or reboot
```

### 1.7 /api/status — only 3 new fields (unchanged)

`scrollTimelineId, scrollUploadComplete, scrollHasSourceText` via
`ScrollStateSnapshot` + `addScrollStateFields`.

### 1.8 GET /api/scroll/meta (unchanged from v4)

Copy under lock → serialize outside; `PsramJsonDocument doc(16384)` with
`capacity()==0` → 507 and `overflowed()` → 507. Fields as v4. Route + OPTIONS.

### 1.9 commandStartScroll — atomic, enum errors (D2, D8)

```cpp
enum class StartScrollError : uint8_t {
    None, TimelineMismatch, UploadIncomplete, NoCachedFrames
};
StartScrollError serr = StartScrollError::None;

withScrollLock([&]() {
    const bool timelineBacked = meta.timelineId[0] != '\0';
    const bool hasFrames = runtimeState().scrollFrameCount > 0 &&
                           runtimeScrollFrameBufferReady();
    if (timelineBacked) {
        if (payloadTimelineIdLen > 0 &&
            strcmp(payloadTimelineId, meta.timelineId) != 0) {
            serr = StartScrollError::TimelineMismatch; return;
        }
        if (!meta.uploadComplete) {                       // D2: checked even
            serr = StartScrollError::UploadIncomplete;    // without payload id
            return;
        }
    }
    if (!hasFrames) { serr = StartScrollError::NoCachedFrames; return; }
});
// map to response OUTSIDE the lock:
// TimelineMismatch / UploadIncomplete -> 409, NoCachedFrames -> 400 (existing msg)
```

Copy `payload["timelineId"]` into a stack char buffer before taking the lock
(no String ops inside).

---

## 2. WebUI changes (data/app.js)

### 2.1 Constants

```js
const SCROLL_GENERATOR_VERSION = "webui-scrollgen-6.4.2";
const SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES = 12 * 1024;
// fontId = TEXT_SCROLL_FONT_MODEL. Both constants MUST pass the firmware's
// [A-Za-z0-9._:-] rule (D9 — verified for current values; test enforces it).
// Bump SCROLL_GENERATOR_VERSION on any change to TEXT_SCROLL_CHAR_SPACING,
// blank margins, textScrollVerticalOffset(), or extractFrameFromTextImage.
// Bump fontModel when ark12.json changes.
```

### 2.2 scroll state additions + reset rules

As v4 (`timelineId, framesTimelineId, uploadGeneration, restoredSourceText,
restoredFromFirmwareMeta, restoreWarning`; module-level `pendingScrollMeta`,
fetch guards), plus:

```text
markScrollTextDirty()          : scroll.framesTimelineId = ""
stopScroll() / GPIO reset path : clear pendingScrollMeta/restored*/warning;
                                 KEEP timelineId and framesTimelineId
startScroll() (new Send), D7   : BEFORE upload —
                                   pendingScrollMeta = null;
                                   scroll.restoredSourceText = "";
                                   scroll.restoredFromFirmwareMeta = false;
                                   scroll.restoreWarning = "";
                                 then fresh timelineId; framesTimelineId =
                                 timelineId after prepare succeeds
```

### 2.3 Upload

As v4 (generation guard, fresh timelineId per Send, first-chunk metadata,
timelineId + chunkIndex on EVERY chunk, start_scroll carries timelineId,
one full retry on any 409 with fresh timelineId + bumped generation), with D4:

```js
function chooseFirstChunkFrames(firstChunkPayloadBuilder) {
  let count = SCROLL_UPLOAD_CHUNK_FRAMES;             // 24
  while (count > 1) {
    const bytes = new TextEncoder()
      .encode(JSON.stringify(firstChunkPayloadBuilder(count))).length;
    if (bytes <= SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) return count;
    count--;
  }
  const oneFrameBytes = new TextEncoder()
    .encode(JSON.stringify(firstChunkPayloadBuilder(1))).length;
  if (oneFrameBytes > SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) {
    throw new Error("滚动文字过长，元数据无法放入首个上传分块");   // D4
  }
  return 1;
}
```

(With the 4096-byte cap + escaping, 1 frame always fits 12 KB in practice;
this is a defensive guard surfaced through the existing upload-error alert.)

### 2.4 Startup — text restore (D6, D10)

```js
async function restoreScrollTextFromFirmware(source = "post_boot") {
  if (scrollMetaFetchInFlight) return false;
  scrollMetaFetchInFlight = true;
  try {
    const meta = await apiGet("/api/scroll/meta");
    lastScrollMetaFetchAt = performance.now();
    if (!meta?.ok || !meta.hasSourceText) return false;

    // unsent-edit guard BEFORE binding anything (unchanged from v4)
    const currentValue = $("scroll-text")?.value || "";
    const restoredText = String(meta.sourceText ?? "");
    if (scroll.dirty || (currentValue && currentValue !== restoredText)) {
      scroll.restoreWarning =
        "硬件有滚动文字可恢复，但输入框已有未发送内容，未自动覆盖。";
      updateScrollUi();
      return false;
    }

    scroll.restoreWarning = "";                       // D6: clean slate
    scroll.restoredSourceText = restoredText;
    pendingScrollMeta = meta;
    scroll.timelineId = String(meta.scrollTimelineId || "");
    scroll.restoredFromFirmwareMeta = true;
    setScrollTextFromFirmware(restoredText);          // sanitize may truncate —
                                                      //  detected below (D10)
    // D10: detect sanitizer truncation (oversized third-party text)
    const valueAfterSanitize = $("scroll-text")?.value || "";
    if (valueAfterSanitize && valueAfterSanitize !== restoredText) {
      scroll.restoreWarning =
        "硬件滚动文字超过 WebUI 输入上限，已截断显示；预览仅供参考。";
    }
    syncScrollFpsUi(
      clamp(Number(meta.uiFps) || DEFAULT_SCROLL_FPS, SCROLL_FPS_MIN, SCROLL_FPS_MAX));
    if (meta.fontId !== TEXT_SCROLL_FONT_MODEL ||
        meta.generatorVersion !== SCROLL_GENERATOR_VERSION) {
      scroll.restoreWarning =
        "文字已从硬件恢复，但字体/生成器版本不同，预览可能与 LED 不一致。";
    }
    updateScrollUi();
    if (isScrollPageActive()) {           // direct-on-6.4 race fix (v4 C4)
      ensureScrollFontsLoaded();          // returns undefined — no .then()
      restoreScrollPreviewIfNeeded().catch(() => {});
    }
    return true;
  } finally { scrollMetaFetchInFlight = false; }
}
```

`setScrollTextFromFirmware` unchanged from v4 (fills only empty input, never
marks dirty).

### 2.5 Page 6.4 entry — regen (D5)

```js
function exactGeneratorMatch(meta) {                  // D5
  return meta.fontId === TEXT_SCROLL_FONT_MODEL &&
         meta.generatorVersion === SCROLL_GENERATOR_VERSION;
}

function localTimelineMatchesMeta(meta) {
  return meta.uploadComplete === true &&
         Number(meta.frameCount || 0) > 0 &&
         scroll.framesTimelineId === String(meta.scrollTimelineId || "") &&
         scroll.frames.length === Number(meta.frameCount || 0);
}

async function restoreScrollPreviewIfNeeded() {
  setScrollTextFromFirmware(scroll.restoredSourceText);
  if (!pendingScrollMeta) return;
  const meta = pendingScrollMeta;
  if (localTimelineMatchesMeta(meta)) { pendingScrollMeta = null; return; }
  try {
    await prepareTextScrollTimelineAsync(true);
  } catch (_) { return; }
  pendingScrollMeta = null;

  // D5: bind frames identity ONLY on exact generator + frameCount match
  if (exactGeneratorMatch(meta) &&
      scroll.frames.length === Number(meta.frameCount || 0)) {
    scroll.framesTimelineId = String(meta.scrollTimelineId || "");
  } else {
    scroll.framesTimelineId = "";
    if (scroll.frames.length !== Number(meta.frameCount || 0)) {
      scroll.restoreWarning =
        "文字已恢复，但本地重新生成的帧数与硬件不一致；预览仅供参考。";
    }
  }

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

### 2.6 Timeline-mismatch refetch (unchanged from v4)

Guarded by truthy fwTimelineId + scrollHasSourceText + 5 s debounce +
in-flight flag; safe after local stop because timelineId is retained.

### 2.7 No other sync changes

Polling, visibilitychange, pause/resume/step index sync unchanged.

---

## 3. Implementation order

```text
1. web_json.cpp \uXXXX decoding (+ curl escape tests)
2. config.h limits; utils validateScrollSourceText / validateMetaIdString
3. state.h/.cpp: meta struct, text buffer alloc, invalidate/clear helpers,
   lock docs
4. web_api.cpp: upload handler (D1 contract, D3 complete/overrun rejects,
   invalidate call sites, 507/413/400/409s)
5. web_api.cpp: status fields, /api/scroll/meta, commandStartScroll (D2/D8)
6. app.js: constants, scroll fields + D7 reset rules, upload payload,
   D4 budget guard, generation guard, fresh-id retry
7. app.js: restore functions (D5/D6/D10), mismatch refetch, warning line in
   index.html
8. Tests
```

## 4. Test checklist

```text
Upload/playback
- ASCII, CJK, emoji (ZWJ 👨‍👩‍👧‍👦, VS16, skin tones): upload OK, plays
- 4096 bytes ASCII via curl: accepted by firmware
- frames-only curl upload: plays; all commands work; scrollHasSourceText=false
- timeline-backed frames-only upload (timelineId, no sourceText): accepted,
  hasSourceText=false
- text upload then frames-only append:false: scrollHasSourceText=false, old
  text not restored
- >4096-byte text -> 413; invalid UTF-8 -> 400; alloc failure -> 507
- sourceText with U+0000 or C0 control (except \n) -> 400
- IDs with control / non-safe chars -> 400
Contract / malformed clients (D1–D3)
- sourceText WITHOUT timelineId -> 400
- sourceText WITHOUT fontId or generatorVersion -> 400
- timeline-backed complete upload, extra append with next chunkIndex -> 409
- timeline-backed append exceeding totalFrames -> 409 "too many frames"
- timeline-backed PARTIAL upload, start_scroll WITHOUT timelineId -> 409
  "upload incomplete" (D2)
- timeline-backed append: missing timelineId -> 409; missing chunkIndex -> 409;
  duplicate chunk -> 409, no duplicate frames
JSON escapes
- curl "sourceText":"你好" -> stored 你好; lone surrogate -> U+FFFD
- TEXT_SCROLL_FONT_MODEL and SCROLL_GENERATOR_VERSION pass
  validateMetaIdString (D9)
Race / stale upload
- Send A then immediately Send B: A's late chunks rejected; stale generation
  aborts client-side; any 409 -> ONE full retry with FRESH timelineId
- old pendingScrollMeta cleared when user presses Send (D7)
Large metadata (D4)
- ~4096-byte text: first chunk auto-reduced, body <= 12 KB
- text heavy in quotes/backslashes (escaping doubles size): budget still
  respected; if 1 frame cannot fit -> clear error surfaced
- /api/scroll/meta returns intact text; capacity/overflow -> 507
Restore
- refresh mid-scroll: text at boot, NO ark12.json request; regen on 6.4 entry;
  frameIndex applied from meta immediately, poll converges
- open WebUI DIRECTLY on 6.4 with active scroll: text + preview restore
  without re-entering the page
- refresh while paused: paused frame at meta.frameIndex, not frame 0
- refresh after stop: text restored, nothing auto-plays
- second device mid-scroll: same restore path
- version mismatch + SAME frameCount: warning shown, preview generated,
  framesTimelineId stays "" (D5)
- clean exact restore: previous restoreWarning cleared (D6)
- frames but no sourceText: notice shown, controls usable
- uploadComplete=false + hasSourceText=true + frameCount=0: text restores,
  preview regenerates (no false 0==0 match)
- 4096-byte ASCII third-party text: restore truncates to UI limit WITH
  explicit warning, framesTimelineId stays "", controls usable (D10)
Stale local frames
- old frames, same frameCount, different text/timeline: regen happens
- user edits text -> framesTimelineId cleared -> next restore regenerates
Input overwrite
- unsent text typed before meta returns: not overwritten, no metadata bound
- unsent edit + other device new timeline: not overwritten, warning
Stop semantics
- local Stop, wait >5 s with polling: old firmware text does NOT auto-refill
Buffer invalidation
- bad M370 mid-upload: frameCount 0 AND scrollUploadComplete false;
  hasSourceText per lifecycle; restore still regenerates from text
Regression
- boot time unchanged with no cached scroll; status delta = 3 fields;
  GPIO B1–B3 stop still resets 6.4 UI
```
