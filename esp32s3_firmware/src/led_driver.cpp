#include "led_driver.h"
#include "serial_log.h"
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

// 中文：__containerof 在部分核心版本可能未通过已包含头文件暴露，提供回退定义。
#ifndef __containerof
#define __containerof(ptr, type, member) \
    ((type*)((char*)(ptr) - offsetof(type, member)))
#endif

// 中文说明：本文件实现 LED 抽象层的两种后端：
//   1. Adafruit_NeoPixel（默认，行为与历史版本完全一致，作为安全回退）
//   2. Espressif RMT（ESP-IDF 5.x 新 RMT 驱动），可选启用 DMA
// 后端选择见 config.h 的 RINACHAN_LED_BACKEND。两个后端互斥编译，避免在
// 不支持新 RMT 驱动的核心版本上引入头文件依赖。

namespace leddrv {

// Shared diagnostics counters (updated by whichever backend is active).
static uint32_t sLastRefreshUs = 0;
static uint32_t sMaxRefreshUs = 0;
static uint32_t sRefreshFail = 0;
static bool sReady = false;

uint32_t lastRefreshUs() { return sLastRefreshUs; }
uint32_t maxRefreshUs() { return sMaxRefreshUs; }
uint32_t refreshFailCount() { return sRefreshFail; }
bool ready() { return sReady; }

static inline void recordRefresh(uint32_t startUs, bool ok) {
    const uint32_t dur = micros() - startUs;
    sLastRefreshUs = dur;
    if (dur > sMaxRefreshUs)
        sMaxRefreshUs = dur;
    if (!ok)
        ++sRefreshFail;
}

// brightness scale: matches the assessment spec (component * brightness / 255).
static inline uint8_t scale8(uint8_t value, uint8_t brightness) {
    return static_cast<uint8_t>((static_cast<uint16_t>(value) * brightness) / 255U);
}

} // namespace leddrv

// ===========================================================================
// Backend 1: Adafruit_NeoPixel (default / fallback)
// ===========================================================================
#if RINACHAN_LED_BACKEND == RINACHAN_LED_BACKEND_ADAFRUIT

#include <Adafruit_NeoPixel.h>

namespace leddrv {

static Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);

const char* backendName() { return "adafruit"; }
bool dmaEnabled() { return false; }

bool begin() {
    strip.begin();
    strip.setBrightness(DEFAULT_BRIGHTNESS);
    strip.clear();
    sReady = true;
    RLOG_INFO("LEDDRV", "event=begin backend=adafruit dma=0 ready=1");
    return true;
}

// Adafruit applies brightness inside show(); forward the value natively so the
// default build is byte-for-byte identical to the previous firmware.
void setBrightness(uint8_t brightness) {
    strip.setBrightness(brightness);
}

void setPixel(uint16_t physicalIndex, uint8_t r, uint8_t g, uint8_t b) {
    strip.setPixelColor(physicalIndex, strip.Color(r, g, b));
}

void clear() { strip.clear(); }

bool refresh() {
    const uint32_t startUs = micros();
    strip.show();
    recordRefresh(startUs, true);
    return true;
}

} // namespace leddrv

// ===========================================================================
// Backend 2: Espressif RMT (ESP-IDF 5.x new RMT TX driver), optional DMA
// ===========================================================================
#elif RINACHAN_LED_BACKEND == RINACHAN_LED_BACKEND_RMT

#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"
#include "esp_err.h"
#include "esp_attr.h" // IRAM_ATTR
#include "freertos/FreeRTOS.h"
#include "freertos/task.h" // xPortGetCoreID

