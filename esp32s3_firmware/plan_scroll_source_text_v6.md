# Text Scroll 6.4 — Source-Text Sync Plan v6 (implementation-ready, supersedes v2–v5)

Core model unchanged: WebUI uploads generated M370 frames **plus** Unicode source
text + metadata; firmware stores both in RAM; WebUI rebuilds preview locally from
text; firmware never sends frames/bitmaps back; only frameIndex syncs during
playback.

## Changes from v5 (fifth audit, tags E1–E6 / EH-A..C, + one self-found item)

```text
E1  frame-overrun check applies to the FIRST chunk too (timeline-backed):
    parsedSoFar > totalFramesExpected -> 409 + invalidate
E2  timeline-backed upload requires totalFrames > 0 (else uploadComplete can
    never become true and D2 blocks playback forever) -> 400
E3  timelineId / fontId / generatorVersion validated WHENEVER present
    (independent of sourceText); D1 presence rule enforced separately
E4  scroll.restoredTextTruncated flag — truncated restore can NEVER bind
    framesTimelineId, even on coincidental frameCount match
E5  setScrollRestoreWarning() appends warnings instead of overwriting
    (truncation + version mismatch can coexist)
E6  start_scroll payload timelineId: length > MAX_SCROLL_TIMELINE_ID_CHARS or
    invalid charset -> 400 BEFORE the lock; never compare a truncated ID
EH-A comment: bad frame data invalidates playback cache but intentionally
     keeps sourceText
EH-B doc: timelineId-without-sourceText is an advanced/third-party form; the
     WebUI always sends timelineId + fontId + generatorVersion + sourceText
EH-C firmware invariant comment near meta helpers (see 1.2)
SF1 (self-found) variable first-chunk size changes upload-loop slicing:
    chunk 1 starts at offset firstChunkFrames (not SCROLL_UPLOAD_CHUNK_FRAMES);
    chunkIndex still increments by 1 per chunk — do NOT reuse the existing
    fixed-stride loop in uploadFirmwareScrollTimeline unchanged
```

Final invariants (EH-C, also added as firmware comments):

```text
timelineId present  = timeline-backed cache
timeline-backed     => totalFramesExpected > 0
timeline-backed     => never playable unless uploadComplete == true
framesTimelineId    = EXACT local preview identity only, never approximate
```

---

## 0. Hard rules

```text
- Playback never depends on sourceText; frames-only uploads keep working.
- Text-backed uploads are all-or-nothing: sourceText requires timelineId,
  fontId, generatorVersion. Timeline-backed uploads require totalFrames > 0
  (E2). Incomplete timeline-backed caches are never playable. Completed
  timeline-backed uploads reject further appends.
- No ark12.json fetch / frame regen during WebUI startup; regen on 6.4 entry
  (or immediately after restore if 6.4 already active).
- Identity = fontId + generatorVersion strings; no runtime hashing.
- Text hard limit: MAX_SCROLL_TEXT_BYTES = 4096 UTF-8 bytes; no code-point cap.
- scroll.timelineId vs scroll.framesTimelineId as v5; framesTimelineId binds
  only on exact generator identity + frameCount match + non-truncated text (E4).
- Metadata/text access under scrollMutex; copy under lock, serialize outside;
  no heap String writes inside the lock.
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

### 1.2 state.h — ScrollTimelineMeta + helpers

Struct and buffer allocation as v4/v5. Helpers (called inside `withScrollLock`):

```cpp
// Invariant (EH-C):
// meta.timelineId[0] != '\0' means this is a timeline-backed cache:
//   - totalFramesExpected must be > 0 (enforced at upload),
//   - uploadComplete is authoritative,
//   - start_scroll must reject while uploadComplete == false.
// framesTimelineId on the WebUI side mirrors EXACT preview identity only.

static void invalidateScrollUploadLocked();   // EH-A: bad frame data invalidates
                                              // the playback cache but
                                              // intentionally keeps sourceText
static void clearScrollTimelineMetaLocked();  // full clear; start of every
                                              // append:false upload
