# Text Scroll 6.4 — Source-Text Sync Plan v3 (final, supersedes v2)

Core model unchanged: WebUI uploads generated M370 frames **plus** Unicode source
text + metadata; firmware stores both in RAM; WebUI rebuilds preview locally from
text; firmware never sends frames/bitmaps back; only frameIndex syncs during
playback.

## Changes from v2 (per second audit)

```text
B1  append chunks REQUIRE timelineId when meta has one (was: only-if-present)
B2  /api/scroll/meta doc: 8192 -> 16384 (PSRAM, escaping headroom)
B3  first-chunk size cap: fewer frames when sourceText is large
B4  restoreScrollPreviewIfNeeded: timeline+frameCount match, not frames.length
B5  startup restore goes through scroll.restoredSourceText pending state
B6  timeline-mismatch refetch never overwrites unsent user edits
B7  uploadComplete invariant: false whenever frame buffer is invalidated
    (incl. the existing m370ToPackedBits-failure path that zeroes frameCount)
B8  /api/scroll/meta: copy under scrollMutex, serialize OUTSIDE the lock
B9  507 when sourceText present but its buffer allocation failed
B10 upload generation guard (double-Send race) + one full retry on
    start_scroll 409
M1  restore must not mark scroll.dirty (verified: sanitize doesn't touch it;
    enforced explicitly anyway)
M2  uiFps clamped to SCROLL_FPS_MIN..MAX on restore
M3  no Unicode normalization anywhere; upload the post-sanitize text;
    sanitize must be idempotent
M4  version-bump discipline test added
```

---

## 0. Hard rules

```text
- sourceText is required ONLY for preview restore. Playback (start_scroll, pause,
  resume, step, stop) keeps working for frames-only uploads (curl, scripts,
  third-party clients).
- No ark12.json fetch and no frame regeneration during WebUI startup. Startup
  restores only the text (into pending state + input field). Regen happens on
  page-6.4 entry.
- Identity = fontId + generatorVersion strings. No runtime hashing.
- Hard firmware text limit is BYTES. Code-point cap is lenient (UI counts
  visible chars excluding emoji format controls; raw count can exceed 1000).
- All metadata + source-text access under scrollMutex; serialize outside it.
- uploadComplete is true ONLY while the corresponding frame buffer is valid.
  hasSourceText and uploadComplete are independent flags.
- No Unicode normalization (no NFC/NFD) at any stage. The WebUI uploads the
  post-sanitizeScrollTextInput text; firmware stores/returns exact UTF-8 after
  JSON decoding. Restored text re-passes sanitize, which must be idempotent.
- Matrix dims fixed 22x18 / 370 LEDs — not part of metadata.
```

---

## 1. Firmware changes

### 1.1 config.h

```cpp
constexpr uint16_t MAX_SCROLL_TEXT_BYTES        = 4096;
constexpr uint16_t MAX_SCROLL_TEXT_CODEPOINTS   = 2048;  // lenient raw cap
constexpr uint8_t  MAX_SCROLL_TIMELINE_ID_CHARS = 47;
constexpr uint8_t  MAX_SCROLL_FONT_ID_CHARS     = 47;
constexpr uint8_t  MAX_SCROLL_GENERATOR_CHARS   = 47;
```

### 1.2 state.h — ScrollTimelineMeta

```cpp
struct ScrollTimelineMeta {
    char     timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1]     = {0};
    char     fontId[MAX_SCROLL_FONT_ID_CHARS + 1]             = {0};
    char     generatorVersion[MAX_SCROLL_GENERATOR_CHARS + 1] = {0};
    uint16_t sourceTextByteLength = 0;
    uint16_t totalFramesExpected  = 0;
    uint16_t framesReceived       = 0;
    uint16_t nextChunkIndex       = 0;
    uint8_t  uiFps                = 0;      // echo-only for input restore
    bool     uploadComplete       = false;  // frame buffer valid + complete
    bool     hasSourceText        = false;  // text available for restore
};
```

