#pragma once
#include <Arduino.h>
#include "config.h"

// 中文说明：LED 物理传输抽象层。业务代码（led_renderer / scroll / button_animation）
// 只通过这里的接口输出像素，不直接调用 ESP-IDF RMT API。传输固定为 RMT，
// DMA 由 RINACHAN_LED_RMT_WITH_DMA 选择（见 config.h / platformio.ini）。
//
// English: thin LED transport. The implementation is ESP-IDF RMT; pixel indices
// passed in are PHYSICAL (already serpentine-mapped by led_renderer). Color
// values are the *unscaled* 0..255 RGB; per-pixel brightness scaling is applied
// inside the driver so that behaviour matches the previous
// Adafruit_NeoPixel::setBrightness() semantics.

namespace leddrv {

// Initialise the transport. Returns true on success. Safe to call once at boot.
bool begin();

// True if the transport initialised successfully and can transmit.
bool ready();

// Set the brightness applied to every subsequent setPixel() (0..255).
void setBrightness(uint8_t brightness);

// Stage one physical LED. r/g/b are unscaled 0..255 values.
void setPixel(uint16_t physicalIndex, uint8_t r, uint8_t g, uint8_t b);

// Stage all LEDs off (does not transmit).
void clear();

// Transmit the staged buffer to the strip. Returns true on success.
// Blocks until the transaction has been handed off / completed, mirroring the
// previous Adafruit strip.show() semantics so existing reset/gap timing holds.
bool refresh();

// ---- Diagnostics ----------------------------------------------------------
// Human-readable backend id: "rmt" or "rmt-dma".
const char* backendName();
// True when the RMT backend was built with DMA enabled.
bool dmaEnabled();
// Duration (microseconds) of the most recent refresh() transmit.
uint32_t lastRefreshUs();
// Largest refresh() transmit duration observed since boot.
uint32_t maxRefreshUs();
// Number of refresh() calls that reported a transport error.
uint32_t refreshFailCount();

} // namespace leddrv
