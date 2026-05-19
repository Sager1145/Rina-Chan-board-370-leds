#include "web_json.h"
#include <ctype.h>

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

bool jsonBoolField(const String& body, const char* key, bool defaultValue) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0) return defaultValue;
    if (body.substring(p, p + 4) == "true") return true;
    if (body.substring(p, p + 5) == "false") return false;
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