namespace leddrv {

// ---- WS2812 byte encoder (mirrors espressif/led_strip's RMT encoder) -------
typedef struct {
    rmt_encoder_t base;
    rmt_encoder_t* bytes_encoder;
    rmt_encoder_t* copy_encoder;
    int state;
    rmt_symbol_word_t reset_code;
} ws2812_encoder_t;

// 中文：encode/reset 跑在 RMT ISR 上下文里。放进 IRAM 可避免 flash cache 关闭
// (Wi-Fi / flash 写入) 时 ISR 取指 cache miss 导致的停顿/乱码——这是 Espressif
// 官方对 WS2812 在 Wi-Fi 负载下抗抖动的核心建议之一。
static IRAM_ATTR size_t ws2812_encode(rmt_encoder_t* encoder, rmt_channel_handle_t channel,
                                      const void* primary_data, size_t data_size,
                                      rmt_encode_state_t* ret_state) {
    ws2812_encoder_t* enc = __containerof(encoder, ws2812_encoder_t, base);
    rmt_encoder_handle_t bytes = enc->bytes_encoder;
    rmt_encoder_handle_t copy = enc->copy_encoder;
    rmt_encode_state_t session_state = RMT_ENCODING_RESET;
    rmt_encode_state_t state = RMT_ENCODING_RESET;
    size_t encoded = 0;
    switch (enc->state) {
    case 0: // transmit the RGB bytes
        encoded += bytes->encode(bytes, channel, primary_data, data_size, &session_state);
        if (session_state & RMT_ENCODING_COMPLETE) {
            enc->state = 1; // move to reset code
        }
        if (session_state & RMT_ENCODING_MEM_FULL) {
            state = static_cast<rmt_encode_state_t>(state | RMT_ENCODING_MEM_FULL);
            goto out;
        }
        // fall through
    case 1: // transmit the reset/latch code
        encoded += copy->encode(copy, channel, &enc->reset_code,
                                sizeof(enc->reset_code), &session_state);
        if (session_state & RMT_ENCODING_COMPLETE) {
            enc->state = RMT_ENCODING_RESET;
            state = static_cast<rmt_encode_state_t>(state | RMT_ENCODING_COMPLETE);
        }
        if (session_state & RMT_ENCODING_MEM_FULL) {
            state = static_cast<rmt_encode_state_t>(state | RMT_ENCODING_MEM_FULL);
            goto out;
        }
    }
out:
    *ret_state = state;
    return encoded;
}

static IRAM_ATTR esp_err_t ws2812_encoder_reset(rmt_encoder_t* encoder) {
    ws2812_encoder_t* enc = __containerof(encoder, ws2812_encoder_t, base);
    rmt_encoder_reset(enc->bytes_encoder);
    rmt_encoder_reset(enc->copy_encoder);
    enc->state = RMT_ENCODING_RESET;
    return ESP_OK;
}

static esp_err_t ws2812_encoder_del(rmt_encoder_t* encoder) {
    ws2812_encoder_t* enc = __containerof(encoder, ws2812_encoder_t, base);
    rmt_del_encoder(enc->bytes_encoder);
    rmt_del_encoder(enc->copy_encoder);
    free(enc);
    return ESP_OK;
}

// ---- backend state ---------------------------------------------------------
static rmt_channel_handle_t sChannel = nullptr;
static rmt_encoder_handle_t sEncoder = nullptr;
static uint8_t sBrightness = DEFAULT_BRIGHTNESS; // applied per-component in setPixel
static uint8_t sPixels[LED_COUNT * 3] = {};      // GRB order, brightness pre-scaled

#if RINACHAN_LED_RMT_WITH_DMA
const char* backendName() { return "rmt-dma"; }
bool dmaEnabled() { return true; }
#else
const char* backendName() { return "rmt"; }
bool dmaEnabled() { return false; }
#endif

static esp_err_t createEncoder() {
    ws2812_encoder_t* enc =
        static_cast<ws2812_encoder_t*>(calloc(1, sizeof(ws2812_encoder_t)));
    if (!enc)
        return ESP_ERR_NO_MEM;
    enc->base.encode = ws2812_encode;
    enc->base.reset = ws2812_encoder_reset;
    enc->base.del = ws2812_encoder_del;
    enc->state = RMT_ENCODING_RESET;

    const uint32_t res = RINACHAN_LED_RMT_RESOLUTION_HZ;
    const float ticks_per_us = res / 1000000.0f;
    // WS2812 bit timing (ns): T0H=300 T0L=900 T1H=900 T1L=300.
    rmt_bytes_encoder_config_t bytes_cfg = {};
    bytes_cfg.bit0.level0 = 1;
    bytes_cfg.bit0.duration0 = static_cast<uint16_t>(0.3f * ticks_per_us); // 0.3us high
    bytes_cfg.bit0.level1 = 0;
    bytes_cfg.bit0.duration1 = static_cast<uint16_t>(0.9f * ticks_per_us); // 0.9us low
    bytes_cfg.bit1.level0 = 1;
    bytes_cfg.bit1.duration0 = static_cast<uint16_t>(0.9f * ticks_per_us); // 0.9us high
    bytes_cfg.bit1.level1 = 0;
    bytes_cfg.bit1.duration1 = static_cast<uint16_t>(0.3f * ticks_per_us); // 0.3us low
    bytes_cfg.flags.msb_first = 1;                                         // WS2812 is MSB-first
    esp_err_t err = rmt_new_bytes_encoder(&bytes_cfg, &enc->bytes_encoder);
    if (err != ESP_OK) {
        free(enc);
        return err;
    }

    rmt_copy_encoder_config_t copy_cfg = {};
    err = rmt_new_copy_encoder(&copy_cfg, &enc->copy_encoder);
    if (err != ESP_OK) {
        rmt_del_encoder(enc->bytes_encoder);
        free(enc);
        return err;
    }

    // Reset/latch >= 50us, split across the two halves of one symbol.
    const uint16_t reset_ticks =
        static_cast<uint16_t>(res / 1000000U * 50U / 2U); // 50us total
    enc->reset_code.level0 = 0;
    enc->reset_code.duration0 = reset_ticks;
    enc->reset_code.level1 = 0;
    enc->reset_code.duration1 = reset_ticks;

    sEncoder = &enc->base;
    return ESP_OK;
}

// 中文：一帧 WS2812 需要的 RMT symbol 数 = LED_COUNT*24 bit + 1 个复位 symbol。
// DMA 缓冲若 >= 这个值，整帧会被一次性编码进 DMA 缓冲，发送期间**零 refill ISR**，
// 于是 Wi-Fi 怎么抢中断都不影响这一帧的时序（等效 I2S 的免疫机制）。
static constexpr size_t kFrameSymbols = static_cast<size_t>(LED_COUNT) * 24U + 1U;

static size_t sActiveMemSymbols = 0; // 实际成功使用的 mem_block_symbols

// 中文：创建并使能一个指定缓冲大小的 RMT 通道，在调用者所在核运行。
// 注意：早期版本用 esp_ipc_call_blocking 把这段派发到 Core 1，结果撑爆了 IPC
// 任务那块极小的栈（默认~1KB）导致开机 panic（Stack canary, ipc1）。现在直接在
// 当前任务栈上创建。有了整帧 DMA 缓冲后发送期间几乎没有 refill 中断，ISR 落在
// 哪个核已不再关键（trans-done 中断被推迟只影响延迟，不污染 LED 时序）。
static esp_err_t rmtChannelCreate(size_t memSymbols) {
    rmt_tx_channel_config_t ch = {};
    ch.gpio_num = static_cast<gpio_num_t>(LED_PIN);
    ch.clk_src = RMT_CLK_SRC_DEFAULT;
    ch.resolution_hz = RINACHAN_LED_RMT_RESOLUTION_HZ;
    ch.mem_block_symbols = memSymbols;
    ch.trans_queue_depth = 4;
    // RMT ISR 优先级拉到驱动允许的最高(3)，减少被 Wi-Fi 中断抢占。
    // 驱动接口只接受 1..3；0 表示自动。>3 需绕过驱动写汇编 ISR，这里不做。
    ch.intr_priority = RINACHAN_LED_RMT_INTR_PRIORITY;
    ch.flags.with_dma = RINACHAN_LED_RMT_WITH_DMA ? 1 : 0;

    esp_err_t err = rmt_new_tx_channel(&ch, &sChannel);
    if (err == ESP_OK) {
        err = rmt_enable(sChannel);
        if (err != ESP_OK && sChannel) {
            rmt_del_channel(sChannel);
            sChannel = nullptr;
        }
    }
    return err;
}

bool begin() {
    // 候选缓冲大小，从大到小，逐级降级，保证一定能初始化成功不黑屏。
    // 注意：RMT DMA 上限 2047 且必须偶数，所以最大用 2046（不能用 2048/整帧）。
    size_t candidates[] = {
        RINACHAN_LED_RMT_MEM_BLOCK_SYMBOLS, // 用户/默认值（DMA 默认 2046）
        2046, 1024, 512, 256, 64};

    esp_err_t chErr = ESP_FAIL;
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        size_t mem = candidates[i];
        if (mem == 0)
            continue;
        if (RINACHAN_LED_RMT_WITH_DMA) {
            if (mem > 2046)
                mem = 2046; // DMA 硬上限 2047
            if (mem & 1U)
                mem -= 1U; // 必须偶数
        } else if (mem > 512) {
            continue; // 非 DMA 硬件块很小，跳过超大候选
        }

        const esp_err_t err = rmtChannelCreate(mem);
        if (err == ESP_OK) {
            chErr = ESP_OK;
            sActiveMemSymbols = mem;
            break;
        }
        RLOG_WARN("LEDDRV", "event=begin backend=%s try_mem_sym=%u failed code=0x%x",
                  backendName(), static_cast<unsigned>(mem), static_cast<unsigned>(err));
    }

