#include "web_json.h"
#include <ctype.h>

/**
 * @brief Locate a top-level-ish JSON field value in a request body string.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @return String index of first non-space value char, or -1 when absent.
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
 * @brief Find the closing quote for a JSON string literal.
 * @param body Raw JSON request body.
 * @param quotePos Index of the opening quote.
 * @return Closing quote index, or -1 when unterminated/invalid.
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
 * @brief Extract and minimally unescape a JSON string at a known quote position.
 * @param body Raw JSON request body.
 * @param quotePos Opening quote index.
 * @param value Receives unescaped string content.
 * @param endQuote Receives closing quote index.
 * @return true when a complete string was extracted.
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

        // The scroll upload parser only needs common JSON escapes in M370/text
        // fields.  Unicode escapes are left as their trailing character payload
        // instead of allocating a full decoder on the microcontroller.
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
 * @brief Read a boolean field from a small raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param defaultValue Value returned when key is absent or malformed.
 * @return Parsed boolean or defaultValue.
 */
bool jsonBoolField(const String& body, const char* key, bool defaultValue) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0) return defaultValue;
    if (body.substring(p, p + 4) == "true") return true;
    if (body.substring(p, p + 5) == "false") return false;
    return defaultValue;
}

/**
 * @brief Read an unsigned integer field from a raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param value Receives parsed integer.
 * @return true when the field was present and numeric.
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
 * @brief Read a floating-point field from a raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param value Receives parsed float.
 * @return true when the field was present and numeric-looking.
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
 * @brief Read a string field from a raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param value Receives extracted string.
 * @return true when the field was present and a JSON string.
 */
bool jsonStringField(const String& body, const char* key, String& value) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0 || static_cast<size_t>(p) >= body.length() || body.charAt(p) != '"') return false;

    int endQuote = -1;
    return extractJsonStringAt(body, static_cast<size_t>(p), value, endQuote);
}
