#pragma once
#include <Arduino.h>

/**
 * @brief Find the closing quote for a JSON string literal.
 * @param body Raw JSON request body.
 * @param quotePos Index of the opening quote.
 * @return Closing quote index, or -1 when invalid.
 */
int findJsonStringEnd(const String& body, size_t quotePos);

/**
 * @brief Extract and minimally unescape a JSON string at a known quote position.
 * @param body Raw JSON request body.
 * @param quotePos Opening quote index.
 * @param value Receives unescaped string content.
 * @param endQuote Receives closing quote index.
 * @return true when a complete string was extracted.
 */
bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote);

/**
 * @brief Read a boolean field from a raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param defaultValue Value returned when absent or malformed.
 * @return Parsed boolean or defaultValue.
 */
bool jsonBoolField(const String& body, const char* key, bool defaultValue);

/**
 * @brief Read an unsigned integer field from a raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param value Receives parsed integer.
 * @return true when present and numeric.
 */
bool jsonUintField(const String& body, const char* key, uint32_t& value);

/**
 * @brief Read a floating-point field from a raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param value Receives parsed float.
 * @return true when present and numeric-looking.
 */
bool jsonFloatField(const String& body, const char* key, float& value);

/**
 * @brief Read a string field from a raw JSON request.
 * @param body Raw JSON request body.
 * @param key Field name without quotes.
 * @param value Receives extracted string.
 * @return true when present and a JSON string.
 */
bool jsonStringField(const String& body, const char* key, String& value);
