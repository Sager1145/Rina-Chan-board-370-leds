#include "led_renderer.h"
#include "state.h"
#include "sync.h"
#include "scroll.h"
#include "utils.h"
#include "button_animations.h"
#include <Adafruit_NeoPixel.h>


// 本文件解析 M370 帧并把逻辑 LED 状态渲染到物理灯带；注释保留必要 English identifier，便于和代码/API 对照。
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
static Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);

static uint16_t logicalToPhysicalMap[LED_COUNT] = {};
static portMUX_TYPE ledRenderRequestMux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool ledRenderRequested = false;
static uint32_t lastLedShowUs = 0;

struct QueuedM370Frame {
    uint8_t bits[FRAME_BYTES] = {};
    char    m370[5 + M370_HEX_CHARS + 1] = "";
    char    reason[M370_FRAME_REASON_CHARS] = "";
    bool    hasM370 = false;
};

static QueuedM370Frame m370FrameQueue[M370_FRAME_QUEUE_DEPTH];
static uint8_t m370FrameQueueHead = 0;
static uint8_t m370FrameQueueCount = 0;
static uint32_t lastM370FrameApplyMs = 0;

// ---------------------------------------------------------------------------
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
// 内部辅助函数（Internal helpers） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 围绕 logicalToPhysicalLedIndex 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param logicalIndex 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static uint16_t logicalToPhysicalLedIndex(uint16_t logicalIndex) {
    if (logicalIndex >= LED_COUNT) return logicalIndex;
    if (!SERPENTINE_WIRING) return logicalIndex;

    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 M370 帧、队列、校验或状态同步。
    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        const uint16_t rowStart  = ROW_OFFSETS[row];
        const uint8_t  rowLength = ROW_LENGTHS[row];
        if (logicalIndex < rowStart || logicalIndex >= rowStart + rowLength) continue;
        const uint16_t localX    = logicalIndex - rowStart;
        const bool     reverseRow = SERPENTINE_ODD_ROWS_REVERSED && ((row & 1U) != 0);
        return reverseRow ? rowStart + (rowLength - 1U - localX) : logicalIndex;
    }
    return logicalIndex;
}

static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits);