- Source-text buffer (`MAX_SCROLL_TEXT_BYTES + 1`) allocated in
  `RuntimeStore::initScrollFrameBuffer()` alongside `scrollFrameBits_`
  (PSRAM-preferred). Accessors `runtimeScrollMeta()` / `runtimeScrollSourceText()`
  (latter may return nullptr on alloc failure — see 1.5 step 2).
- Timing: `scrollIntervalMs` stays canonical; `uiFps` is echo-only.
- Extend the lock-contract comment: ScrollTimelineMeta + source-text buffer are
  guarded by `scrollMutex`. Copy under lock, serialize outside (see 1.8).

Add a single helper used by EVERY path that invalidates frames:

```cpp
// call inside withScrollLock wherever scrollFrameCount is zeroed/reset
static void invalidateScrollUploadLocked() {
    meta.uploadComplete    = false;
    meta.framesReceived    = 0;
    meta.totalFramesExpected = 0;
    meta.nextChunkIndex    = 0;
    // hasSourceText / timelineId / text untouched (restore may still work)
}
```

Call sites (B7): append:false reset in handleApiScroll, the existing
`m370ToPackedBits` failure path that does `scrollFrameCount = 0`
(web_api.cpp ~line 729), and any future buffer-clear path.

### 1.3 web_json.cpp — `\uXXXX` decoding (unchanged from v2)

`extractJsonStringAt()` gains a `case 'u':` that reads 4 hex digits, combines
surrogate pairs, substitutes U+FFFD for lone surrogates, appends UTF-8, and
returns false on malformed hex (caller responds 400).

### 1.4 utils — `validateUtf8(const char*, size_t, uint16_t& codePoints)`

Rejects invalid sequences, overlong encodings, surrogates, > U+10FFFF.

### 1.5 /api/scroll upload handler

Keep manual frame streaming. Metadata via raw helpers (safe after 1.3).

First chunk (`append:false`), strict order:

```text
1. Read timelineId / sourceText / fontId / generatorVersion / fps / intervalMs /
   totalFrames from body.
2. Validate BEFORE touching state:
   - timelineId length <= MAX_SCROLL_TIMELINE_ID_CHARS
   - totalFrames <= MAX_SCROLL_FRAMES                          -> else 413
   - if sourceText present:
       * source-text buffer allocated?                         -> else 507 (B9)
       * byte length <= MAX_SCROLL_TEXT_BYTES                  -> else 413
       * validateUtf8 passes                                   -> else 400
       * codePoints <= MAX_SCROLL_TEXT_CODEPOINTS              -> else 413
3. stopFirmwareScroll(false); reset frame counters (existing behavior).
4. withScrollLock: invalidateScrollUploadLocked(); store timelineId / fontId /
   generatorVersion / uiFps / sourceText / hasSourceText;
   totalFramesExpected = totalFrames; nextChunkIndex = 1.
5. Stream/decode frames exactly as today. On m370ToPackedBits failure the
   existing zero-count path also runs invalidateScrollUploadLocked() (B7).
6. framesReceived = count; if totalFramesExpected > 0 &&
   framesReceived >= totalFramesExpected: uploadComplete = true.
```

sourceText stays OPTIONAL: a frames-only first chunk is accepted as today
(meta reset, hasSourceText=false, empty timelineId).

Append chunk (`append:true`) — B1 strict rule:

```text
if meta.timelineId is non-empty:
    request timelineId missing            -> 409 "timeline required"
    request timelineId != meta.timelineId -> 409 "timeline mismatch"
else:
    legacy frames-only append allowed (backward compat)
if body has chunkIndex and chunkIndex != meta.nextChunkIndex
                                          -> 409 "chunk out of order"
decode frames; framesReceived += count; nextChunkIndex++
if totalFramesExpected > 0 && framesReceived >= totalFramesExpected:
    uploadComplete = true
```

Distinct 409 messages so the WebUI restarts from chunk 0 (`append:false`).
Auto-start logic unchanged. Reply gains `timelineId` + `uploadComplete`.
Recovery from any upload error = full re-Send; no partial resume.

Body size (B3): no firmware change needed (WebServer reads Content-Length into
heap String; saved_faces POSTs are already larger), but the WebUI caps the
first chunk — see 2.3.

