#include "web_json.h"
#include "utils.h"
#include <ctype.h>
#include <string.h>

int findJsonStringEnd(const String& body, size_t quotePos) {
    if (quotePos >= body.length() || body.charAt(quotePos) != '"')
        return -1;

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
        if (c == '"')
            return static_cast<int>(i);
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
    if (!key)
        return false;
    const size_t keyLen = strlen(key);
    if (end < start || end - start != keyLen)
        return false;
    for (size_t i = 0; i < keyLen; ++i) {
        if (body.charAt(start + i) != key[i])
            return false;
    }
    return true;
}

static bool jsonStartsWithAt(const String& body, size_t pos, const char* token) {
    if (!token)
        return false;
    const size_t tokenLen = strlen(token);
    if (pos > body.length() || body.length() - pos < tokenLen)
        return false;
    for (size_t i = 0; i < tokenLen; ++i) {
        if (body.charAt(pos + i) != token[i])
            return false;
    }
    return true;
}

static bool isJsonValueTerminator(char c) {
    return c == ',' || c == '}' || c == ']' || isspace(static_cast<unsigned char>(c));
}

static bool skipJsonValue(const String& body, size_t pos, size_t& end, uint8_t depth);

static int jsonFieldValuePosition(const String& body, const char* key) {
    if (!key || key[0] == '\0')
        return -1;

    size_t pos = skipJsonWhitespace(body, 0);
    if (pos >= body.length() || body.charAt(pos) != '{')
        return -1;
    ++pos;

    while (true) {
        pos = skipJsonWhitespace(body, pos);
        if (pos >= body.length())
            return -1;
        if (body.charAt(pos) == '}')
            return -1;
        if (body.charAt(pos) != '"')
            return -1;
        const int endQuote = findJsonStringEnd(body, pos);
        if (endQuote < 0)
            return -1;

        const size_t afterKey = skipJsonWhitespace(body, static_cast<size_t>(endQuote) + 1U);
        if (afterKey < body.length() && body.charAt(afterKey) == ':' &&
            rawJsonKeyEquals(body, pos + 1U, static_cast<size_t>(endQuote), key)) {
            return static_cast<int>(skipJsonWhitespace(body, afterKey + 1U));
        }

        if (afterKey >= body.length() || body.charAt(afterKey) != ':')
            return -1;
        size_t valueEnd = 0;
        if (!skipJsonValue(body, skipJsonWhitespace(body, afterKey + 1U), valueEnd, 0))
            return -1;
        pos = skipJsonWhitespace(body, valueEnd);
        if (pos < body.length() && body.charAt(pos) == ',') {
            ++pos;
            continue;
        }
        if (pos < body.length() && body.charAt(pos) == '}')
            return -1;
        return -1;
    }
}

// 把 Unicode code point 以 UTF-8 形式追加到输出字符串。
static void appendUtf8CodePoint(String& out, uint32_t cp) {
    if (cp < 0x80) {
        out += static_cast<char>(cp);
    } else if (cp < 0x800) {
        out += static_cast<char>(0xC0 | (cp >> 6));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += static_cast<char>(0xE0 | (cp >> 12));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (cp >> 18));
        out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
}

// 解析 raw 中 pos 开始的 4 个十六进制字符；非法十六进制返回 false。
static bool parse4HexDigits(const String& raw, size_t pos, uint32_t& value) {
    if (pos + 4 > raw.length())
        return false;
    value = 0;
    for (size_t k = 0; k < 4; ++k) {
        const int nib = hexNibble(raw.charAt(pos + k));
        if (nib < 0)
            return false;
        value = (value << 4) | static_cast<uint32_t>(nib);
    }
    return true;
}

bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote) {
    endQuote = findJsonStringEnd(body, quotePos);
    if (endQuote < 0)
        return false;

    const String raw = body.substring(quotePos + 1, endQuote);
    if (raw.indexOf('\\') < 0) {
        for (size_t i = 0; i < raw.length(); ++i) {
            if (static_cast<unsigned char>(raw.charAt(i)) < 0x20)
                return false;
        }
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
            } else if (static_cast<unsigned char>(c) < 0x20) {
                return false;
            } else {
                value += c;
            }
            continue;
        }

        switch (c) {
        case '"':
            value += '"';
            break;
        case '\\':
            value += '\\';
            break;
        case '/':
            value += '/';
            break;
        case 'b':
            value += '\b';
            break;
        case 'f':
            value += '\f';
            break;
        case 'n':
            value += '\n';
            break;
        case 'r':
            value += '\r';
            break;
        case 't':
            value += '\t';
            break;
        case 'u': {
            // \uXXXX 解码：surrogate pair 合并，孤立 surrogate 用 U+FFFD，
            // 非法十六进制返回 false（调用方回 400）。
            uint32_t cp = 0;
            if (!parse4HexDigits(raw, i + 1, cp))
                return false;
            size_t extraConsumed = 4;
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                uint32_t low = 0;
                if (i + 6 < raw.length() && raw.charAt(i + 5) == '\\' &&
                    raw.charAt(i + 6) == 'u' && parse4HexDigits(raw, i + 7, low) &&
                    low >= 0xDC00 && low <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    extraConsumed = 10;
                } else {
                    cp = 0xFFFD; // 孤立 high surrogate
                }
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                cp = 0xFFFD; // 孤立 low surrogate
            }
            appendUtf8CodePoint(value, cp);
            i += extraConsumed;
            break;
        }
        default:
            return false;
        }
        escaped = false;
    }
    return !escaped;
}

static bool skipJsonNumber(const String& body, size_t pos, size_t& end) {
    const size_t n = body.length();
    if (pos >= n)
        return false;
    if (body.charAt(pos) == '-')
        ++pos;
    if (pos >= n)
        return false;

    if (body.charAt(pos) == '0') {
        ++pos;
    } else if (isdigit(static_cast<unsigned char>(body.charAt(pos)))) {
        while (pos < n && isdigit(static_cast<unsigned char>(body.charAt(pos))))
            ++pos;
    } else {
        return false;
    }

    if (pos < n && body.charAt(pos) == '.') {
        ++pos;
        if (pos >= n || !isdigit(static_cast<unsigned char>(body.charAt(pos))))
            return false;
        while (pos < n && isdigit(static_cast<unsigned char>(body.charAt(pos))))
            ++pos;
    }

    if (pos < n && (body.charAt(pos) == 'e' || body.charAt(pos) == 'E')) {
        ++pos;
        if (pos < n && (body.charAt(pos) == '+' || body.charAt(pos) == '-'))
            ++pos;
        if (pos >= n || !isdigit(static_cast<unsigned char>(body.charAt(pos))))
            return false;
        while (pos < n && isdigit(static_cast<unsigned char>(body.charAt(pos))))
            ++pos;
    }

    if (pos < n && !isJsonValueTerminator(body.charAt(pos)))
        return false;
    end = pos;
    return true;
}

static constexpr uint8_t JSON_MAX_DEPTH = 32U;

static bool skipJsonObject(const String& body, size_t pos, size_t& end, uint8_t depth) {
    if (pos >= body.length() || body.charAt(pos) != '{')
        return false;
    if (depth >= JSON_MAX_DEPTH)
        return false;
    ++pos;
    pos = skipJsonWhitespace(body, pos);
    if (pos < body.length() && body.charAt(pos) == '}') {
        end = pos + 1U;
        return true;
    }

    while (true) {
        pos = skipJsonWhitespace(body, pos);
        if (pos >= body.length() || body.charAt(pos) != '"')
            return false;
        const int keyEnd = findJsonStringEnd(body, pos);
        if (keyEnd < 0)
            return false;
        pos = skipJsonWhitespace(body, static_cast<size_t>(keyEnd) + 1U);
        if (pos >= body.length() || body.charAt(pos) != ':')
            return false;
        size_t valueEnd = 0;
        if (!skipJsonValue(body, skipJsonWhitespace(body, pos + 1U), valueEnd,
                           static_cast<uint8_t>(depth + 1U)))
            return false;
        pos = skipJsonWhitespace(body, valueEnd);
        if (pos >= body.length())
            return false;
        const char c = body.charAt(pos);
        if (c == ',') {
            ++pos;
            continue;
        }
        if (c == '}') {
            end = pos + 1U;
            return true;
        }
        return false;
    }
}

static bool skipJsonArray(const String& body, size_t pos, size_t& end, uint8_t depth) {
    if (pos >= body.length() || body.charAt(pos) != '[')
        return false;
    if (depth >= JSON_MAX_DEPTH)
        return false;
    ++pos;
    pos = skipJsonWhitespace(body, pos);
    if (pos < body.length() && body.charAt(pos) == ']') {
        end = pos + 1U;
        return true;
    }

    while (true) {
        size_t valueEnd = 0;
        if (!skipJsonValue(body, skipJsonWhitespace(body, pos), valueEnd,
                           static_cast<uint8_t>(depth + 1U)))
            return false;
        pos = skipJsonWhitespace(body, valueEnd);
        if (pos >= body.length())
            return false;
        const char c = body.charAt(pos);
        if (c == ',') {
            ++pos;
            continue;
        }
        if (c == ']') {
            end = pos + 1U;
            return true;
        }
        return false;
    }
}

