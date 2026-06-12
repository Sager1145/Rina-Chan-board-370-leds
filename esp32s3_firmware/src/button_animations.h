#pragma once
#include <Arduino.h>
#include "config.h"


// 本文件渲染按钮反馈、电量提示和网络信息 overlay；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// GPIO 按钮 LED 动画叠加层（GPIO button LED animation overlay） 相关代码，维护 渲染按钮反馈、电量提示和网络信息 overlay。
// ---------------------------------------------------------------------------
//

void startButtonAnimationForGpioAction(const String& buttonCode);

void handleButtonAnimationGpioPress(const char* buttonCode);

void handleButtonAnimationGpioRelease(const char* buttonCode);

void serviceButtonAnimationButtonInputs(bool b6Pressed, bool b2Pressed, bool b3Pressed);

void serviceButtonAnimations();

bool copyButtonAnimationOverlay(uint8_t* rgbOut, uint16_t ledCount);

