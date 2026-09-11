# Scroll-text rasterizer — port spec (WebUI app.js → Swift)

Verified against the legacy `app.js` and the shipped `ark12.json` on 2026-09-11. Output
must be bit-identical to the WebUI so firmware-side restore/identity checks keep working.

## Constants
| name | value | app.js |
|---|---|---|
| fontId (`fontModel`) | `"ark_pixel_12px_fusion_bitmap_v4"` | 129 |
| generatorVersion | `"webui-scrollgen-6.4.2"` | 3066 |
| charSpacing | 0 (still add it between consecutive non-space glyphs) | 142 |
| spaceColumns | 6 | 143 |
| missing glyph | U+25A1 | 144 |
| maxTextChars (visible) | 1000 | 124 |
| maxTextBytes (UTF-8) | 4096 | 3031 |
| maxFrames | 3072 | 122 |
| uploadChunkFrames | 24, 20 ms gap between chunks | 123, 10966 |
| timelineId | `"scroll-" + base36(Date.now()) + "-" + 4 random base36 chars` | 10884 |
| fps→intervalMs | `max(1, round(1000/fps))` | 10908 |
| COLS, ROWS | 22, 18 | |

## ark12.json (actual file)
- Header: rows 12, lineHeight 12, ascent 10, descent 2, defaultAdvance 12. 33,476 glyphs.
- Keys: **uppercase hex, zero-padded to at least 4 digits** (`"0041"`, `"1F600"`, `"FE82B"`). Lookup = `String(format:"%04X", cp)`.
- Value: `[advance, width, height, xOffset, yOffset, dstY, rowsHex]`. `rowsHex` = 12 rows joined by `/`, each row a hex string of `ceil(width/4)` nibbles (left-pad with `0` if shorter), **MSB-first: bit 7 of the first nibble pair = local x=0**. Decode each nibble to 4 bits, concatenate, truncate to `width`. (Example `0041` = `[6,6,12,0,-2,0,"00/00/20/20/50/50/70/88/88/88/00/00"]`.)
- Regular glyphs: yOffset −2, dstY 0. Emoji: yOffset −1. Format controls (FE0E, 200D…) are zero-width `[0,0,0,0,0,0,""]`.
- No glyph for U+000A: newlines fall through to the missing-glyph box (same as the WebUI).

## 1. Text normalisation (app.js 4102–4156, 9819–9866, 11047)
Iterate by Unicode scalar (codepoint), not UTF-16 unit.
- `isEmojiFormatControl(cp)`: FE00–FE0F, 200D, 1F3FB–1F3FF, E0000–E007F.
- `isEmojiPresentationBase(cp)`: 00A9, 00AE, 203C, 2049, 2122, 2139, 2194–21AA, 231A–23FF, 2460–24FF, 25AA–27BF, 2934–2935, 2B05–2B55, 3030, 303D, 3297, 3299, 1F000–1FAFF.
- `normalizeEmojiPresentation(text)`: walk scalars; if cp is a VS (FE00–FE0F) and the previous emitted scalar is a presentation base → drop it (VS15 is appended by the rule below); if cp is a presentation base → emit cp then emit U+FE0E unless the next scalar is already a VS (in which case that VS is replaced by FE0E). Net: every base gets exactly one trailing FE0E, other VS removed. Everything else passes through.
- `truncate(text)`: count only scalars that are not format controls; stop when the visible count would exceed 1000.
- Byte check: `utf8.count > 4096` → refuse to send (alert), before rasterising.

## 2. Glyph model (app.js 4188–4229, 12151–12227)
```
struct Glyph { isSpace, advance, width, height, xOffset, yOffset, dstY, rows: [[Bool]] }
glyph(for cp):
  if the scalar is whitespace (Swift: `Character(scalar).isWhitespace` ≈ JS `!ch.trim()`) →
      Glyph(isSpace: true, advance: 6, width 0, height 0, offsets 0, rows [])
  raw = table[cp] ?? table[0x25A1]  (fatal if both missing)
  advance = raw.advance finite ? max(0, raw.advance) : max(1, defaultAdvance(12))
  height  = raw.height != 0 ? raw.height : (rows.count != 0 ? rows.count : 12)
  rows    = decoded bits (see above), each row padded right with false to `width`
pixel(g,x,y) = y < rows.count && x < rows[y].count && rows[y][x]
```

