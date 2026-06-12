#pragma once
#include <Arduino.h>


// 本文件提供小型字符串、数值和颜色辅助函数；注释保留必要 English identifier，便于和代码/API 对照。
int hexNibble(char c);

bool millisReached(uint32_t now, uint32_t dueMs);

bool millisElapsed(uint32_t now, uint32_t sinceMs, uint32_t intervalMs);

size_t jsonCapacityFor(size_t sourceBytes);

bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);

String formatColorHex(uint8_t r, uint8_t g, uint8_t b);