```

`invalidateScrollUploadLocked()` call sites: append:false reset, the
`m370ToPackedBits` failure path (web_api.cpp ~729), the E1 overrun reject, any
future buffer clear.

### 1.3 web_json.cpp — `\uXXXX` decoding (unchanged)

### 1.4 utils — validators (unchanged signatures)

`validateScrollSourceText` (UTF-8 strict, rejects U+0000 and C0 except `\n`),
`validateMetaIdString` (nonempty, `[A-Za-z0-9._:-]`).

### 1.5 /api/scroll upload handler

First chunk (`append:false`), strict order:

```text
1. Read timelineId / sourceText / fontId / generatorVersion / fps / intervalMs /
   totalFrames.
2. Validate BEFORE touching state:
   a. totalFrames <= MAX_SCROLL_FRAMES                      -> else 413
   b. E3: each of timelineId / fontId / generatorVersion, WHENEVER present:
      validateMetaIdString (covers length + charset)        -> else 400
   c. D1: if sourceText present:
      timelineId AND fontId AND generatorVersion present    -> else 400
      source-text buffer allocated?                         -> else 507
      byte length <= MAX_SCROLL_TEXT_BYTES                  -> else 413
      validateScrollSourceText passes                       -> else 400
   d. E2: if timelineId present: totalFrames > 0            -> else 400
3. stopFirmwareScroll(false); reset frame counters (existing behavior).
4. withScrollLock: clearScrollTimelineMetaLocked(); store present fields;
   hasSourceText only when sourceText stored;
   totalFramesExpected = totalFrames; nextChunkIndex = 1.
5. Stream/decode frames as today, with E1 inside the streaming loop for
   timeline-backed uploads:
      if totalFramesExpected > 0 && parsedSoFar > totalFramesExpected:
          withScrollLock { scrollFrameCount = 0; invalidateScrollUploadLocked(); }
          -> 409 "too many frames"
   (m370ToPackedBits failure keeps its existing zero-count path + invalidate.)
6. framesReceived = count; if totalFramesExpected > 0 &&
   framesReceived >= totalFramesExpected: uploadComplete = true.
```

Append chunk (`append:true`):

```text
if meta.timelineId is non-empty (timeline-backed):
    meta.uploadComplete == true            -> 409 "upload already complete"
    timelineId missing                     -> 409 "timeline required"
    timelineId != meta.timelineId          -> 409 "timeline mismatch"
    chunkIndex missing                     -> 409 "chunk index required"
    chunkIndex != meta.nextChunkIndex      -> 409 "chunk out of order"
    E1 (streaming): framesReceived + parsedSoFar > totalFramesExpected
                                           -> 409 "too many frames" + invalidate
else (legacy frames-only):
    timelineId/chunkIndex optional; chunkIndex if present must equal
    meta.nextChunkIndex -> else 409; MAX_SCROLL_FRAMES cap applies as today
decode frames; framesReceived += count; nextChunkIndex++
if totalFramesExpected > 0 && framesReceived >= totalFramesExpected:
    uploadComplete = true
```

EH-B: timelineId-without-sourceText is a valid but advanced/third-party form
(restore reports hasSourceText=false). The WebUI itself ALWAYS sends
timelineId + fontId + generatorVersion + sourceText on text sends.

Auto-start logic unchanged. Reply gains `timelineId` + `uploadComplete`.
Recovery from any upload error = full re-Send with a FRESH timelineId.

### 1.6 Metadata lifecycle (unchanged from v5)

### 1.7 /api/status — only 3 new fields (unchanged)

`scrollTimelineId, scrollUploadComplete, scrollHasSourceText`.

### 1.8 GET /api/scroll/meta (unchanged from v5)

Copy under lock → serialize outside; `PsramJsonDocument doc(16384)`;
`capacity()==0` → 507; `overflowed()` → 507.

### 1.9 commandStartScroll — atomic, enum errors, E6 pre-lock validation

```cpp
// BEFORE the lock (E6): extract payload timelineId into a stack buffer.
char payloadTimelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
const char* raw = payload["timelineId"] | "";
const size_t rawLen = strlen(raw);
if (rawLen > MAX_SCROLL_TIMELINE_ID_CHARS) { sendError(400, "timeline id too long"); return; }
if (rawLen > 0 && !validateMetaIdString(raw, MAX_SCROLL_TIMELINE_ID_CHARS)) {
    sendError(400, "invalid timeline id"); return;
}
memcpy(payloadTimelineId, raw, rawLen);   // never compare a truncated ID

