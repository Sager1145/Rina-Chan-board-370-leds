#pragma once

#include <Arduino.h>


// 本文件封装 FreeRTOS mutex 和跨核心同步保护；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// FreeRTOS 同步辅助函数（FreeRTOS synchronization helpers） 相关代码，维护 封装 FreeRTOS mutex 和跨核心同步保护。
// ---------------------------------------------------------------------------
//
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
//
// 说明界面布局、组件状态或响应式规则。
// 说明文字滚动、帧缓存或播放状态处理。
//
// 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 说明 FreeRTOS 同步锁 中当前代码块的职责和维护约束。

enum class SyncDomain : uint8_t {
    Frame,
    Scroll,
    HardwareBus,
};

/**
 * 围绕 ScopedLock 处理本模块的核心流程，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param domain 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
class ScopedLock final {
public:
    explicit ScopedLock(SyncDomain domain);
    ~ScopedLock();

    ScopedLock(const ScopedLock&) = delete;
    ScopedLock& operator=(const ScopedLock&) = delete;

private:
    SyncDomain domain_;
    bool locked_ = false;
};

/**
 * 初始化、同步 initSyncPrimitives 相关逻辑，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool initSyncPrimitives();

/**
 * 围绕 lockFrame 处理本模块的核心流程，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void lockFrame();

/**
 * 围绕 unlockFrame 处理本模块的核心流程，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void unlockFrame();

/**
 * 围绕 lockScroll 处理本模块的核心流程，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void lockScroll();

/**
 * 围绕 unlockScroll 处理本模块的核心流程，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void unlockScroll();

/**
 * 围绕 lockHardwareBus 处理本模块的核心流程，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void lockHardwareBus();

/**
 * 围绕 unlockHardwareBus 处理本模块的核心流程，供 sync 模块使用。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void unlockHardwareBus();

/**
 * 说明 sync 模块中的这个声明或实现块。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param fn 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
template <typename Fn>
auto withFrameLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Frame);
    return fn();
}

/**
 * 说明 sync 模块中的这个声明或实现块。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param fn 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
template <typename Fn>
auto withScrollLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Scroll);
    return fn();
}

/**
 * 说明 sync 模块中的这个声明或实现块。
 * @brief 说明 FreeRTOS 同步锁 中当前函数或声明的用途。
 * @param fn 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
template <typename Fn>
auto withHardwareBusLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::HardwareBus);
    return fn();
}
