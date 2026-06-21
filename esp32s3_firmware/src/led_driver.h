#pragma once
#include <Arduino.h>
#include "config.h"

// 中文说明：LED 物理传输后端抽象层。
// 业务代码（led_renderer / scroll / button_animation）只通过这里的接口输出像素，
// 不直接依赖 Adafruit_NeoPixel 或 ESP-IDF RMT API。后端由编译开关
// RINACHAN_LED_BACKEND 选择（见 config.h），方便 A/B 测试与回滚。
//
// English: thin LED transport abstraction. The active backend is chosen at
// compile time (RINACHAN_LED_BACKEND); pixel indices passed in are PHYSICAL
// (already serpentine-mapped by led_renderer). Color values are the *unscaled*
// 0..255 RGB; per-pixel brightness scaling is applied inside the driver so that
// behaviour matches the previous Adafruit_NeoPixel::setBrightness() semantics
// regardless of backend.

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
// Human-readable backend id: "adafruit" | "rmt" | "rmt-dma".
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