### 1.6 Metadata lifecycle

```text
created/replaced : first chunk of a new append:false upload
survives         : stop_scroll, pause/resume, GPIO stop, /api/frame, mode switch
                   (frames stay cached today; meta follows frames)
uploadComplete   : forced false by invalidateScrollUploadLocked() whenever the
                   frame buffer is cleared/invalidated (B7); hasSourceText is
                   NOT cleared by that — text restore can outlive frames
cleared fully    : only by the next append:false upload (or reboot)
```

### 1.7 /api/status — only 3 new fields

Extend `ScrollStateSnapshot` + `addScrollStateFields` (covers `/api/status` and
`/api/command` replies):

```text
scrollTimelineId, scrollUploadComplete, scrollHasSourceText
```

No fontId/generatorVersion/text in status.

### 1.8 GET /api/scroll/meta

Pattern (B2 + B8):

```cpp
ScrollTimelineMeta metaCopy;
static char textCopy[MAX_SCROLL_TEXT_BYTES + 1];  // or heap; never on 8KB stack
uint16_t frameCount, frameIndex; bool active, paused;
withScrollLock([&] {
    metaCopy = runtimeScrollMeta();
    if (metaCopy.hasSourceText && runtimeScrollSourceText())
        memcpy(textCopy, runtimeScrollSourceText(), metaCopy.sourceTextByteLength);
    textCopy[metaCopy.sourceTextByteLength] = '\0';
    frameCount = runtimeState().scrollFrameCount;
    frameIndex = runtimeState().scrollFrameIndex;
    active     = runtimeState().firmwareScrollActive;
    paused     = runtimeState().firmwareScrollPaused;
});
PsramJsonDocument doc(16384);   // B2: 4KB text + escaping + fields headroom
// build + sendJsonDocument OUTSIDE the lock
```

Response fields as v2 (`ok, scrollTimelineId, hasSourceText, sourceText,
sourceTextBytes, fontId, generatorVersion, uiFps, scrollIntervalMs, frameCount,
frameIndex, uploadComplete, firmwareScrollActive, firmwareScrollPaused`).
Empty meta → `{"ok":true,"hasSourceText":false,"scrollTimelineId":""}`.
Register route + OPTIONS in `startWebServer()`.

### 1.9 commandStartScroll

```text
if payload has timelineId:
    != meta.timelineId        -> 409 "timeline mismatch"
    !meta.uploadComplete      -> 409 "upload incomplete"
always (existing): scrollFrameCount > 0 && buffer ready
NO sourceText requirement.
```

---

## 2. WebUI changes (data/app.js)

### 2.1 Constants

```js
const SCROLL_GENERATOR_VERSION = "webui-scrollgen-6.4.2";
// fontId = TEXT_SCROLL_FONT_MODEL. Bump SCROLL_GENERATOR_VERSION on any change
// to TEXT_SCROLL_CHAR_SPACING, blank margins, textScrollVerticalOffset(), or
// extractFrameFromTextImage. Bump fontModel when ark12.json changes.
```

### 2.2 scroll state additions

```js
scroll.timelineId = "";
scroll.uploadGeneration = 0;          // B10
scroll.restoredSourceText = "";       // B5
scroll.restoredFromFirmwareMeta = false;
scroll.restoreWarning = "";           // rendered by updateScrollUi (add a small
                                      // warning line to the 6.4 page in index.html)
let pendingScrollMeta = null;         // module-level
let scrollMetaFetchInFlight = false, lastScrollMetaFetchAt = 0;
// reset timelineId/restored*/pendingScrollMeta in resetScrollControlsAfterButton()
// and stopScroll()
```

### 2.3 Upload (uploadFirmwareScrollTimeline / startScroll)

- B10 generation guard:

```js
// in startScroll(), before upload:
const generation = ++scroll.uploadGeneration;
// in uploadFirmwareScrollTimeline(), before EACH chunk POST and before start_scroll:
if (generation !== scroll.uploadGeneration) throw new Error("stale upload cancelled");
```

