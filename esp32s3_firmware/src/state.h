#pragma once
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "config.h"

// 本头文件定义固件共享运行时状态、保存表情缓存和 RuntimeStore
// 单例接口。跨模块读写这些字段时，调用方需要按 sync.h 的锁策略保护。

// ---------------------------------------------------------------------------
// 说明 共享运行时状态 中当前代码块的职责和维护约束。
// ---------------------------------------------------------------------------
// 中文块：RuntimeState 保存当前 WebUI/固件可见状态，包括颜色、亮度、播放模式、
// 统计计数、文字滚动状态和延迟恢复标记。
struct RuntimeState {
    // 中文块：当前显示配置和最近一次操作原因；WebUI status 与渲染器都会读取。
    String   colorHex            = DEFAULT_COLOR;
    uint8_t  colorR              = 0xf9;
    uint8_t  colorG              = 0x71;
    uint8_t  colorB              = 0xd4;
    uint8_t  brightness          = DEFAULT_BRIGHTNESS;
    String   mode                = DEFAULT_MODE;
    String   playback            = DEFAULT_PLAYBACK;
    String   lastM370;
    String   lastReason          = "boot";
    bool     paused              = false;

    // 中文块：运行统计计数，用来在调试页面观察帧、命令、文件写入和 UI 发布情况。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    uint32_t framesAccepted      = 0;
    uint32_t framesRejected      = 0;
    uint32_t framesQueued        = 0;
    uint32_t framesDequeued      = 0;
    uint32_t framesDropped       = 0;
    uint32_t commandsAccepted    = 0;
    uint32_t commandsRejected    = 0;
    uint32_t savedFacesWrites    = 0;
    uint32_t settingsWrites      = 0;
    uint32_t bootMs              = 0;
    uint32_t stateVersion        = 1;
    bool     slowUiDirty         = false;
    uint32_t lastSlowUiPublishMs = 0;

    // 中文块：自动轮播的间隔、上次切换时间和当前表情 index。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    uint32_t autoIntervalMs      = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs    = 0;
    uint16_t autoFaceIndex       = 0;

    // 中文块：固件端文字滚动播放状态；WebUI 上传帧后由这些字段控制播放/暂停。
    // 说明文字滚动、帧缓存或播放状态处理。
    bool     firmwareScrollActive  = false;
    bool     firmwareScrollPaused  = false;
    bool     firmwareScrollUserPaused = false;
    bool     firmwareScrollSystemPaused = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount      = 0;
    uint16_t scrollFrameIndex      = 0;
    uint16_t scrollIntervalMs      = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs     = 0;

    // 中文块：GPIO B1/B2/B3 中断文字滚动时给 WebUI 的轻量事件标记。
    // 前端在 6.4 页面轮询 sequence，不需要拉取完整帧数据。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明文字滚动、帧缓存或播放状态处理。
    uint32_t scrollStopEventSeq       = 0;
    uint32_t scrollStopEventMs        = 0;
    String   scrollStopEventButton;
    String   scrollStopEventSource;
    String   scrollStopEventReason;

    // 中文块：显式清屏后延迟恢复保存表情；这样 HTTP/button handler 不需要 delay()，
    // 但 LED render task 仍有时间物理锁存全黑帧。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    String   deferredFaceRestoreReason;
};

// ---------------------------------------------------------------------------
// 说明 JSON 字段、资源格式或序列化流程。
// ---------------------------------------------------------------------------
// 中文块：RuntimeFace 是 saved_faces.json 中单个表情的运行时副本，保留排序、
// 默认标记和启动默认标记，供自动轮播和 WebUI 列表共用。
struct RuntimeFace {
    String   id;
    String   name;
    String   m370;
    int32_t  order           = 0;
    uint16_t jsonIndex       = 0;
    bool     isDefault       = false;
    bool     isStartupDefault = false;
};

