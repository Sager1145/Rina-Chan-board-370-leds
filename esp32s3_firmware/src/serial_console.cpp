#include "serial_console.h"

#if ENABLE_SERIAL_CONSOLE

#include <Arduino.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>

#include <esp_heap_caps.h>

#include "state.h"
#include "led_renderer.h"
#include "led_driver.h"
#include "buttons.h"
#include "faces.h"
#include "power_monitor.h"
#include "serial_log.h"
#include "transport_ble.h"
#include "board_identity.h"
#include "wifi_manager.h"

namespace {
constexpr uint16_t SERIAL_CMD_MAX = 192;
constexpr uint16_t SERIAL_RX_BUDGET_PER_PORT = 64;

enum class SerialByteResult : uint8_t {
    None,
    LineReady,
    LineTooLong,
};

struct SerialLineBuffer {
    char bytes[SERIAL_CMD_MAX];
    uint16_t length = 0;
    bool discarding = false;
};

SerialLineBuffer sUsbLine;
#if ENABLE_SERIAL_UART0_MIRROR
SerialLineBuffer sUart0Line;
#endif

void sout(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void sout(const char* fmt, ...) {
    char buf[256];
    va_list a;
    va_start(a, fmt);
    int n = vsnprintf(buf, sizeof(buf) - 2, fmt, a);
    va_end(a);
    if (n < 0)
        return;
    if (n > static_cast<int>(sizeof(buf)) - 2)
        n = sizeof(buf) - 2;
    buf[n++] = '\n';
    rinaSerialWrite(reinterpret_cast<const uint8_t*>(buf), n);
}

int tokenize(char* line, char** argv, int maxArgs) {
    int argc = 0;
    char* p = line;
    while (*p && argc < maxArgs) {
        while (*p == ' ' || *p == '\t')
            ++p;
        if (!*p)
            break;
        argv[argc++] = p;
        while (*p && *p != ' ' && *p != '\t')
            ++p;
        if (*p)
            *p++ = '\0';
    }
    return argc;
}

bool hexByte(const char* text, uint8_t& out) {
    if (!isxdigit(text[0]) || !isxdigit(text[1]))
        return false;
    char tmp[3] = {text[0], text[1], 0};
    out = static_cast<uint8_t>(strtoul(tmp, nullptr, 16));
    return true;
}

bool parsePackedHex(const char* hex, uint8_t* out) {
    if (!hex || strlen(hex) != FRAME_BYTES * 2U)
        return false;
    for (uint16_t i = 0; i < FRAME_BYTES; ++i) {
        if (!hexByte(hex + i * 2U, out[i]))
            return false;
    }
    String error;
    return validatePackedFrame(out, error);
}

void printStatus() {
    const FrameStateSnapshot f = readFrameStateSnapshot();
    char bleName[MAX_DEVICE_NAME_BYTES + 1];
    char defaultBleName[MAX_DEVICE_NAME_BYTES + 1];
    bleTransportDeviceName(bleName, sizeof(bleName));
    bleTransportDefaultDeviceName(defaultBleName, sizeof(defaultBleName));
    sout("=== STATUS BEGIN ===");
    sout("STATUS bleName=%s bleDefaultName=%s bleCustomName=%d",
         bleName, defaultBleName, runtimeState().deviceName.length() > 0 ? 1 : 0);
    sout("STATUS boardId=%s apSsid=%s hostname=%s",
         boardId(), wifiManagerApSsid().c_str(), boardHostname().c_str());
    sout("STATUS mode=%s playback=%s paused=%d brightness=%u color=%s", runtimeState().mode.c_str(), runtimeState().playback.c_str(), runtimeState().paused ? 1 : 0, f.brightness, f.colorHex);
    sout("STATUS faceIndex=%u faceCount=%u intervalMs=%lu", static_cast<unsigned>(runtimeState().autoFaceIndex), static_cast<unsigned>(runtimeAutoFaceCount()), static_cast<unsigned long>(runtimeState().autoIntervalMs));
    sout("STATUS frameEncoding=packed-lsb-first frameBytes=%u lit=%u queued=%u accepted=%lu lastReason=%s", static_cast<unsigned>(FRAME_BYTES), static_cast<unsigned>(f.litLeds), static_cast<unsigned>(queuedPackedFrameCount()), static_cast<unsigned long>(f.framesAccepted), f.lastReason);
    sout("STATUS ledBackend=%s dma=%d ledReady=%d refreshUs=%lu refreshMaxUs=%lu refreshFail=%lu",
         leddrv::backendName(), leddrv::dmaEnabled() ? 1 : 0, leddrv::ready() ? 1 : 0,
         static_cast<unsigned long>(leddrv::lastRefreshUs()),
         static_cast<unsigned long>(leddrv::maxRefreshUs()),
         static_cast<unsigned long>(leddrv::refreshFailCount()));
    sout("STATUS heapFree=%u largestBlock=%u",
         static_cast<unsigned>(ESP.getFreeHeap()),
         static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_8BIT)));
    sout("=== STATUS END ===");
}

