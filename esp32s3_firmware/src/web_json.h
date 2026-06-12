#pragma once
#include <Arduino.h>


// 本文件把运行时状态序列化成 Web API JSON 响应；注释保留必要 English identifier，便于和代码/API 对照。
/**
 * 查找 findJsonStringEnd 相关逻辑，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param quotePos 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
int findJsonStringEnd(const String& body, size_t quotePos);

/**
 * 围绕 extractJsonStringAt 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param quotePos 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @param endQuote 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote);

/**
 * 围绕 jsonBoolField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param defaultValue 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonBoolField(const String& body, const char* key, bool defaultValue);

/**
 * 围绕 jsonUintField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonUintField(const String& body, const char* key, uint32_t& value);

/**
 * 围绕 jsonFloatField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonFloatField(const String& body, const char* key, float& value);

/**
 * 围绕 jsonStringField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonStringField(const String& body, const char* key, String& value);
