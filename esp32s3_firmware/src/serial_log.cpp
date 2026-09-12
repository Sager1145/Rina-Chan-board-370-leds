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

// Both physical sinks get an independent bounded FIFO. Log traffic may use
// only the non-reserved portion; console replies can consume the reserve so a
// `status` response remains observable during a TRACE burst.
static constexpr size_t SERIAL_TX_QUEUE_BYTES = 2048;
static constexpr size_t SERIAL_TX_CONSOLE_RESERVE = 768;
static constexpr size_t SERIAL_TX_PUMP_BUDGET = 128;

struct SerialTxQueue {
    uint8_t bytes[SERIAL_TX_QUEUE_BYTES] = {};
    size_t head = 0;
    size_t count = 0;
    bool pumping = false;
};

static SerialTxQueue sUsbTx;
#if ENABLE_SERIAL_UART0_MIRROR
static SerialTxQueue sUart0Tx;
#endif
static portMUX_TYPE sSerialTxMux = portMUX_INITIALIZER_UNLOCKED;

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

static bool enqueueSerialBytes(SerialTxQueue& queue, const uint8_t* data, size_t len,
                               size_t reserve) {
    if (!data || len == 0 || len > SERIAL_TX_QUEUE_BYTES)
        return false;
    bool accepted = false;
    portENTER_CRITICAL(&sSerialTxMux);
    const size_t freeBytes = SERIAL_TX_QUEUE_BYTES - queue.count;
    if (freeBytes >= len && freeBytes - len >= reserve) {
        size_t tail = (queue.head + queue.count) % SERIAL_TX_QUEUE_BYTES;
        for (size_t i = 0; i < len; ++i) {
            queue.bytes[tail] = data[i];
            tail = (tail + 1) % SERIAL_TX_QUEUE_BYTES;
        }
        queue.count += len;
        accepted = true;
    }
    portEXIT_CRITICAL(&sSerialTxMux);
    return accepted;
}

template <typename Port>
static void pumpSerialQueue(SerialTxQueue& queue, Port& port) {
    uint8_t chunk[SERIAL_TX_PUMP_BUDGET];
    size_t requested = 0;

    portENTER_CRITICAL(&sSerialTxMux);
    if (!queue.pumping && queue.count > 0) {
        queue.pumping = true;
        requested = queue.count < sizeof(chunk) ? queue.count : sizeof(chunk);
        for (size_t i = 0; i < requested; ++i)
            chunk[i] = queue.bytes[(queue.head + i) % SERIAL_TX_QUEUE_BYTES];
    }
    portEXIT_CRITICAL(&sSerialTxMux);
    if (requested == 0)
        return;

    const int available = port.availableForWrite();
    size_t writable = available > 0 ? static_cast<size_t>(available) : 0;
    if (writable > requested)
        writable = requested;
    const size_t written = writable > 0 ? port.write(chunk, writable) : 0;

    portENTER_CRITICAL(&sSerialTxMux);
    const size_t consumed = written < requested ? written : requested;
    queue.head = (queue.head + consumed) % SERIAL_TX_QUEUE_BYTES;
    queue.count -= consumed;
    queue.pumping = false;
    portEXIT_CRITICAL(&sSerialTxMux);
}

static void enqueueMirrored(const uint8_t* data, size_t len, bool consolePriority) {
    const size_t reserve = consolePriority ? 0 : SERIAL_TX_CONSOLE_RESERVE;
#if ENABLE_SERIAL_UART0_MIRROR
    enqueueSerialBytes(sUart0Tx, data, len, reserve);
#endif
#if ARDUINO_USB_CDC_ON_BOOT
    if (Serial)
#endif
        enqueueSerialBytes(sUsbTx, data, len, reserve);
}

static void pumpMirrored() {
#if ENABLE_SERIAL_UART0_MIRROR
    pumpSerialQueue(sUart0Tx, Serial0);
#endif
#if ARDUINO_USB_CDC_ON_BOOT
    if (Serial)
#endif
        pumpSerialQueue(sUsbTx, Serial);
}

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
#if ARDUINO_USB_CDC_ON_BOOT
    // Diagnostics must never be able to stall the board. The native USB CDC
    // only drains while a host actually has the port open; when the port is
    // merely powered (or the host app closed it) its TX ring fills and a
    // blocking write() parks the calling task forever. A zero timeout turns
    // that into a dropped line instead of a hang.
    Serial.setTxTimeoutMs(0);
#endif
#if ENABLE_SERIAL_UART0_MIRROR
    static bool started = false;
    if (!started) {
        // Keep the driver TX ring disabled. pumpSerialQueue() writes no more
        // than the hardware FIFO reports free, so UART output never waits for
        // a full 240-byte log line to shift at 115200 baud.
        Serial0.setTxBufferSize(0);
        Serial0.begin(115200);
        started = true;
    }
#endif
}

void rinaSerialWrite(const uint8_t* data, size_t len) {
    if (data && len > 0)
        enqueueMirrored(data, len, true);
    pumpMirrored();
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
    // Logs are best-effort. Keep a reserve for command replies, and pump only
    // bytes that each transport reports writable right now.
    enqueueMirrored(reinterpret_cast<const uint8_t*>(buf), static_cast<size_t>(n), false);
    pumpMirrored();
}

bool rinaLogRateReady(uint32_t& lastMs, uint32_t intervalMs) {
    const uint32_t now = millis();
    if (lastMs != 0 && (now - lastMs) < intervalMs)
        return false;
    lastMs = now;
    return true;
}

#endif // ENABLE_SERIAL_DIAGNOSTICS
