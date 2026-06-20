# Packed frame migration Phase 1/2

This document records the intended active migration away from M370 string frames.

## Protocol decision

- LED frame payload is the theoretical minimum 370-bit packed frame.
- `FRAME_BYTES = (LED_COUNT + 7) / 8 = 47`.
- Bit order is logical LED index, little-endian within each byte:
  - LED 0 => byte 0 bit 0
  - LED 7 => byte 0 bit 7
  - LED 8 => byte 1 bit 0
  - LED 369 => byte 46 bit 1
- Unused bits in byte 46 must be zero.

## Phase 1 target

- `/api/frame` accepts only `application/octet-stream` with exactly 47 bytes.
- Runtime frame queue stores only packed bytes.
- WebUI sends 47-byte binary frames.
- WebUI reads current display frame from binary bytes and decodes locally for preview.

## Phase 2 target

- Saved faces use packed frame storage, not M370.
- Parts use packed masks/values or packed full frames.
- Scroll upload sends `N * 47` raw bytes per chunk.
- Debug tooling exports/imports packed binary or packed base64/hex only.

## Do not reintroduce

- No M370 command path.
- No `m370` field in API frame payloads.
- No status response field that contains a textual M370 frame.
