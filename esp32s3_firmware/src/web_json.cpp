#include "web_json.h"
#include <ctype.h>


// 本文件把运行时状态序列化成 Web API JSON 响应；注释保留必要 English identifier，便于和代码/API 对照。
/**
 * 围绕 jsonFieldValuePosition 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static int jsonFieldValuePosition(const String& body, const char* key) {
    const String token = String("\"") + key + "\"";
    const int keyPos = body.indexOf(token);
    if (keyPos < 0) return -1;

    const int colon = body.indexOf(':', keyPos);
    if (colon < 0) return -1;

    int p = colon + 1;
    while (p >= 0 && static_cast<size_t>(p) < body.length() &&
           isspace(static_cast<unsigned char>(body.charAt(p)))) {
        ++p;
    }
    return p;
}

/**
 * 查找 findJsonStringEnd 相关逻辑，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param quotePos 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
int findJsonStringEnd(const String& body, size_t quotePos) {
    if (quotePos >= body.length() || body.charAt(quotePos) != '"') return -1;

    bool escaped = false;
    for (size_t i = quotePos + 1; i < body.length(); ++i) {
        const char c = body.charAt(i);
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') return static_cast<int>(i);
    }
    return -1;
}

/**
 * 围绕 extractJsonStringAt 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param quotePos 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @param endQuote 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote) {
    endQuote = findJsonStringEnd(body, quotePos);
    if (endQuote < 0) return false;

    const String raw = body.substring(quotePos + 1, endQuote);
    if (raw.indexOf('\\') < 0) {
        value = raw;
        return true;
    }

    value = "";
    value.reserve(raw.length());
    bool escaped = false;
    for (size_t i = 0; i < raw.length(); ++i) {
        const char c = raw.charAt(i);
        if (!escaped) {
            if (c == '\\') {
                escaped = true;
            } else {
                value += c;
            }
            continue;
        }

        // 处理 M370 帧、队列、校验或状态同步。
        // 说明字体、字形、Unicode 范围或 Web font 资源处理。
        // 说明 Web API JSON 字段解析 中当前代码块的职责和维护约束。
        switch (c) {
            case '"': value += '"'; break;
            case '\\': value += '\\'; break;
            case '/': value += '/'; break;
            case 'b': value += '\b'; break;
            case 'f': value += '\f'; break;
            case 'n': value += '\n'; break;
            case 'r': value += '\r'; break;
            case 't': value += '\t'; break;
            default:
                value += c;
                break;
        }
        escaped = false;
    }
    return !escaped;
}

/**
 * 围绕 jsonBoolField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param defaultValue 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonBoolField(const String& body, const char* key, bool defaultValue) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0) return defaultValue;
    if (body.substring(p, p + 4) == "true") return true;
    if (body.substring(p, p + 5) == "false") return false;
    return defaultValue;
}

/**
 * 围绕 jsonUintField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonUintField(const String& body, const char* key, uint32_t& value) {
    int p = jsonFieldValuePosition(body, key);
    if (p < 0) return false;

    uint32_t parsed = 0;
    bool foundDigit = false;
    while (static_cast<size_t>(p) < body.length() &&
           isdigit(static_cast<unsigned char>(body.charAt(p)))) {
        foundDigit = true;
        parsed = parsed * 10 + static_cast<uint32_t>(body.charAt(p++) - '0');
    }
    if (!foundDigit) return false;
    value = parsed;
    return true;
}

/**
 * 围绕 jsonFloatField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonFloatField(const String& body, const char* key, float& value) {
    int p = jsonFieldValuePosition(body, key);
    if (p < 0) return false;

    int q = p;
    while (static_cast<size_t>(q) < body.length()) {
        const char c = body.charAt(q);
        if (!(isdigit(static_cast<unsigned char>(c)) || c == '.' || c == '-' ||
              c == '+' || c == 'e' || c == 'E')) {
            break;
        }
        ++q;
    }
    if (q == p) return false;
    value = body.substring(p, q).toFloat();
    return true;
}

/**
 * 围绕 jsonStringField 处理本模块的核心流程，供 web_json 模块使用。
 * @brief 说明 Web API JSON 字段解析 中当前函数或声明的用途。
 * @param body 调用方传入或接收的参数，含义以函数签名为准。
 * @param key 调用方传入或接收的参数，含义以函数签名为准。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool jsonStringField(const String& body, const char* key, String& value) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0 || static_cast<size_t>(p) >= body.length() || body.charAt(p) != '"') return false;

    int endQuote = -1;
    return extractJsonStringAt(body, static_cast<size_t>(p), value, endQuote);
}