void printHelp() {
    sout("Commands:");
    sout("  help");
    sout("  status");
    sout("  frame clear");
    sout("  frame hex <94 packed-byte hex chars>");
    sout("  btn <B1..B6>");
    sout("  color <#RRGGBB>");
    sout("  bright <10..200>");
    sout("  log on|off");
    sout("  log level <lvl>");
    sout("Packed frame format: 47 bytes, logical LED index, LSB-first within each byte.");
}

void runLine(char* line) {
    char* argv[6] = {};
    const int argc = tokenize(line, argv, 6);
    if (argc == 0)
        return;
    if (strcasecmp(argv[0], "help") == 0) {
        printHelp();
        return;
    }
    if (strcasecmp(argv[0], "status") == 0) {
        printStatus();
        return;
    }
    if (strcasecmp(argv[0], "frame") == 0 && argc >= 2) {
        if (strcasecmp(argv[1], "clear") == 0) {
            takeOverExternalFrame();
            applyBlankFrame("serial_frame_clear");
            sout("OK frame clear");
            return;
        }
        if (strcasecmp(argv[1], "hex") == 0 && argc >= 3) {
            uint8_t packed[FRAME_BYTES];
            if (!parsePackedHex(argv[2], packed)) {
                sout("ERR frame invalid packed hex");
                return;
            }
            takeOverExternalFrame();
            String error;
            if (!applyPackedFrameQueued(packed, "serial_frame_hex", error)) {
                sout("ERR frame %s", error.c_str());
                return;
            }
            sout("OK frame hex bytes=%u", static_cast<unsigned>(FRAME_BYTES));
            return;
        }
    }
    if (strcasecmp(argv[0], "btn") == 0 && argc >= 2) {
        if (runButtonAction(String(argv[1]), "serial"))
            sout("OK btn %s", argv[1]);
        else
            sout("ERR btn invalid");
        return;
    }
    if (strcasecmp(argv[0], "color") == 0 && argc >= 2) {
        String error;
        if (setColor(String(argv[1]), error))
            sout("OK color %s", runtimeState().colorHex.c_str());
        else
            sout("ERR color %s", error.c_str());
        return;
    }
    if (strcasecmp(argv[0], "bright") == 0 && argc >= 2) {
        setBrightness(atoi(argv[1]));
        sout("OK bright %u", runtimeState().brightness);
        return;
    }
    if (strcasecmp(argv[0], "log") == 0 && argc >= 2) {
        if (strcasecmp(argv[1], "on") == 0) {
            rinaLogSetEnabled(true);
            sout("OK log on");
            return;
        }
        if (strcasecmp(argv[1], "off") == 0) {
            rinaLogSetEnabled(false);
            sout("OK log off");
            return;
        }
        if (strcasecmp(argv[1], "level") == 0 && argc >= 3) {
            RinaLogLevel level;
            if (!rinaLogParseLevel(argv[2], level)) {
                sout("ERR log level invalid");
                return;
            }
            rinaLogSetLevel(level);
            sout("OK log level %s", rinaLogLevelName(level));
            return;
        }
    }
    sout("ERR unknown command; type help");
}

SerialByteResult acceptSerialByte(SerialLineBuffer& line, char c) {
    if (c == '\r')
        return SerialByteResult::None;
    if (c == '\n') {
        if (line.discarding) {
            line.discarding = false;
            line.length = 0;
            return SerialByteResult::LineTooLong;
        }
        line.bytes[line.length] = '\0';
        return SerialByteResult::LineReady;
    }
    if (line.discarding)
        return SerialByteResult::None;
    if (line.length + 1 < SERIAL_CMD_MAX) {
        line.bytes[line.length++] = c;
    } else {
        // Discard the entire physical line. Resetting length alone would allow
        // its suffix to become a separate command at the following newline.
        line.length = 0;
        line.discarding = true;
    }
    return SerialByteResult::None;
}

void serviceSerialInput(Stream& input, SerialLineBuffer& line) {
    uint16_t remaining = SERIAL_RX_BUDGET_PER_PORT;
    while (remaining > 0 && input.available() > 0) {
        --remaining;
        const char c = static_cast<char>(input.read());
        const SerialByteResult result = acceptSerialByte(line, c);
        if (result == SerialByteResult::LineReady) {
            runLine(line.bytes);
            line.length = 0;
        } else if (result == SerialByteResult::LineTooLong) {
            sout("ERR command too long");
        }
    }
}
} // namespace

void initSerialConsole() {
    sUsbLine = SerialLineBuffer{};
#if ENABLE_SERIAL_UART0_MIRROR
    sUart0Line = SerialLineBuffer{};
#endif
    sout("Serial console ready. Type help.");
}

void serviceSerialConsole() {
    serviceSerialInput(Serial, sUsbLine);
#if ENABLE_SERIAL_UART0_MIRROR
    serviceSerialInput(Serial0, sUart0Line);
#endif
}

#else
void initSerialConsole() {}
void serviceSerialConsole() {}
#endif
