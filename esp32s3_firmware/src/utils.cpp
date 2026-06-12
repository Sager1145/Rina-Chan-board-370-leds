#include "utils.h"


// 本文件提供小型字符串、数值和颜色辅助函数；注释保留必要 English identifier，便于和代码/API 对照。
/**
 * 围绕 hexNibble 处理本模块的核心流程，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param c 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/**
 * 围绕 jsonCapacityFor 处理本模块的核心流程，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param sourceBytes 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
size_t jsonCapacityFor(size_t sourceBytes) {
    const size_t estimated = sourceBytes * 2 + 4096;
    return estimated < 32768 ? 32768 : estimated;
}

/**
 * 解析 parseColorHex 相关逻辑，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param r 调用方传入或接收的参数，含义以函数签名为准。
 * @param g 调用方传入或接收的参数，含义以函数签名为准。
 * @param b 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b) {
    String value = input;
    value.trim();

    // 说明 通用辅助函数 中当前代码块的职责和维护约束。
    // 说明 通用辅助函数 中当前代码块的职责和维护约束。
    const size_t offset = (value.length() > 0 && value.charAt(0) == '#') ? 1 : 0;
    if (value.length() - offset != 6) return false;

    // 说明 通用辅助函数 中当前代码块的职责和维护约束。
    // 说明 通用辅助函数 中当前代码块的职责和维护约束。
    // 说明 通用辅助函数 中当前代码块的职责和维护约束。
    // 说明 通用辅助函数 中当前代码块的职责和维护约束。
    int nibbles[6];
    for (size_t i = 0; i < 6; ++i) {
        nibbles[i] = hexNibble(value.charAt(offset + i));
        if (nibbles[i] < 0) return false;
    }

    r = static_cast<uint8_t>((nibbles[0] << 4) | nibbles[1]);
    g = static_cast<uint8_t>((nibbles[2] << 4) | nibbles[3]);
    b = static_cast<uint8_t>((nibbles[4] << 4) | nibbles[5]);
    return true;
}

/**
 * 围绕 formatColorHex 处理本模块的核心流程，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param r 调用方传入或接收的参数，含义以函数签名为准。
 * @param g 调用方传入或接收的参数，含义以函数签名为准。
 * @param b 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
String formatColorHex(uint8_t r, uint8_t g, uint8_t b) {
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x", r, g, b);
    return String(buf);
}