enum class StartScrollError : uint8_t {
    None, TimelineMismatch, UploadIncomplete, NoCachedFrames
};
StartScrollError serr = StartScrollError::None;
withScrollLock([&]() {
    const bool timelineBacked = meta.timelineId[0] != '\0';
    const bool hasFrames = runtimeState().scrollFrameCount > 0 &&
                           runtimeScrollFrameBufferReady();
    if (timelineBacked) {
        if (rawLen > 0 && strcmp(payloadTimelineId, meta.timelineId) != 0) {
            serr = StartScrollError::TimelineMismatch; return;
        }
        if (!meta.uploadComplete) {            // D2: enforced even when the
            serr = StartScrollError::UploadIncomplete; return;   // payload has
        }                                       // no timelineId
    }
    if (!hasFrames) { serr = StartScrollError::NoCachedFrames; return; }
});
// map OUTSIDE the lock: TimelineMismatch/UploadIncomplete -> 409,
// NoCachedFrames -> 400 (existing message)
```

---

## 2. WebUI changes (data/app.js)

### 2.1 Constants (unchanged from v5)

`SCROLL_GENERATOR_VERSION`, `SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES = 12*1024`;
both ID constants must pass `validateMetaIdString` (test enforces).

### 2.2 scroll state additions + reset rules

As v5, plus E4:

```js
scroll.restoredTextTruncated = false;
```

Reset rules:

```text
markScrollTextDirty()          : framesTimelineId = "";
                                 restoredTextTruncated = false
stopScroll() / GPIO reset path : clear pendingScrollMeta/restored*/warning/
                                 restoredTextTruncated;
                                 KEEP timelineId and framesTimelineId
startScroll() (new Send)       : pendingScrollMeta = null;
                                 restoredSourceText = "";
                                 restoredFromFirmwareMeta = false;
                                 restoreWarning = "";
                                 restoredTextTruncated = false;
                                 then fresh timelineId; framesTimelineId =
                                 timelineId after prepare succeeds
clean restore start            : restoreWarning = "";
                                 restoredTextTruncated = false