    if (chErr != ESP_OK) {
        RLOG_ERROR("LEDDRV", "event=begin backend=%s err=tx_channel_all_failed", backendName());
        sReady = false;
        return false;
    }

    const esp_err_t encErr = createEncoder();
    if (encErr != ESP_OK) {
        RLOG_ERROR("LEDDRV", "event=begin backend=%s err=encoder code=0x%x",
                   backendName(), static_cast<unsigned>(encErr));
        rmt_disable(sChannel);
        rmt_del_channel(sChannel);
        sChannel = nullptr;
        sReady = false;
        return false;
    }

    memset(sPixels, 0, sizeof(sPixels));
    sReady = true;
    const bool wholeFrame = sActiveMemSymbols >= kFrameSymbols;
    RLOG_INFO("LEDDRV", "event=begin backend=%s dma=%d ready=1 isr_core=%d res_hz=%u mem_sym=%u frame_sym=%u whole_frame=%d prio=%d",
              backendName(), dmaEnabled() ? 1 : 0, static_cast<int>(xPortGetCoreID()),
              static_cast<unsigned>(RINACHAN_LED_RMT_RESOLUTION_HZ),
              static_cast<unsigned>(sActiveMemSymbols), static_cast<unsigned>(kFrameSymbols),
              wholeFrame ? 1 : 0, static_cast<int>(RINACHAN_LED_RMT_INTR_PRIORITY));
    return true;
}