/**
 * 排队 m370FrameQueueTail 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static uint8_t m370FrameQueueTail() {
    return static_cast<uint8_t>((m370FrameQueueHead + m370FrameQueueCount) % M370_FRAME_QUEUE_DEPTH);
}

/**
 * 读取 m370FrameRateReady 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool m370FrameRateReady(uint32_t now) {
    return lastM370FrameApplyMs == 0 || now - lastM370FrameApplyMs >= M370_FRAME_MIN_INTERVAL_MS;
}

/**
 * 复制 copyText 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param out 调用方传入或接收的参数，含义以函数签名为准。
 * @param outSize 调用方传入或接收的参数，含义以函数签名为准。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void copyText(char* out, size_t outSize, const char* input) {
    if (outSize == 0) return;
    if (!input) input = "";
    size_t i = 0;
    for (; i + 1 < outSize && input[i] != '\0'; ++i) out[i] = input[i];
    out[i] = '\0';
}

/**
 * 发布 publishPackedFrameNow 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param packedBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param normalizedM370 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void publishPackedFrameNow(const uint8_t* packedBits, const char* normalizedM370, const char* reason) {
    withFrameLock([&]() {
        memcpy(runtimeFrameBits(), packedBits, FRAME_BYTES);
        if (normalizedM370 && normalizedM370[0] != '\0') {
            runtimeState().lastM370 = normalizedM370;
        }
        runtimeState().lastReason = reason ? reason : "";
        ++runtimeState().framesAccepted;
        touchRuntimeState();
        showCurrentFrameNoLock();
    });
    lastM370FrameApplyMs = millis();
}

/**
 * 围绕 enqueuePackedM370Frame 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param packedBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param normalizedM370 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void enqueuePackedM370Frame(const uint8_t* packedBits, const char* normalizedM370, const String& reason) {
    if (!packedBits) return;

    const uint32_t now = millis();
    if (m370FrameQueueCount == 0 && m370FrameRateReady(now)) {
        publishPackedFrameNow(packedBits, normalizedM370, reason.c_str());
        return;
    }

    uint8_t target = m370FrameQueueTail();
    if (m370FrameQueueCount >= M370_FRAME_QUEUE_DEPTH) {
        // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
        // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
        target = m370FrameQueueHead;
        m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
        ++runtimeState().framesDropped;
    } else {
        ++m370FrameQueueCount;
    }

    memcpy(m370FrameQueue[target].bits, packedBits, FRAME_BYTES);
    if (normalizedM370 && normalizedM370[0] != '\0') {
        copyText(m370FrameQueue[target].m370, sizeof(m370FrameQueue[target].m370), normalizedM370);
        m370FrameQueue[target].hasM370 = true;
    } else {
        m370FrameQueue[target].m370[0] = '\0';
        m370FrameQueue[target].hasM370 = false;
    }
    copyText(m370FrameQueue[target].reason, sizeof(m370FrameQueue[target].reason), reason.c_str());
    ++runtimeState().framesQueued;
}

// ---------------------------------------------------------------------------
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// LED 索引映射（LED index map） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 初始化 initLedIndexMap 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void initLedIndexMap() {
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        logicalToPhysicalMap[logical] = logicalToPhysicalLedIndex(logical);
    }
}

// ---------------------------------------------------------------------------
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
// 渲染请求（Render request，ISR 安全） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 请求、渲染 requestLedRender 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void requestLedRender() {
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    if (xPortInIsrContext()) {
        portENTER_CRITICAL_ISR(&ledRenderRequestMux);
        ledRenderRequested = true;
        portEXIT_CRITICAL_ISR(&ledRenderRequestMux);
    } else {
        portENTER_CRITICAL(&ledRenderRequestMux);
        ledRenderRequested = true;
        portEXIT_CRITICAL(&ledRenderRequestMux);
    }
    notifyScrollRenderTask();
}

/**
 * 消费、渲染、请求 consumeLedRenderRequest 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool consumeLedRenderRequest() {
    bool requested = false;
    portENTER_CRITICAL(&ledRenderRequestMux);
    requested = ledRenderRequested;
    ledRenderRequested = false;
    portEXIT_CRITICAL(&ledRenderRequestMux);
    return requested;
}

/**
 * 围绕 showCurrentFrameNoLock 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void showCurrentFrameNoLock() { requestLedRender(); }

// ---------------------------------------------------------------------------
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
// 帧位辅助函数（Frame bit helpers） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 设置 setFrameBit 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @param on 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setFrameBit(uint16_t index, bool on) {
    const uint16_t byteIndex = index >> 3;
    const uint8_t  bitMask   = 1U << (index & 7U);
    if (on) runtimeFrameBits()[byteIndex] |=  bitMask;
    else    runtimeFrameBits()[byteIndex] &= ~bitMask;
}

/**
 * 围绕 frameBit 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool frameBit(uint16_t index) {
    return (runtimeFrameBits()[index >> 3] & (1U << (index & 7U))) != 0;
}

/**
 * 围绕 packedFrameBit 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param bits 调用方传入或接收的参数，含义以函数签名为准。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool packedFrameBit(const uint8_t* bits, uint16_t index) {
    return (bits[index >> 3] & (1U << (index & 7U))) != 0;
}

/**
 * 统计 countLitLeds 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint16_t countLitLeds() {
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    const uint8_t* bits = runtimeFrameBits();
    uint16_t lit = 0;
    for (uint16_t byteIndex = 0; byteIndex < FRAME_BYTES; ++byteIndex) {
        uint8_t value = bits[byteIndex];
        const uint16_t firstBit = static_cast<uint16_t>(byteIndex) << 3;
        if (firstBit + 8U > LED_COUNT) {
            const uint8_t validBits = static_cast<uint8_t>(LED_COUNT - firstBit);
            value &= static_cast<uint8_t>((1U << validBits) - 1U);
        }
        lit += static_cast<uint16_t>(__builtin_popcount(value));
    }
    return lit;
}

// ---------------------------------------------------------------------------
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 物理渲染（Physical render，仅限 Core 1 渲染任务） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 渲染 renderCurrentFrameToLedStrip 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void renderCurrentFrameToLedStrip() {
    uint8_t localFrame[FRAME_BYTES];
    static uint8_t overlayRgb[LED_COUNT * 3];
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    uint8_t colorR = 0, colorG = 0, colorB = 0;

    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    withFrameLock([&]() {
        memcpy(localFrame, runtimeFrameBits(), FRAME_BYTES);
        brightness = runtimeState().brightness;
        colorR     = runtimeState().colorR;
        colorG     = runtimeState().colorG;
        colorB     = runtimeState().colorB;
    });

    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 在操作像素缓冲区之前等待，以确保 WS2812 总线已空闲（Wait before touching the pixel buffer so the WS2812 bus has been idle） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    const uint32_t nowUs = micros();
    if (lastLedShowUs != 0) {
        const uint32_t elapsedUs = nowUs - lastLedShowUs;
        if (elapsedUs < LED_RENDER_MIN_GAP_US) {
            delayMicroseconds(LED_RENDER_MIN_GAP_US - elapsedUs);
        }
    }

    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明颜色、亮度或显示参数处理。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    static uint8_t lastAppliedBrightness = DEFAULT_BRIGHTNESS;
    if (brightness != lastAppliedBrightness) {
        strip.setBrightness(brightness);
        lastAppliedBrightness = brightness;
    }
    const bool overlayActive = copyButtonAnimationOverlay(overlayRgb, LED_COUNT);
    if (overlayActive) {
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            const uint16_t offset = logical * 3U;
            strip.setPixelColor(
                logicalToPhysicalMap[logical],
                strip.Color(overlayRgb[offset], overlayRgb[offset + 1], overlayRgb[offset + 2])
            );
        }
    } else {
        const uint32_t rgb = strip.Color(colorR, colorG, colorB);
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            strip.setPixelColor(
                logicalToPhysicalMap[logical],
                packedFrameBit(localFrame, logical) ? rgb : 0
            );
        }
    }

    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() {
        strip.show();
    });
    lastLedShowUs = micros();
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 说明文字滚动、帧缓存或播放状态处理。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

// ---------------------------------------------------------------------------
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 灯带启动辅助函数（Strip boot helpers，仅从 setup() 调用） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 围绕 ledStripBegin 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void ledStripBegin() {
    strip.begin();
    strip.setBrightness(DEFAULT_BRIGHTNESS);
    strip.clear();
    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() {
        strip.show();
    });
    lastLedShowUs = micros();
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

// ---------------------------------------------------------------------------
// 处理 M370 帧、队列、校验或状态同步。
// M370 编解码器（M370 codec） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 规范化 normalizeM370 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param normalized 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool normalizeM370(const String& input, String& normalized, String& error) {
    String compact;
    compact.reserve(M370_HEX_CHARS);

    String payload = input;
    payload.trim();
    if (payload.length() >= 5 && payload.substring(0, 5).equalsIgnoreCase("M370:")) {
        payload = payload.substring(5);
    }

    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 处理 M370 帧、队列、校验或状态同步。
    for (size_t i = 0; i < payload.length(); ++i) {
        const char c = payload.charAt(i);
        if (c == ' ' || c == '\r' || c == '\n' || c == '\t') continue;
        if (hexNibble(c) < 0) {
            error = "M370 contains a non-hex character";
            return false;
        }
        compact += c;
    }

    if (compact.length() != M370_HEX_CHARS) {
        error = "M370 must be 93 hex chars, optionally prefixed with M370:";
        return false;
    }

    compact.toUpperCase();
    normalized = "M370:" + compact;
    return true;
}

/**
 * 围绕 m370ToPackedBits 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param outBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) return false;

    decodeNormalizedM370ToPackedBits(normalized, outBits);
    return true;
}

/**
 * 解码、规范化 decodeNormalizedM370ToPackedBits 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param normalized 调用方传入或接收的参数，含义以函数签名为准。
 * @param outBits 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits) {
    memset(outBits, 0, FRAME_BYTES);

    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
    // 处理 M370 帧、队列、校验或状态同步。
    const char* hex = normalized.c_str() + 5;
    for (uint16_t nib = 0; nib < M370_HEX_CHARS; ++nib) {
        const int value = hexNibble(hex[nib]);
        if (value <= 0) continue;  // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
        const uint16_t baseBit = static_cast<uint16_t>(nib) * 4U;
        for (uint8_t k = 0; k < 4U; ++k) {
            if ((value & (1 << (3 - k))) == 0) continue;
            const uint16_t bit = baseBit + k;
            if (bit < M370_BITS) outBits[bit >> 3] |= 1U << (bit & 7U);
        }
    }
}

/**
 * 围绕 blankM370 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
String blankM370() {
    String out = "M370:";
    out.reserve(5 + M370_HEX_CHARS);
    for (uint16_t i = 0; i < M370_HEX_CHARS; ++i) out += '0';
    return out;
}

// ---------------------------------------------------------------------------
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
// 帧应用辅助函数（Frame apply helpers） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 应用 applyM370 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool applyM370(const String& input, const String& reason, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) {
        ++runtimeState().framesRejected;
        return false;
    }

    // 处理 M370 帧、队列、校验或状态同步。
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    uint8_t packed[FRAME_BYTES];
    decodeNormalizedM370ToPackedBits(normalized, packed);

    enqueuePackedM370Frame(packed, normalized.c_str(), reason);
    return true;
}

/**
 * 应用 applyPackedFrame 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param packedBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void applyPackedFrame(const uint8_t* packedBits, const String& reason) {
    enqueuePackedM370Frame(packedBits, nullptr, reason);
}

/**
 * 应用 applyPackedFrameImmediate 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param packedBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason) {
    if (!packedBits) return;
    publishPackedFrameNow(packedBits, nullptr, reason.c_str());
}

/**
 * 应用 applyBlankFrame 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void applyBlankFrame(const String& reason) {
    uint8_t blank[FRAME_BYTES] = {};
    char blankM370Text[5 + M370_HEX_CHARS + 1];
    memcpy(blankM370Text, "M370:", 5);
    memset(blankM370Text + 5, '0', M370_HEX_CHARS);
    blankM370Text[5 + M370_HEX_CHARS] = '\0';
    enqueuePackedM370Frame(blank, blankM370Text, reason);
}

/**
 * 轮询服务、排队 serviceM370FrameQueue 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceM370FrameQueue() {
    if (m370FrameQueueCount == 0) return;
    const uint32_t now = millis();
    if (!m370FrameRateReady(now)) return;

    QueuedM370Frame item;
    memcpy(&item, &m370FrameQueue[m370FrameQueueHead], sizeof(item));
    m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
    --m370FrameQueueCount;
    ++runtimeState().framesDequeued;

    publishPackedFrameNow(item.bits, item.hasM370 ? item.m370 : nullptr, item.reason);
}

/**
 * 清除、排队 clearQueuedM370Frames 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void clearQueuedM370Frames() {
    if (m370FrameQueueCount == 0) return;
    runtimeState().framesDropped += m370FrameQueueCount;
    m370FrameQueueHead = 0;
    m370FrameQueueCount = 0;
}

/**
 * 排队、统计 queuedM370FrameCount 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint8_t queuedM370FrameCount() {
    return m370FrameQueueCount;
}

// ---------------------------------------------------------------------------
// 说明颜色、亮度或显示参数处理。
// 颜色 / 亮度（Color / brightness） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 设置、渲染 setColorStateNoRender 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setColorStateNoRender(const String& input) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) return;
    runtimeState().colorHex = formatColorHex(r, g, b);
    runtimeState().colorR   = r;
    runtimeState().colorG   = g;
    runtimeState().colorB   = b;
}

/**
 * 设置 setColor 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setColor(const String& input, String& error) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) {
        error = "color must be #RRGGBB or RRGGBB (hex)";
        return false;
    }
    withFrameLock([&]() {
        runtimeState().colorHex = formatColorHex(r, g, b);
        runtimeState().colorR   = r;
        runtimeState().colorG   = g;
        runtimeState().colorB   = b;
        touchRuntimeStateSlow();
        showCurrentFrameNoLock();
    });
    return true;
}

/**
 * 设置 setBrightness 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param raw 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setBrightness(int raw) {
    raw = constrain(raw, MIN_BRIGHTNESS, MAX_BRIGHTNESS);
    withFrameLock([&]() {
        runtimeState().brightness = static_cast<uint8_t>(raw);
        touchRuntimeStateSlow();
        showCurrentFrameNoLock();
    });
}