```

Warning helper (E5) — use for ALL restore warnings (truncation, version
mismatch, frameCount mismatch, unsent-edit):

```js
function setScrollRestoreWarning(message) {
  if (!message) return;
  scroll.restoreWarning = scroll.restoreWarning
    ? `${scroll.restoreWarning}\n${message}`
    : message;
  // updateScrollUi renders multi-line warnings
}
```

### 2.3 Upload

As v5 (generation guard, fresh timelineId per Send, metadata on first chunk,
timelineId + chunkIndex on every chunk, D4 budget guard with 1-frame throw,
one full retry on any 409 with fresh timelineId), plus SF1:

```js
// SF1: first chunk may carry fewer frames than SCROLL_UPLOAD_CHUNK_FRAMES.
// The chunk loop must slice by a running offset, not a fixed stride:
const firstChunkFrames = chooseFirstChunkFrames(buildFirstChunkPayload);
let offset = 0, chunkIndex = 0;
while (offset < frames.length) {
  const size = chunkIndex === 0 ? firstChunkFrames : SCROLL_UPLOAD_CHUNK_FRAMES;
  const chunk = frames.slice(offset, offset + size);
  // POST with { chunkIndex, chunkFrames: chunk.length, totalFrames, ... }
  offset += chunk.length;
  chunkIndex++;
}
// chunkIndex increments by 1 per chunk regardless of chunk size; firmware
// validates order by chunkIndex and total by frame counts, never by stride.
```

### 2.4 Startup — text restore (E4, E5)

As v5, with these replacements:

```js
scroll.restoreWarning = "";              // clean slate
scroll.restoredTextTruncated = false;    // E4
...
setScrollTextFromFirmware(restoredText);
const valueAfterSanitize = $("scroll-text")?.value || "";
if (valueAfterSanitize && valueAfterSanitize !== restoredText) {
  scroll.restoredTextTruncated = true;   // E4
  setScrollRestoreWarning(               // E5
    "硬件滚动文字超过 WebUI 输入上限，已截断显示；预览仅供参考。");
}
...
if (meta.fontId !== TEXT_SCROLL_FONT_MODEL ||
    meta.generatorVersion !== SCROLL_GENERATOR_VERSION) {
  setScrollRestoreWarning(               // E5: appends, does not overwrite
    "文字已从硬件恢复，但字体/生成器版本不同，预览可能与 LED 不一致。");
}
```

Unsent-edit guard also uses `setScrollRestoreWarning`. Everything else
(guard-before-bind, fps clamp, direct-on-6.4 regen call) unchanged from v5.

### 2.5 Page 6.4 entry — regen (E4)

As v5, with the binding condition extended:

```js
if (!scroll.restoredTextTruncated &&          // E4
    exactGeneratorMatch(meta) &&
    scroll.frames.length === Number(meta.frameCount || 0)) {
  scroll.framesTimelineId = String(meta.scrollTimelineId || "");
} else {
  scroll.framesTimelineId = "";
  if (scroll.frames.length !== Number(meta.frameCount || 0)) {
    setScrollRestoreWarning(
      "文字已恢复，但本地重新生成的帧数与硬件不一致；预览仅供参考。");
  }
}
```

frameIndex apply + preview render + timer logic unchanged from v5.

### 2.6 Timeline-mismatch refetch (unchanged from v5)

### 2.7 No other sync changes

---

## 3. Implementation order

```text
1. web_json.cpp \uXXXX decoding (+ curl escape tests)
2. config.h limits; utils validators
3. state.h/.cpp: meta struct, text buffer alloc, invalidate/clear helpers,
   invariant comments (EH-C)
4. web_api.cpp: upload handler (E1/E2/E3 validation order, D3 rejects,
   invalidate call sites, 507/413/400/409s)
5. web_api.cpp: status fields, /api/scroll/meta, commandStartScroll (E6, D2, D8)
6. app.js: constants, scroll fields + reset rules (E4), upload loop (SF1),
   D4 budget guard, generation guard, fresh-id retry
7. app.js: restore functions (E4/E5), mismatch refetch, warning line in
   index.html (multi-line capable)
8. Tests
```

## 4. Test checklist

All v5 tests remain, plus:

```text
First-chunk malformed upload (E1, E2)
- append:false, timelineId, totalFrames=10, first chunk has 11+ frames
  -> 409 "too many frames", cache invalidated, start_scroll then 409/400
- append:false with timelineId and missing/zero totalFrames -> 400; no
  unplayable timeline-backed cache is ever created
Metadata validation (E3, E6)
- fontId present WITHOUT sourceText but invalid charset -> 400
- generatorVersion present WITHOUT sourceText but invalid -> 400
- start_scroll timelineId longer than MAX_SCROLL_TIMELINE_ID_CHARS -> 400,
  no truncated comparison
D10/E4 exactness
- oversized third-party text truncates; regenerated frameCount coincidentally
  equals meta.frameCount -> framesTimelineId STILL stays ""
Warnings (E5)
- oversized text + generator mismatch -> BOTH warnings visible
Upload loop (SF1)
- large text forcing reduced first chunk: total uploaded frame count exactly
  equals totalFrames (no duplicate/skipped frames at the chunk-1 boundary);
  firmware reports uploadComplete=true and plays correctly
```

v5 checklist highlights that still apply verbatim: 4096-byte ASCII accept,
frames-only compatibility, D1 400s, D2 partial-upload start reject, D3
complete-then-append reject, escape round-trips, race/stale-upload, restore
paths (boot / direct-6.4 / paused / stopped / second device), stale-frame
regen, input-overwrite guards, stop semantics, buffer invalidation,
boot-time + status-size regressions.