// RMT backend applies brightness per-component in setPixel (no library helper).
void setBrightness(uint8_t brightness) { sBrightness = brightness; }

void setPixel(uint16_t physicalIndex, uint8_t r, uint8_t g, uint8_t b) {
    if (physicalIndex >= LED_COUNT)
        return;
    const uint16_t off = physicalIndex * 3U;
    // WS2812 wire order is GRB. Apply brightness here (Adafruit did it in show()).
    sPixels[off + 0] = scale8(g, sBrightness);
    sPixels[off + 1] = scale8(r, sBrightness);
    sPixels[off + 2] = scale8(b, sBrightness);
}

void clear() { memset(sPixels, 0, sizeof(sPixels)); }

bool refresh() {
    if (!sReady || !sChannel || !sEncoder) {
        ++sRefreshFail;
        return false;
    }
    rmt_transmit_config_t txc = {};
    txc.loop_count = 0;
    const uint32_t startUs = micros();
    esp_err_t err = rmt_transmit(sChannel, sEncoder, sPixels, sizeof(sPixels), &txc);
    if (err == ESP_OK) {
        // Block until the strip transaction has finished, preserving the
        // synchronous strip.show() semantics the render task relies on.
        err = rmt_tx_wait_all_done(sChannel, 100 /* ms */);
    }
    const bool ok = (err == ESP_OK);
    recordRefresh(startUs, ok);
    if (!ok) {
        RLOG_WARN("LEDDRV", "event=refresh_fail backend=%s code=0x%x",
                  backendName(), static_cast<unsigned>(err));
    }
    return ok;
}

} // namespace leddrv

#else
#error "Unknown RINACHAN_LED_BACKEND; expected RINACHAN_LED_BACKEND_ADAFRUIT or RINACHAN_LED_BACKEND_RMT"
#endif
