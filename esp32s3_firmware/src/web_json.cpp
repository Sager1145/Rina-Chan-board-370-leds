#include "web_json.h"
#include <ctype.h>
#include <string.h>


// 本文件把运行时状态序列化成 Web API JSON 响应；注释保留必要 English identifier，便于和代码/API 对照。
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

static size_t skipJsonWhitespace(const String& body, size_t pos) {
    while (pos < body.length() &&
           isspace(static_cast<unsigned char>(body.charAt(pos)))) {
        ++pos;
    }
    return pos;
}

static bool rawJsonKeyEquals(const String& body, size_t start, size_t end, const char* key) {
    if (!key) return false;
    const size_t keyLen = strlen(key);
    if (end < start || end - start != keyLen) return false;
    for (size_t i = 0; i < keyLen; ++i) {
        if (body.charAt(start + i) != key[i]) return false;
    }
    return true;
}

static bool jsonStartsWithAt(const String& body, size_t pos, const char* token) {
    if (!token) return false;
    const size_t tokenLen = strlen(token);
    if (pos > body.length() || body.length() - pos < tokenLen) return false;
    for (size_t i = 0; i < tokenLen; ++i) {
        if (body.charAt(pos + i) != token[i]) return false;
    }
    return true;
}

static int jsonFieldValuePosition(const String& body, const char* key) {
    if (!key || key[0] == '\0') return -1;

    size_t pos = 0;
    while (pos < body.length()) {
        if (body.charAt(pos) != '"') {
            ++pos;
            continue;
        }

        const int endQuote = findJsonStringEnd(body, pos);
        if (endQuote < 0) return -1;

        const size_t afterKey = skipJsonWhitespace(body, static_cast<size_t>(endQuote) + 1U);
        if (afterKey < body.length() && body.charAt(afterKey) == ':' &&
            rawJsonKeyEquals(body, pos + 1U, static_cast<size_t>(endQuote), key)) {
            return static_cast<int>(skipJsonWhitespace(body, afterKey + 1U));
        }

        pos = static_cast<size_t>(endQuote) + 1U;
    }

    return -1;
}

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

bool jsonFieldValueOffset(const String& body, const char* key, size_t& offset) {
    const int position = jsonFieldValuePosition(body, key);
    if (position < 0) return false;
    offset = static_cast<size_t>(position);
    return true;
}

bool jsonHasField(const String& body, const char* key) {
    return jsonFieldValuePosition(body, key) >= 0;
}

bool jsonBoolField(const String& body, const char* key, bool defaultValue) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0) return defaultValue;
    if (jsonStartsWithAt(body, static_cast<size_t>(p), "true")) return true;
    if (jsonStartsWithAt(body, static_cast<size_t>(p), "false")) return false;
    return defaultValue;
}

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

bool jsonStringField(const String& body, const char* key, String& value) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0 || static_cast<size_t>(p) >= body.length() || body.charAt(p) != '"') return false;

    int endQuote = -1;
    return extractJsonStringAt(body, static_cast<size_t>(p), value, endQuote);
}
