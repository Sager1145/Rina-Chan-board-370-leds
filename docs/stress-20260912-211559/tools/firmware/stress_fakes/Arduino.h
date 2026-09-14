// Host fake of the minimal Arduino-ESP32 surface used by the RinaBoard firmware
// sources compiled in the stress harnesses. Test shim only: no product logic.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <type_traits>

// ---- fake clock (controlled by harnesses via fake_hooks.h) -----------------
extern uint64_t g_fakeMicros;
inline uint32_t millis() { return static_cast<uint32_t>(g_fakeMicros / 1000ULL); }
inline uint32_t micros() { return static_cast<uint32_t>(g_fakeMicros); }
inline void delay(uint32_t ms) { g_fakeMicros += static_cast<uint64_t>(ms) * 1000ULL; }
inline void delayMicroseconds(uint32_t us) { g_fakeMicros += us; }

template <typename T, typename A, typename B>
inline T constrain(T v, A lo, B hi) {
    if (v < static_cast<T>(lo)) return static_cast<T>(lo);
    if (v > static_cast<T>(hi)) return static_cast<T>(hi);
    return v;
}

#define portMAX_DELAY 0xFFFFFFFFU
struct portMUX_TYPE { int owner; };
#define portMUX_INITIALIZER_UNLOCKED {0}
#define portENTER_CRITICAL(m) ((void)(m))
#define portEXIT_CRITICAL(m) ((void)(m))
#define portENTER_CRITICAL_SAFE(m) ((void)(m))
#define portEXIT_CRITICAL_SAFE(m) ((void)(m))

inline size_t strlcpy(char* dst, const char* src, size_t size) {
    size_t n = std::strlen(src);
    if (size) {
        size_t c = n >= size ? size - 1 : n;
        std::memcpy(dst, src, c);
        dst[c] = '\0';
    }
    return n;
}

class String {
public:
    std::string s;
    String() = default;
    String(const char* c) : s(c ? c : "") {}
    String(const char* c, unsigned int len) : s(c ? std::string(c, len) : std::string()) {}
    String(const std::string& x) : s(x) {}
    explicit String(char c) : s(1, c) {}
    template <typename T, typename std::enable_if<std::is_integral<T>::value && !std::is_same<T, char>::value && !std::is_same<T, bool>::value, int>::type = 0>
    explicit String(T v) : s(std::to_string(v)) {}
    const char* c_str() const { return s.c_str(); }
    unsigned int length() const { return static_cast<unsigned int>(s.size()); }
    bool isEmpty() const { return s.empty(); }
    char charAt(unsigned int i) const { return i < s.size() ? s[i] : 0; }
    bool concat(const char* c) { if (c) s += c; return true; }
    bool concat(const String& o) { s += o.s; return true; }
    bool reserve(unsigned int n) { s.reserve(n); return true; }
    void trim() {
        size_t b = s.find_first_not_of(" \t\r\n\f\v");
        if (b == std::string::npos) { s.clear(); return; }
        size_t e = s.find_last_not_of(" \t\r\n\f\v");
        s = s.substr(b, e - b + 1);
    }
    void toLowerCase() { for (auto& ch : s) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch))); }
    String& operator=(const char* c) { s = c ? c : ""; return *this; }
    String& operator+=(const String& o) { s += o.s; return *this; }
    String& operator+=(const char* c) { if (c) s += c; return *this; }
    String& operator+=(char c) { s += c; return *this; }
    bool operator==(const String& o) const { return s == o.s; }
    bool operator!=(const String& o) const { return s != o.s; }
    bool operator==(const char* c) const { return s == (c ? c : ""); }
    bool operator!=(const char* c) const { return !(*this == c); }
    friend String operator+(const String& a, const String& b) { return String(a.s + b.s); }
    friend String operator+(const String& a, const char* b) { return String(a.s + (b ? b : "")); }
    friend String operator+(const char* a, const String& b) { return String(std::string(a ? a : "") + b.s); }
    template <typename T, typename std::enable_if<std::is_integral<T>::value && !std::is_same<T, char>::value, int>::type = 0>
    friend String operator+(const String& a, T v) { return String(a.s + std::to_string(v)); }
};

struct FakeSerial {
    void printf(const char*, ...) {}
    void println(const char* = "") {}
    void println(const String&) {}
    void print(const char*) {}
    void begin(unsigned long) {}
};
extern FakeSerial Serial;

struct FakeEsp {
    uint32_t getFreeHeap() { return 200000; }
    uint32_t getFreePsram() { return 4000000; }
    uint32_t getPsramSize() { return 8000000; }
    void restart();
};
extern FakeEsp ESP;
