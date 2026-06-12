#pragma once
#include <Arduino.h>


// 本文件提供小型字符串、数值和颜色辅助函数；注释保留必要 English identifier，便于和代码/API 对照。
/**
 * 围绕 hexNibble 处理本模块的核心流程，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param c 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
int hexNibble(char c);

/**
 * 围绕 jsonCapacityFor 处理本模块的核心流程，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param sourceBytes 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
size_t jsonCapacityFor(size_t sourceBytes);

/**
 * 解析 parseColorHex 相关逻辑，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param r 调用方传入或接收的参数，含义以函数签名为准。
 * @param g 调用方传入或接收的参数，含义以函数签名为准。
 * @param b 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);

/**
 * 围绕 formatColorHex 处理本模块的核心流程，供 utils 模块使用。
 * @brief 说明 通用辅助函数 中当前函数或声明的用途。
 * @param r 调用方传入或接收的参数，含义以函数签名为准。
 * @param g 调用方传入或接收的参数，含义以函数签名为准。
 * @param b 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
String formatColorHex(uint8_t r, uint8_t g, uint8_t b);