- New `scroll.timelineId = `scroll-${Date.now()}-${rand4}`` per Send.
- First chunk adds `timelineId, sourceText (post-sanitize), fontId:
  TEXT_SCROLL_FONT_MODEL, generatorVersion: SCROLL_GENERATOR_VERSION, fps,
  intervalMs, source: "webui_text_scroll_frames_with_source_text"`.
- EVERY chunk (incl. appends) carries `timelineId` (B1 makes it mandatory).
- B3 first-chunk cap (actual chunk size is 24, not 32):

```js
const sourceTextBytes = new TextEncoder().encode(sourceText).length;
const firstChunkFrames = sourceTextBytes > 2048
  ? Math.min(12, SCROLL_UPLOAD_CHUNK_FRAMES)
  : SCROLL_UPLOAD_CHUNK_FRAMES;   // later chunks: SCROLL_UPLOAD_CHUNK_FRAMES (24)
```

- `start_scroll` payload gains `timelineId`.
- Retry rule (B10): on 409 from any chunk OR from `start_scroll`, restart the
  whole upload once from chunk 0 (`append:false`, same timelineId regenerated);
  second failure surfaces the existing alert path.

### 2.4 Startup — text restore via pending state (B5, B6, M1, M2)

Hook into `runPostBootDeferredReads` after `preloadFirmwareRuntimeState()`.
Gate on status renderer fields: `scrollHasSourceText && scrollTimelineId &&
scrollTimelineId !== scroll.timelineId`.

```js
function setScrollTextFromFirmware(text) {          // M1: never marks dirty
  const el = $("scroll-text");
  if (!el) return false;                            // defensive; element is
  if (el.value) return false;                       //  static in index.html
  el.value = text;                                  // programmatic set fires no
  sanitizeScrollTextInput(true);                    //  input event -> dirty
  applyTextScrollInputFont();                       //  untouched (verified)
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

    // B6: never clobber unsent user edits on mismatch-triggered refetch
    const userHasUnsentEdit = scroll.dirty && $("scroll-text")?.value;
    if (userHasUnsentEdit && source === "timeline_mismatch") {
      scroll.restoreWarning =
        "硬件正在播放另一段滚动文字；输入框有未发送的编辑，未自动覆盖。";
      updateScrollUi();
      return false;
    }

    scroll.restoredSourceText = String(meta.sourceText ?? "");   // B5
    pendingScrollMeta = meta;
    scroll.timelineId = String(meta.scrollTimelineId || "");
    scroll.restoredFromFirmwareMeta = true;
    setScrollTextFromFirmware(scroll.restoredSourceText);        // fills if empty
    syncScrollFpsUi(                                             // M2 clamp
      clamp(Number(meta.uiFps) || DEFAULT_SCROLL_FPS, SCROLL_FPS_MIN, SCROLL_FPS_MAX));
    if (meta.fontId !== TEXT_SCROLL_FONT_MODEL ||
        meta.generatorVersion !== SCROLL_GENERATOR_VERSION) {
      scroll.restoreWarning =
        "文字已从硬件恢复，但字体/生成器版本不同，预览可能与 LED 不一致。";
    }
    updateScrollUi();
    return true;
  } finally { scrollMetaFetchInFlight = false; }
}
```

No ark12.json fetch, no regen here. `scroll.active/paused/firmwareBacked` come
from the existing `applyFirmwareRuntimeState()` poll.

### 2.5 Page 6.4 entry — regen (B4)

Call from the `if (id === "scroll")` branch of `switchPage`, after
`ensureScrollFontsLoaded()`:

