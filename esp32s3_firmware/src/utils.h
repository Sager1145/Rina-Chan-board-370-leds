#pragma once
#include <Arduino.h>


// 本文件提供小型字符串、数值和颜色辅助函数；注释保留必要 English identifier，便于和代码/API 对照。
int hexNibble(char c);

bool millisReached(uint32_t now, uint32_t dueMs);

bool millisElapsed(uint32_t now, uint32_t sinceMs, uint32_t intervalMs);

size_t jsonCapacityFor(size_t sourceBytes);

bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);

String formatColorHex(uint8_t r, uint8_t g, uint8_t b);

// 滚动源文本校验：拒绝非法 UTF-8、overlong 编码、surrogate、> U+10FFFF、
// U+0000，以及除 '\n' 外的 C0 控制字符。
bool validateScrollSourceText(const char* s, size_t len);

// timelineId / fontId / generatorVersion 校验：非空，仅允许安全 ASCII
// [A-Za-z0-9._:-]，长度不超过 maxLen。
bool validateMetaIdString(const char* s, size_t maxLen);