static bool skipJsonLiteral(const String& body, size_t pos, size_t& end, const char* literal) {
    if (!jsonStartsWithAt(body, pos, literal))
        return false;
    end = pos + strlen(literal);
    return true;
}

static bool skipJsonValue(const String& body, size_t pos, size_t& end, uint8_t depth) {
    if (depth >= JSON_MAX_DEPTH)
        return false;
    pos = skipJsonWhitespace(body, pos);
    if (pos >= body.length())
        return false;
    const char c = body.charAt(pos);
    switch (c) {
    case '{':
        return skipJsonObject(body, pos, end, depth);
    case '[':
        return skipJsonArray(body, pos, end, depth);
    case '"': {
        // Validate string escapes here so malformed escapes are rejected during
        // whole-object validation, before any state mutation (Addendum A5/A11).
        String scratch;
        int endQuote = 0;
        if (!extractJsonStringAt(body, pos, scratch, endQuote))
            return false;
        end = static_cast<size_t>(endQuote) + 1U;
        return true;
    }
    case 't':
        return skipJsonLiteral(body, pos, end, "true");
    case 'f':
        return skipJsonLiteral(body, pos, end, "false");
    case 'n':
        return skipJsonLiteral(body, pos, end, "null");
    default:
        return skipJsonNumber(body, pos, end);
    }
}

bool jsonValidateCompleteObject(const String& body, String& error) {
    size_t pos = skipJsonWhitespace(body, 0);
    if (pos >= body.length() || body.charAt(pos) != '{') {
        error = "body is not a JSON object";
        return false;
    }
    size_t end = 0;
    if (!skipJsonObject(body, pos, end, 0)) {
        error = "malformed JSON object";
        return false;
    }
    pos = skipJsonWhitespace(body, end);
    if (pos != body.length()) {
        error = "trailing characters after JSON object";
        return false;
    }
    return true;
}

bool jsonFieldValueOffset(const String& body, const char* key, size_t& offset) {
    const int pos = jsonFieldValuePosition(body, key);
    if (pos < 0)
        return false;
    offset = static_cast<size_t>(pos);
    return true;
}

bool jsonHasField(const String& body, const char* key) {
    return jsonFieldValuePosition(body, key) >= 0;
}

bool jsonBoolField(const String& body, const char* key, bool defaultValue) {
    const int pos = jsonFieldValuePosition(body, key);
    if (pos < 0)
        return defaultValue;
    if (jsonStartsWithAt(body, static_cast<size_t>(pos), "true"))
        return true;
    if (jsonStartsWithAt(body, static_cast<size_t>(pos), "false"))
        return false;
    return defaultValue;
}

bool jsonUintField(const String& body, const char* key, uint32_t& value) {
    const int posi = jsonFieldValuePosition(body, key);
    if (posi < 0)
        return false;
    size_t pos = static_cast<size_t>(posi);
    const size_t n = body.length();
    if (pos >= n || !isdigit(static_cast<unsigned char>(body.charAt(pos))))
        return false;
    uint64_t acc = 0;
    while (pos < n && isdigit(static_cast<unsigned char>(body.charAt(pos)))) {
        acc = acc * 10U + static_cast<uint64_t>(body.charAt(pos) - '0');
        if (acc > 0xFFFFFFFFULL)
            return false; // overflow guard (Addendum A5)
        ++pos;
    }
    if (pos < n && !isJsonValueTerminator(body.charAt(pos)))
        return false;
    value = static_cast<uint32_t>(acc);
    return true;
}

bool jsonFloatField(const String& body, const char* key, float& value) {
    const int posi = jsonFieldValuePosition(body, key);
    if (posi < 0)
        return false;
    size_t end = 0;
    if (!skipJsonNumber(body, static_cast<size_t>(posi), end))
        return false;
    value = body.substring(posi, end).toFloat();
    return true;
}

bool jsonStringField(const String& body, const char* key, String& value) {
    const int posi = jsonFieldValuePosition(body, key);
    if (posi < 0)
        return false;
    if (body.charAt(static_cast<size_t>(posi)) != '"')
        return false;
    int endQuote = 0;
    return extractJsonStringAt(body, static_cast<size_t>(posi), value, endQuote);
}
