#include "state.h"
#include <esp_heap_caps.h>


// 本文件保存运行时状态、帧缓存和 WebUI 可见状态版本；注释保留必要 English identifier，便于和代码/API 对照。
static constexpr size_t SCROLL_FRAME_BUFFER_BYTES =
    static_cast<size_t>(MAX_SCROLL_FRAMES) * static_cast<size_t>(FRAME_BYTES);

/**
 * 围绕 instance 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}

/**
 * 初始化 initScrollFrameBuffer 相关逻辑，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool RuntimeStore::initScrollFrameBuffer() {
    if (scrollFrameBits_ != nullptr) return true;

    // 说明文字滚动、帧缓存或播放状态处理。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    if (ESP.getPsramSize() > 0) {
        scrollFrameBits_ = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        scrollFrameBitsInPsram_ = scrollFrameBits_ != nullptr;
    }

    // 说明文字滚动、帧缓存或播放状态处理。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明文字滚动、帧缓存或播放状态处理。
    if (scrollFrameBits_ == nullptr) {
        scrollFrameBits_ = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
        scrollFrameBitsInPsram_ = false;
        if (scrollFrameBits_ == nullptr) {
            Serial.printf("WARN: scroll buffer unavailable; need %u bytes of PSRAM or internal SRAM\n",
                          static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
            return false;  // 说明文字滚动、帧缓存或播放状态处理。
        }
        Serial.printf("WARN: PSRAM scroll buffer unavailable; using %u-byte internal SRAM heap fallback\n",
                      static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
    }

    memset(scrollFrameBits_, 0, SCROLL_FRAME_BUFFER_BYTES);
    Serial.printf("Scroll buffer ready: %u bytes in %s, psram total=%u free=%u\n",
                  static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES),
                  scrollFrameBitsInPsram_ ? "PSRAM" : "internal SRAM heap fallback",
                  static_cast<unsigned>(ESP.getPsramSize()),
                  static_cast<unsigned>(ESP.getFreePsram()));
    return true;
}

/**
 * 围绕 scrollFrameBits 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    if (index >= MAX_SCROLL_FRAMES || scrollFrameBits_ == nullptr) return nullptr;
    return scrollFrameBits_ + (static_cast<size_t>(index) * FRAME_BYTES);
}

/**
 * 围绕 scrollFrameBits 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
const uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) const {
    if (index >= MAX_SCROLL_FRAMES || scrollFrameBits_ == nullptr) return nullptr;
    return scrollFrameBits_ + (static_cast<size_t>(index) * FRAME_BYTES);
}

/**
 * 围绕 runtimeState 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
RuntimeState& runtimeState() {
    return RuntimeStore::instance().state();
}

/**
 * 围绕 runtimeAutoFaces 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
RuntimeFace* runtimeAutoFaces() {
    return RuntimeStore::instance().autoFaces();
}

/**
 * 统计 runtimeAutoFaceCount 相关逻辑，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint16_t& runtimeAutoFaceCount() {
    return RuntimeStore::instance().autoFaceCount();
}

/**
 * 围绕 runtimeFrameBits 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint8_t* runtimeFrameBits() {
    return RuntimeStore::instance().frameBits();
}

/**
 * 初始化 initRuntimeScrollFrameBuffer 相关逻辑，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool initRuntimeScrollFrameBuffer() {
    return RuntimeStore::instance().initScrollFrameBuffer();
}

/**
 * 读取 runtimeScrollFrameBufferReady 相关逻辑，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool runtimeScrollFrameBufferReady() {
    return RuntimeStore::instance().scrollFrameBufferReady();
}

/**
 * 围绕 runtimeScrollFrameBufferInPsram 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool runtimeScrollFrameBufferInPsram() {
    return RuntimeStore::instance().scrollFrameBufferInPsram();
}

/**
 * 围绕 runtimeScrollFrameBufferBytes 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
size_t runtimeScrollFrameBufferBytes() {
    return SCROLL_FRAME_BUFFER_BYTES;
}

/**
 * 围绕 runtimeScrollFrameBits 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint8_t* runtimeScrollFrameBits(uint16_t index) {
    return RuntimeStore::instance().scrollFrameBits(index);
}

/**
 * 挂载 runtimeFsMounted 相关逻辑，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool& runtimeFsMounted() {
    return RuntimeStore::instance().fsMounted();
}

/**
 * 围绕 runtimeStateVersion 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint32_t runtimeStateVersion() {
    return runtimeState().stateVersion;
}

/**
 * 围绕 touchRuntimeState 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void touchRuntimeState() {
    ++runtimeState().stateVersion;
    if (runtimeState().stateVersion == 0) runtimeState().stateVersion = 1;
}

/**
 * 围绕 touchRuntimeStateSlow 处理本模块的核心流程，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void touchRuntimeStateSlow() {
    runtimeState().slowUiDirty = true;
}

/**
 * 轮询服务、发布 serviceRuntimeSlowStatePublish 相关逻辑，供 state 模块使用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceRuntimeSlowStatePublish() {
    RuntimeState& state = runtimeState();
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    if (!state.slowUiDirty) return;
    const uint32_t now = millis();
    if (now - state.lastSlowUiPublishMs < POWER_WEB_SLOW_PUBLISH_MS) return;
    state.slowUiDirty = false;
    state.lastSlowUiPublishMs = now;
    touchRuntimeState();
}