## 3. Bitmap assembly (app.js 4095–4100, 12110–12149, 12238–12253)
```
verticalOffset = clamp(floor((18 - 12)/2) + 2, 0, 17) = 5
chars   = scalars(normalizedText).filter { !isEmojiFormatControl }
glyphs  = chars.map(glyph(for:))
content = Σ advance + charSpacing for each pair of consecutive non-space glyphs
leading = trailing = COLS + 4 = 26
width   = max(COLS*2 + 8 /*52*/, leading + content + trailing)
bitmap  = [ROWS][width] Bool = false
x = leading (Double or Int; xOffset applied with round(x0 + xOffset))
for (i, g) in glyphs:
    if !g.isSpace: blit(g, x0: x)
    x += g.advance
    if next exists && !g.isSpace && !next.isSpace: x += charSpacing
blit(g, x0):
    baseX = Int((Double(x0) + Double(g.xOffset)).rounded())   // JS Math.round: half → +∞
    baseY = verticalOffset + g.dstY + g.yOffset                 // regular glyphs: 5 + 0 − 2 = 3
    for gy in 0..<g.height: y = baseY + gy; skip if y<0 || y>=ROWS
      for gx in 0..<g.width: if pixel(g,gx,gy): x = baseX+gx; if 0<=x<width: bitmap[y][x] = true
```

## 4. Frames (app.js 12255–12270, 11531–11540, 4313–4322)
```
maxOffset  = max(1, width - COLS)
frameCount = maxOffset + 1                           // > 3072 → abort before extracting
frame(offset): for y in 0..<ROWS, for x in validXRange(y):
    idx = ledIndex(x,y); srcX = offset + x
    bit(idx) = srcX < width && bitmap[y][srcX]        // outside bitmap → off
frames = (0...maxOffset).map(frame)
rotate frames so index 0 is the first frame with litCount > 0 (if any is lit)
```
Increasing offset moves the text LEFT on the board; 1 frame = 1 pixel. Playback wraps mod frameCount.
Pre-check (cheap, before rasterising): `scalarCount - COLS + 1 > 3072` → abort.

## 5. Upload (app.js 10850–11024)
BLOB_BEGIN kind "scroll" `{append:false,intervalMs,fps,totalFrames,timelineId,fontId,generatorVersion}`;
chunks of 24 frames (1128 B) — or up to `chunkMax/47` frames when smaller; then BLOB_END
`{start:false}` then `CMD start_scroll {timelineId, fps, intervalMs, sourceText, source:"ios_text_scroll_after_frames"}`.
On a conflict/identity error retry once with a fresh timelineId. Progress stages: 2 % → 4–34 % generating → 36–86 % uploading → 90 % → 98 % starting → 100 %.

## 6. Preview speed lock (app.js 10222–10453)
Constants: HW_RATE_WINDOW_MS 8000, MIN_SAMPLES 3, MIN_SPAN_MS 2000, MIN_FRAMES 3, FPS_MIN 0.2, FPS_MAX 120, EMA_ALPHA 0.4; PREVIEW_PHASE_DEADBAND 0.65 frames, GENTLE 0.97…1.03, CATCHUP 0.9…1.1 (when |err| ≥ 4), ALIGN_HORIZON 1000 ms, SLEW 0.04/s, interval blend α 0.18, phase-error low-pass α 0.25.
- On each EV_PREVIEW_SYNC: if `scrollTimelineId` ≠ local timeline or frameCount mismatch → identity mismatch (stop local preview, mark STALE). If paused/stepping → snap display index to `presentedFrameIndex`, ignore rate samples until seq+2.
- Rate: only `rateEligible` samples; least-squares slope of (t, unwrapped frame) over an 8 s window; needs ≥3 samples, ≥2 s span, ≥3 frames; clamp 0.2–120 fps; EMA 0.4 into measuredFps; blend `previewIntervalMs = prev*0.82 + (1000/measuredFps)*0.18`.
- Phase: `err = shortestRingDelta(presentedIndex, displayIndex, frameCount)` filtered with α 0.25; |err| < 0.65 → multiplier 1 ("locked"); else target = clamp(1 + err/horizonFrames, band) with horizonFrames = max(1, measuredFps·1 s); slew the multiplier ≤ 0.04 per second; tick delay = max(1, round(base/multiplier)). Each tick advances exactly one frame.

## 7. Restore on launch (app.js 11569–12009)
After connect: GET_SCROLL_META. If `uploadComplete && frameCount > 0 && fontId/generatorVersion match exactly && hasSourceText`: re-rasterise sourceText locally; if the local frame count equals `frameCount`, bind the timeline (`scrollTimelineId`), set fps from `uiFps`, set display index to `frameIndex`, and show the text in the input — unless the user already edited the input (then show the "restore conflict" warning instead). If counts differ or generator mismatch → warning only.
