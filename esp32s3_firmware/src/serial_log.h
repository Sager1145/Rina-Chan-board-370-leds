#pragma once
#include <Arduino.h>
#include "config.h"

// =============================================================================
// serial_log -- structured, leveled, runtime-toggleable diagnostic logger.
//
// All firmware events route through the RLOG_* macros so a host script or AI
// agent can parse a single, machine-readable line per event. Output is always a
// SINGLE Serial.write() call (newline embedded) so lines never interleave even
// when Core-0 and the Core-1 render task both log.
//
// Line format (stable contract -- do not reorder fields):
//   [<millis> ms] [<LEVEL>] [<CATEGORY>] key=value key=value ...
// Example:
//   [123456 ms] [INFO] [BUTTON] source=physical id=B1 event=press
//
// Compile gate: ENABLE_SERIAL_DIAGNOSTICS (default 1). When 0, every RLOG_*
// macro becomes `do {} while (0)` -- byte-for-byte identical to a build with no
// logging, so a production image is unaffected.
// =============================================================================

#ifndef ENABLE_SERIAL_DIAGNOSTICS
#define ENABLE_SERIAL_DIAGNOSTICS 1
#endif

// Log severity. Lower numeric value == higher priority / always shown first.
enum RinaLogLevel : uint8_t {
    RINA_LOG_ERROR = 0,
    RINA_LOG_WARN  = 1,
    RINA_LOG_INFO  = 2,
    RINA_LOG_DEBUG = 3,
    RINA_LOG_TRACE = 4,
};

// Recent-LED-command ring record (history for `led command_history`).
struct LedCmdRecord {
    uint32_t ms   = 0;
    uint16_t lit  = 0;
    char     reason[40] = {0};
    char     source[12] = {0};
};

#if ENABLE_SERIAL_DIAGNOSTICS

// Lifecycle / runtime control (driven by the `log ...` serial commands).
void         rinaLogInit();
void         rinaLogSetEnabled(bool enabled);
bool         rinaLogEnabled();
void         rinaLogSetLevel(RinaLogLevel level);
RinaLogLevel rinaLogLevel();
const char*  rinaLogLevelName(RinaLogLevel level);
bool         rinaLogParseLevel(const char* name, RinaLogLevel& out);  // case-insensitive

// True if a message at `level` would currently be printed. Used by the macros
// so the (potentially expensive) argument formatting is skipped when disabled.
bool rinaLogShouldEmit(RinaLogLevel level);

// Emit one fully-formatted line (single Serial.write, newline embedded).
void rinaLogEmit(RinaLogLevel level, const char* category, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

// Shared diagnostics transport. The primary port is Serial (USB-CDC when
// ARDUINO_USB_CDC_ON_BOOT=1). With ENABLE_SERIAL_UART0_MIRROR=1, writes are
// mirrored to Serial0 and reads drain whichever port has buffered input.
void rinaSerialInit();
void rinaSerialWrite(const uint8_t* data, size_t len);
int  rinaSerialAvailable();
int  rinaSerialRead();

// Rate-limit helper for high-frequency call sites (e.g. scroll tick). Returns
// true at most once per `intervalMs`; pass a static uint32_t cursor.
bool rinaLogRateReady(uint32_t& lastMs, uint32_t intervalMs);

// LED command history ring (output-only; pushed by the LED apply path).
void    rinaLogRecordLedCommand(const char* reason, uint16_t lit, const char* source);
uint8_t rinaLogCopyLedHistory(LedCmdRecord* out, uint8_t maxEntries);  // newest last
uint8_t rinaLogLedHistoryCapacity();

#define RLOG_AT(level, cat, ...)                                                \
    do {                                                                        \
        if (rinaLogShouldEmit(level)) rinaLogEmit((level), (cat), __VA_ARGS__); \
    } while (0)

#define RLOG_ERROR(cat, ...) RLOG_AT(RINA_LOG_ERROR, cat, __VA_ARGS__)
#define RLOG_WARN(cat, ...)  RLOG_AT(RINA_LOG_WARN, cat, __VA_ARGS__)
#define RLOG_INFO(cat, ...)  RLOG_AT(RINA_LOG_INFO, cat, __VA_ARGS__)
#define RLOG_DEBUG(cat, ...) RLOG_AT(RINA_LOG_DEBUG, cat, __VA_ARGS__)
#define RLOG_TRACE(cat, ...) RLOG_AT(RINA_LOG_TRACE, cat, __VA_ARGS__)

#else  // ENABLE_SERIAL_DIAGNOSTICS == 0  -> all calls compile away

static inline void         rinaLogInit() {}
static inline void         rinaLogSetEnabled(bool) {}
static inline bool         rinaLogEnabled() { return false; }
static inline void         rinaLogSetLevel(RinaLogLevel) {}
static inline RinaLogLevel rinaLogLevel() { return RINA_LOG_INFO; }
static inline const char*  rinaLogLevelName(RinaLogLevel) { return "INFO"; }
static inline bool         rinaLogParseLevel(const char*, RinaLogLevel&) { return false; }
static inline bool         rinaLogShouldEmit(RinaLogLevel) { return false; }
static inline void         rinaSerialInit() {}
static inline void         rinaSerialWrite(const uint8_t*, size_t) {}
static inline int          rinaSerialAvailable() { return 0; }
static inline int          rinaSerialRead() { return -1; }
static inline bool         rinaLogRateReady(uint32_t&, uint32_t) { return false; }
static inline void         rinaLogRecordLedCommand(const char*, uint16_t, const char*) {}
static inline uint8_t      rinaLogCopyLedHistory(LedCmdRecord*, uint8_t) { return 0; }
static inline uint8_t      rinaLogLedHistoryCapacity() { return 0; }

#define RLOG_ERROR(cat, ...) do {} while (0)
#define RLOG_WARN(cat, ...)  do {} while (0)
#define RLOG_INFO(cat, ...)  do {} while (0)
#define RLOG_DEBUG(cat, ...) do {} while (0)
#define RLOG_TRACE(cat, ...) do {} while (0)

#endif  // ENABLE_SERIAL_DIAGNOSTICS
