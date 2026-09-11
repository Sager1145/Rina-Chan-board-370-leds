#include "serial_log.h"

#if ENABLE_SERIAL_DIAGNOSTICS

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>

// -----------------------------------------------------------------------------
// Runtime state. Defaults are deliberately calm: enabled, INFO level. INFO and
// above (ERROR/WARN/INFO) cover button/mode/LED/command events without flooding
// the line; DEBUG adds ADC reads, TRACE adds scroll ticks. These are runtime
// adjustable via the `log level ...` and `log on|off` serial commands.
// -----------------------------------------------------------------------------
static bool sLogEnabled = true;
static RinaLogLevel sLogLevel = RINA_LOG_INFO;
static RinaLogSink sLogSink = nullptr;

void rinaLogSetSink(RinaLogSink sink) { sLogSink = sink; }

static char levelChar(RinaLogLevel level) {
    switch (level) {
    case RINA_LOG_ERROR: return 'E';
    case RINA_LOG_WARN: return 'W';
    case RINA_LOG_INFO: return 'I';
    case RINA_LOG_DEBUG: return 'D';
    case RINA_LOG_TRACE: return 'T';
    default: return 'I';
    }
}

// Line assembly happens into a stack buffer and is flushed with a single
// Serial.write so two cores can never interleave a partial line.
static constexpr size_t LOG_LINE_MAX = 240;

void rinaLogInit() {
    rinaSerialInit();
}

void rinaLogSetEnabled(bool enabled) { sLogEnabled = enabled; }
bool rinaLogEnabled() { return sLogEnabled; }
void rinaLogSetLevel(RinaLogLevel level) { sLogLevel = level; }
RinaLogLevel rinaLogLevel() { return sLogLevel; }

const char* rinaLogLevelName(RinaLogLevel level) {
    switch (level) {
    case RINA_LOG_ERROR:
        return "ERROR";
    case RINA_LOG_WARN:
        return "WARN";
    case RINA_LOG_INFO:
        return "INFO";
    case RINA_LOG_DEBUG:
        return "DEBUG";
    case RINA_LOG_TRACE:
        return "TRACE";
    default:
        return "INFO";
    }
}

bool rinaLogParseLevel(const char* name, RinaLogLevel& out) {
    if (!name)
        return false;
    if (strcasecmp(name, "ERROR") == 0) {
        out = RINA_LOG_ERROR;
        return true;
    }
    if (strcasecmp(name, "WARN") == 0) {
        out = RINA_LOG_WARN;
        return true;
    }
    if (strcasecmp(name, "INFO") == 0) {
        out = RINA_LOG_INFO;
        return true;
    }
    if (strcasecmp(name, "DEBUG") == 0) {
        out = RINA_LOG_DEBUG;
        return true;
    }
    if (strcasecmp(name, "TRACE") == 0) {
        out = RINA_LOG_TRACE;
        return true;
    }
    return false;
}

bool rinaLogShouldEmit(RinaLogLevel level) {
    return sLogEnabled && level <= sLogLevel;
}

void rinaSerialInit() {
#if ENABLE_SERIAL_UART0_MIRROR
    static bool started = false;
    if (!started) {
        Serial0.begin(115200);
        started = true;
    }
#endif
}

void rinaSerialWrite(const uint8_t* data, size_t len) {
    if (!data || len == 0)
        return;
    Serial.write(data, len);
#if ENABLE_SERIAL_UART0_MIRROR
    Serial0.write(data, len);
#endif
}

void rinaLogEmit(RinaLogLevel level, const char* category, const char* fmt, ...) {
    char buf[LOG_LINE_MAX];

    // Header: "[<ms> ms] [<LEVEL>] [<CAT>] "
    int n = snprintf(buf, sizeof(buf), "[%lu ms] [%s] [%s] ",
                     static_cast<unsigned long>(millis()),
                     rinaLogLevelName(level),
                     category ? category : "?");
    if (n < 0)
        return;
    if (static_cast<size_t>(n) >= sizeof(buf))
        n = sizeof(buf) - 1;

    // Body.
    const int headerLen = n;
    va_list args;
    va_start(args, fmt);
    int m = vsnprintf(buf + n, sizeof(buf) - static_cast<size_t>(n), fmt, args);
    va_end(args);
    if (m > 0) {
        n += m;
        if (static_cast<size_t>(n) >= sizeof(buf))
            n = sizeof(buf) - 1;
    }

    // vsnprintf always null-terminates within its bounds, so buf+headerLen is
    // a valid C string here regardless of truncation. Callable from any task.
    if (sLogSink)
        sLogSink(levelChar(level), category ? category : "?", buf + headerLen);

    // Trailing newline inside the same buffer -> one write, no interleave.
    if (static_cast<size_t>(n) < sizeof(buf) - 1) {
        buf[n++] = '\n';
    } else {
        buf[sizeof(buf) - 1] = '\n';
        n = sizeof(buf);
    }
    rinaSerialWrite(reinterpret_cast<const uint8_t*>(buf), static_cast<size_t>(n));
}

bool rinaLogRateReady(uint32_t& lastMs, uint32_t intervalMs) {
    const uint32_t now = millis();
    if (lastMs != 0 && (now - lastMs) < intervalMs)
        return false;
    lastMs = now;
    return true;
}

#endif // ENABLE_SERIAL_DIAGNOSTICS
