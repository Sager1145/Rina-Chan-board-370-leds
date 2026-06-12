#pragma once
#include <Arduino.h>


// 本文件处理 GPIO 按钮、组合键和按钮来源的语义动作；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明 GPIO 按钮、组合键或本地 overlay 反馈。
// 硬件按钮运行时记录（Hardware button runtime record） 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------
struct ButtonRuntime {
    const char* code;
    uint8_t     pin;
    bool        rawPressed     = false;
    bool        pressed        = false;
    bool        comboConsumed  = false;
    uint32_t    lastRawChangeMs = 0;
    uint32_t    pressedAtMs    = 0;
    uint32_t    lastRepeatMs   = 0;

    /**
 * 围绕 ButtonRuntime 处理本模块的核心流程，供 buttons 模块使用。
     * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
     * @param buttonCode 调用方传入或接收的参数，含义以函数签名为准。
     * @param gpioPin 调用方传入或接收的参数，含义以函数签名为准。
     * @return 返回操作结果、状态值、数据引用或空值。
     */
    ButtonRuntime(const char* buttonCode, uint8_t gpioPin)
        : code(buttonCode), pin(gpioPin) {}
};

// ---------------------------------------------------------------------------
// 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
// API 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------

/**
 * 初始化 initHardwareButtons 相关逻辑，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void initHardwareButtons();

/**
 * 轮询服务 serviceHardwareButtons 相关逻辑，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceHardwareButtons();

/**
 * 围绕 runButtonAction 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param button 调用方传入或接收的参数，含义以函数签名为准。
 * @param source 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool runButtonAction(const String& button, const String& source);
