# LED Asset Format Specification

## Geometry

- Matrix: 22 x 18 logical grid
- Real LEDs: 370
- Row lengths: [18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16]
- Static frame encoding: `M370`, 93 hex characters per frame

## M370 bit order

Loop order:

```python
for y in range(18):
    for x in range(22):
        if logical_to_led_index(x, y) is not None:
            emit_bit(pixel[y][x])
```

Then pad with `0` until the bit count is divisible by 4, and convert every 4 bits to one uppercase hex nibble.

## RNT2 timeline row

```text
start_frame|hold_frames|hold_ms|m370_hex
```

No frame list allocation is required. The ESP32 can read a line, draw one `m370_hex`, sleep `hold_ms`, then discard the line.

## RBITMAP1

```json
{"format":"rbitmap1","encoding":"row_hex_msb_first","w":8,"h":8,"row_hex":["00","18",...]}
```

For each row, bit 7 is the left-most pixel in the first byte. Unused trailing bits in the last byte are `0`.
