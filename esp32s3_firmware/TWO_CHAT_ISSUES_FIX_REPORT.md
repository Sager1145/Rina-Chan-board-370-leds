# Two Chat Issues Fix Report

## Scope

This package fixes the two issues discussed in the chat:

1. Boot first-frame garble / random LED data before the first valid saved face.
2. 6.4 text-scroll FPS control layout misalignment on mobile, compared with the 6.1 brightness control layout.

## 1. Boot first-frame garble fix

### Files changed

- `src/main.cpp`
- `src/config.h`

### Changes

`setup()` now clamps the LED data pin low immediately at boot, before `Serial.begin()` and before the first `ledStripBegin()` call:

```cpp
pinMode(LED_PIN, OUTPUT);
digitalWrite(LED_PIN, LOW);
delay(LED_BOOT_DATA_LOW_HOLD_MS);
delayMicroseconds(LED_SIGNAL_RESET_US);
```

Boot timing constants were made more conservative:

```cpp
constexpr uint16_t LED_BOOT_DATA_LOW_HOLD_MS        = 20;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS           = 350;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS       = 120;
```

This reduces the chance that the WS2812/SK6812 data line floats or clocks noise before the first intentional clear/show sequence.

## 2. FPS control mobile layout fix

### Files changed

- `data/styles.css`
- `data/styles.css.gz`

### Changes

The FPS control area is inside `.row > .field.scroll-fps-control`, unlike the 6.1 brightness control. The parent `.row` is flex-wrap, and the old FPS row depended on `.push-right { margin-left:auto; }`, which can fail on narrow screens.

A page-specific CSS override was appended to `data/styles.css`:

- Forces `#page-scroll .scroll-fps-control` to occupy 100% width.
- Changes only the FPS `.slider-step-row` into a 3-column grid.
- Keeps the reset button on the left.
- Keeps `-5` / `+5` pinned to the right.
- Keeps the range + number input row aligned like the 6.1 brightness control.
- Cancels the old `.push-right` margin behavior only inside this FPS control.

`data/styles.css.gz` was regenerated and verified to decompress exactly to `data/styles.css`.

## Build/upload note

This ZIP contains updated source and LittleFS data resources. The prebuilt `.pio/build/...` artifacts may be stale if they are not rebuilt locally.

Use the normal upload command from the project root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

The script should rebuild firmware and upload LittleFS.

## 追加修复：帧率控件 shrink-wrap 右侧空白

已进一步修复 `.row > .field.scroll-fps-control` 在手机端作为 flex item 发生 shrink-wrap 的问题。

新增/确认规则：

```css
#page-scroll .scroll-fps-control {
  flex: 1 1 100%;
  width: 100%;
  max-width: 100%;
  min-width: 0;
}

#page-scroll .row > .field.scroll-fps-control,
#page-scroll .row > .scroll-fps-control {
  flex: 1 1 100%;
  width: 100%;
  max-width: 100%;
  min-width: 0;
}
```

目的：强制帧率控制块撑满 `.row` 的整行宽度，消除右侧大块空白，使 `-5/+5` 按钮、滑动条和数字输入框与卡片右边缘对齐。