// ---------------------------------------------------------------------------
// 说明 共享运行时状态 中当前代码块的职责和维护约束。
// ---------------------------------------------------------------------------
// 中文块：RuntimeStore 集中持有所有可变运行时存储，避免各模块直接链接 extern
// 全局变量；具体加锁仍由调用方或 helper 按操作语义决定。
// 说明 共享运行时状态 中当前代码块的职责和维护约束。
// 说明 共享运行时状态 中当前代码块的职责和维护约束。
// 说明 共享运行时状态 中当前代码块的职责和维护约束。
class RuntimeStore final {
public:
    /**
     * 取得全局唯一 RuntimeStore，用于访问状态、表情和帧缓存。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    static RuntimeStore& instance();

    /**
     * 取得可写 RuntimeState，调用方负责必要的锁保护。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    RuntimeState& state() { return state_; }

    /**
     * 取得只读 RuntimeState，适合状态快照和只读检查。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    const RuntimeState& state() const { return state_; }

    /**
     * 取得保存表情数组的可写首地址。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    RuntimeFace* autoFaces() { return autoFaces_; }

    /**
     * 取得保存表情数组的只读首地址。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    const RuntimeFace* autoFaces() const { return autoFaces_; }

    /**
     * 取得保存表情数量的可写引用。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    uint16_t& autoFaceCount() { return autoFaceCount_; }

    /**
     * 取得保存表情数量的只读引用。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    const uint16_t& autoFaceCount() const { return autoFaceCount_; }

    /**
     * 取得当前活动帧的 packed bits 缓冲区。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    uint8_t* frameBits() { return frameBits_; }

    /**
     * 取得当前活动帧 packed bits 的只读缓冲区。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    const uint8_t* frameBits() const { return frameBits_; }

    /**
     * 初始化文字滚动帧缓存，优先使用 PSRAM，必要时回退到内部 SRAM。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    bool initScrollFrameBuffer();

    /**
     * 检查文字滚动帧缓存是否已经可用。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    bool scrollFrameBufferReady() const { return scrollFrameBits_ != nullptr; }

    /**
     * 检查文字滚动帧缓存是否由 PSRAM 支撑。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    bool scrollFrameBufferInPsram() const { return scrollFrameBitsInPsram_; }

    /**
     * 按 index 取得可写文字滚动帧。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param index 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    uint8_t* scrollFrameBits(uint16_t index);

    /**
     * 按 index 取得只读文字滚动帧。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param index 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    const uint8_t* scrollFrameBits(uint16_t index) const;

    /**
     * 取得 LittleFS 挂载状态的可写引用。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    bool& fsMounted() { return fsMounted_; }

    /**
     * 取得 LittleFS 挂载状态的只读引用。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    const bool& fsMounted() const { return fsMounted_; }

private:
    /**
     * 私有默认构造，保证 RuntimeStore 只能通过 instance() 访问。
     * @brief 说明 共享运行时状态 中当前函数或声明的用途。
     * @param None 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    RuntimeStore() = default;
    RuntimeStore(const RuntimeStore&) = delete;
    RuntimeStore& operator=(const RuntimeStore&) = delete;

    RuntimeState state_;
    RuntimeFace  autoFaces_[MAX_AUTO_FACES] = {};
    uint16_t     autoFaceCount_ = 0;
    uint8_t      frameBits_[FRAME_BYTES] = {};
    // 中文块：文字滚动缓存约 140 KB，按需分配；常见 PSRAM 路径不会永久占用
    // 内部 SRAM 的这块大内存。
    // 说明文字滚动、帧缓存或播放状态处理。
    // 说明文字滚动、帧缓存或播放状态处理。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    // 说明 共享运行时状态 中当前代码块的职责和维护约束。
    uint8_t*     scrollFrameBits_ = nullptr;
    bool         scrollFrameBitsInPsram_ = false;
    bool         fsMounted_ = false;
};

/**
 * 取得全局可写 RuntimeState。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
RuntimeState& runtimeState();

/**
 * 取得已加载的保存表情记录数组。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
RuntimeFace* runtimeAutoFaces();

/**
 * 取得保存表情数量的可写引用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint16_t& runtimeAutoFaceCount();

/**
 * 取得当前活动帧 packed bits 缓冲区。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint8_t* runtimeFrameBits();

/**
 * 初始化文字滚动帧存储。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool initRuntimeScrollFrameBuffer();

/**
 * 检查文字滚动帧存储是否就绪。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool runtimeScrollFrameBufferReady();

/**
 * 检查文字滚动帧存储是否位于 PSRAM。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool runtimeScrollFrameBufferInPsram();

/**
 * 返回配置的文字滚动缓存总字节数。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
size_t runtimeScrollFrameBufferBytes();

/**
 * 取得指定 index 的可写文字滚动帧。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint8_t* runtimeScrollFrameBits(uint16_t index);

/**
 * 取得 LittleFS 挂载标记的可写引用。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool& runtimeFsMounted();

/**
 * 读取 WebUI/运行时状态版本号。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint32_t runtimeStateVersion();

/**
 * 递增运行时状态版本，用于快速通知 WebUI 有新状态。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void touchRuntimeState();

/**
 * 标记慢变化 UI 字段需要发布，但暂不立刻增加版本。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void touchRuntimeStateSlow();

/**
 * 合并慢变化字段的 UI 更新，按节流策略发布版本变化。
 * @brief 说明 共享运行时状态 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceRuntimeSlowStatePublish();
