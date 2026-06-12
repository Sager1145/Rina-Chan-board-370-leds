#pragma once
#include <Arduino.h>
#include "config.h"


// 本文件渲染按钮反馈、电量提示和网络信息 overlay；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// GPIO 按钮 LED 动画叠加层（GPIO button LED animation overlay） 相关代码，维护 渲染按钮反馈、电量提示和网络信息 overlay。
// ---------------------------------------------------------------------------
//
// 说明 按钮反馈、电量提示和网络信息 overlay 中当前代码块的职责和维护约束。
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 说明文字滚动、帧缓存或播放状态处理。

/**
 * 启动 startButtonAnimationForGpioAction 相关逻辑，供 button_animations 模块使用。
 * @brief 说明 按钮反馈、电量提示和网络信息 overlay 中当前函数或声明的用途。
 * @param buttonCode 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void startButtonAnimationForGpioAction(const String& buttonCode);

/**
 * 处理 handleButtonAnimationGpioPress 相关逻辑，供 button_animations 模块使用。
 * @brief 说明 按钮反馈、电量提示和网络信息 overlay 中当前函数或声明的用途。
 * @param buttonCode 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void handleButtonAnimationGpioPress(const char* buttonCode);

/**
 * 处理 handleButtonAnimationGpioRelease 相关逻辑，供 button_animations 模块使用。
 * @brief 说明 按钮反馈、电量提示和网络信息 overlay 中当前函数或声明的用途。
 * @param buttonCode 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void handleButtonAnimationGpioRelease(const char* buttonCode);

/**
 * 轮询服务 serviceButtonAnimationButtonInputs 相关逻辑，供 button_animations 模块使用。
 * @brief 说明 按钮反馈、电量提示和网络信息 overlay 中当前函数或声明的用途。
 * @param b6Pressed 调用方传入或接收的参数，含义以函数签名为准。
 * @param b2Pressed 调用方传入或接收的参数，含义以函数签名为准。
 * @param b3Pressed 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceButtonAnimationButtonInputs(bool b6Pressed, bool b2Pressed, bool b3Pressed);

/**
 * 轮询服务 serviceButtonAnimations 相关逻辑，供 button_animations 模块使用。
 * @brief 说明 按钮反馈、电量提示和网络信息 overlay 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceButtonAnimations();

/**
 * 复制 copyButtonAnimationOverlay 相关逻辑，供 button_animations 模块使用。
 * @brief 说明 按钮反馈、电量提示和网络信息 overlay 中当前函数或声明的用途。
 * @param rgbOut 调用方传入或接收的参数，含义以函数签名为准。
 * @param ledCount 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool copyButtonAnimationOverlay(uint8_t* rgbOut, uint16_t ledCount);