```js
function localTimelineMatchesMeta(meta) {           // B4
  return scroll.timelineId &&
         scroll.timelineId === String(meta.scrollTimelineId || "") &&
         scroll.frames.length === Number(meta.frameCount || 0);
}

async function restoreScrollPreviewIfNeeded() {
  setScrollTextFromFirmware(scroll.restoredSourceText);  // B5: late DOM fill
  if (!pendingScrollMeta) return;
  const meta = pendingScrollMeta;
  if (localTimelineMatchesMeta(meta)) { pendingScrollMeta = null; return; }
  try {
    await prepareTextScrollTimelineAsync(true);     // real boolean signature;
  } catch (_) { return; }                           // reads #scroll-text
  pendingScrollMeta = null;
  if (scroll.frames.length !== Number(meta.frameCount || 0)) {
    scroll.restoreWarning =
      "文字已恢复，但本地重新生成的帧数与硬件不一致；预览仅供参考。";
    // keep controls usable; do NOT clear frames or re-upload
  }
  // frameIndex: existing status poll writes renderer.scrollFrameIndex into
  // scroll.frameIndex once frames exist — no manual fetch
  if (scroll.active && !scroll.paused) restartScrollPreviewTimer();
  else setScrollPreviewFrame(scroll.frames[scroll.frameIndex] || blankFrame(),
                             "text_scroll_restore_preview",
                             scroll.paused ? "scroll_paused" : "scroll");
  updateScrollUi();
}
```

`prepareTextScrollTimeline` sets `scroll.signature`/`scroll.dirty=false` itself,
so restored text is not treated as an unsent edit afterward (M1).

### 2.6 Timeline-mismatch refetch (guarded)

In `applyFirmwareRuntimeState`, after the scroll block:

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

### 2.7 No other sync changes

Polling, visibilitychange, pause/resume/step index sync already correct; no
per-event meta fetches.

---

## 3. Implementation order

```text
1. web_json.cpp \uXXXX decoding (+ curl escape tests)
2. config.h limits; utils validateUtf8
3. state.h/.cpp: meta struct, text buffer alloc, invalidateScrollUploadLocked,
   lock docs
4. web_api.cpp: upload handler (validation, B1 append rule, B7 call sites,
   B9 507, 409s)
5. web_api.cpp: status fields, /api/scroll/meta (B2/B8 pattern),
   commandStartScroll
6. app.js: constants, scroll fields, upload payload, B3 first-chunk cap,
   B10 generation guard + retry
7. app.js: setScrollTextFromFirmware / restoreScrollTextFromFirmware /
   restoreScrollPreviewIfNeeded / mismatch refetch; warning line in index.html
8. Tests
```

## 4. Test checklist

```text
Upload/playback
- ASCII, CJK, emoji (ZWJ 👨‍👩‍👧‍👦, VS16, skin tones): upload OK, plays
- frames-only curl upload: plays; all commands work; scrollHasSourceText=false
- >4096-byte text -> 413; invalid UTF-8 -> 400; text-buffer alloc failure -> 507
- append without timelineId while meta has one -> 409 (B1)
- out-of-order chunk / wrong timelineId -> 409; WebUI restarts once
JSON escapes
- curl "sourceText":"你好" -> stored 你好; lone surrogate -> U+FFFD
Race / stale upload (B10)
- Send A, immediately Send B: A's late chunks rejected (timelineId), A's stale
  generation aborts client-side; start_scroll 409 -> one full re-upload
Large metadata (B2/B3)
- ~4096-byte text: first chunk uses reduced frame count, upload succeeds;
  /api/scroll/meta returns intact text (no doc overflow)
Restore
- refresh mid-scroll: text in #scroll-text at boot with NO ark12.json request
  (verify devtools); regen on 6.4 entry; frameCount matches; index converges
- refresh while paused: paused frame rendered; refresh after stop: text
  restored, nothing auto-plays
- second device mid-scroll: same restore path
- version mismatch (fake old generatorVersion): text restored + warning,
  controls usable, no re-upload (M4)
- frames but no sourceText: notice shown, controls usable
Input overwrite (B6)
- unsent local edit + other device starts new timeline -> input NOT overwritten,
  warning shown
Stale local frames (B4)
- old scroll.frames + firmware timeline changed -> 6.4 entry regenerates from
  firmware text, does not reuse old frames
Lazy DOM (B5)
- boot on another page, enter 6.4 later -> #scroll-text filled from pending state
Buffer invalidation (B7)
- force invalid frame mid-upload (bad M370 via curl) -> frameCount 0 AND
  scrollUploadComplete false; hasSourceText per lifecycle; restore behavior sane
Regression
- boot time unchanged with no cached scroll; status delta = 3 fields;
  GPIO B1–B3 stop still resets 6.4 UI
```
