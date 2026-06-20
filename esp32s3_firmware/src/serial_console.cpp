#include "serial_console.h"

#if ENABLE_SERIAL_CONSOLE

#include <Arduino.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>

#include "config.h"
#include "state.h"
#include "sync.h"
#include "serial_log.h"
#include "buttons.h"
#include "faces.h"
#include "led_renderer.h"
#include "scroll_session.h"
#include "power_monitor.h"
#include "button_animations.h"

// =============================================================================
// Each command handler below documents, in its block comment:
//   - syntax            (what the user types)
//   - what it controls / tests
//   - hardware effect    (does it mutate LED / mode / scroll state?)
//   - expected reply     (the parseable line(s) it prints)
// Command replies are line-oriented: `OK <cmd> ...`, `ERR <cmd> <reason>`, or a
// dump wrapped in `=== <TAG> BEGIN ===` ... `=== <TAG> END ===`. Event side
// effects additionally emit the structured `[ms] [LEVEL] [CAT] ...` log lines.
// =============================================================================

namespace {

constexpr uint16_t SERIAL_CMD_MAX = 192;   // fixed line buffer; oversized lines dropped
constexpr uint8_t  MAX_ARGS       = 8;

// ---- single-write line output (atomic, never interleaves with Core-1 logs) --
void sout(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void sout(const char* fmt, ...) {
    char buf[256];
    va_list a;
    va_start(a, fmt);
    int n = vsnprintf(buf, sizeof(buf) - 1, fmt, a);
    va_end(a);
    if (n < 0) return;
    if (n > static_cast<int>(sizeof(buf)) - 2) n = sizeof(buf) - 2;
    buf[n++] = '\n';
    rinaSerialWrite(reinterpret_cast<const uint8_t*>(buf), static_cast<size_t>(n));
}

void toUpperInplace(char* s) {
    for (; *s; ++s) *s = static_cast<char>(toupper(static_cast<unsigned char>(*s)));
}

int tokenize(char* line, char** argv, int maxArgs) {
    int argc = 0;
    char* p = line;
    while (*p && argc < maxArgs) {
        while (*p == ' ' || *p == '\t') ++p;
        if (!*p) break;
        argv[argc++] = p;
        while (*p && *p != ' ' && *p != '\t') ++p;
        if (*p) *p++ = '\0';
    }
    return argc;
}

// =============================================================================
//  Button emulation scheduler
//  Timed jobs (hold auto-release, spaced repeats) serviced each loop so the
//  reader stays non-blocking. press/release/tap/combo are immediate.
// =============================================================================
enum EmuJobKind : uint8_t { EMU_NONE = 0, EMU_RELEASE, EMU_REPEAT };
struct EmuJob {
    EmuJobKind kind     = EMU_NONE;
    char       code[5]  = {0};
    uint32_t   dueMs    = 0;
    uint32_t   interval = 0;
    uint16_t   remaining = 0;
};
constexpr uint8_t EMU_JOB_SLOTS = 8;
EmuJob sEmuJobs[EMU_JOB_SLOTS];

EmuJob* allocEmuJob() {
    for (auto& j : sEmuJobs) if (j.kind == EMU_NONE) return &j;
    return nullptr;
}

void cancelReleaseJobsFor(const char* code) {
    for (auto& j : sEmuJobs) {
        if (j.kind == EMU_RELEASE && strcmp(j.code, code) == 0) j.kind = EMU_NONE;
    }
}

void serviceEmuJobs(uint32_t now) {
    for (auto& j : sEmuJobs) {
        if (j.kind == EMU_NONE) continue;
        if (static_cast<int32_t>(now - j.dueMs) < 0) continue;
        if (j.kind == EMU_RELEASE) {
            emulateButtonRawSet(j.code, false);
            j.kind = EMU_NONE;
        } else if (j.kind == EMU_REPEAT) {
            RLOG_INFO("BUTTON", "source=serial id=%s event=repeat", j.code);
            runButtonAction(String(j.code), "serial");
            if (j.remaining > 0) --j.remaining;
            if (j.remaining == 0) j.kind = EMU_NONE;
            else                  j.dueMs = now + j.interval;
        }
    }
}

// Map "B3+B1" -> "B3B1" (combo code). Returns nullptr if not a known combo.
const char* comboCode(const char* token) {
    if (strcmp(token, "B3+B1") == 0) return "B3B1";
    if (strcmp(token, "B3+B2") == 0) return "B3B2";
    return nullptr;
}

// Parse a '+'-joined button list ("B3+B1", "B4+B5", "B1+B2+B3") into validated,
// upper-cased codes. Returns the count (0 on any malformed/duplicate/unknown id,
// with *err set to a short reason). The order is preserved as typed, but note
// that the firmware always services the physical buttons in fixed array order
// (B1..B6) regardless of typing order -- exactly like real simultaneous presses.
uint8_t parseButtonList(const char* token, char codes[][5], uint8_t maxCodes,
                        const char** err) {
    *err = nullptr;
    uint8_t n = 0;
    const char* p = token;
    while (*p) {
        if (n >= maxCodes) { *err = "too_many"; return 0; }
        char one[5];
        uint8_t k = 0;
        while (*p && *p != '+') {
            if (k < sizeof(one) - 1) one[k++] = *p;
            ++p;
        }
        one[k] = '\0';
        if (*p == '+') ++p;            // skip separator
        if (k == 0) { *err = "empty_token"; return 0; }
        toUpperInplace(one);
        if (!buttonCodeValid(one)) { *err = "unknown_id"; return 0; }
        for (uint8_t i = 0; i < n; ++i) {
            if (strcmp(codes[i], one) == 0) { *err = "duplicate_id"; return 0; }
        }
        strlcpy(codes[n++], one, 5);
    }
    if (n == 0) *err = "empty";
    return n;
}

// =============================================================================
//  Frame helpers (LED dump / patterns)
// =============================================================================
void copyFrameSnapshot(uint8_t* out) {
    withFrameLock([&]() { memcpy(out, runtimeFrameBits(), FRAME_BYTES); });
}

void setPackedBit(uint8_t* bits, uint16_t index) {
    if (index < LED_COUNT) bits[index >> 3] |= static_cast<uint8_t>(1U << (index & 7U));
}

uint16_t countPackedLit(const uint8_t* bits) {
    uint16_t lit = 0;
    for (uint16_t i = 0; i < LED_COUNT; ++i) {
        if (packedFrameBit(bits, i)) ++lit;
    }
    return lit;
}

// Encode a packed frame into the canonical "M370:<93 hex>" string (pasteable
// into tests / `set` / applyM370). Bit order matches the firmware decoder:
// nibble nib covers bits [nib*4 .. nib*4+3], MSB-first within the nibble.
void packedToM370(const uint8_t* bits, char* out, size_t outSize) {
    static const char HEX_DIGITS[] = "0123456789abcdef";
    size_t pos = 0;
    if (outSize < 6 + M370_HEX_CHARS) { if (outSize) out[0] = '\0'; return; }
    memcpy(out, "M370:", 5);
    pos = 5;
    for (uint16_t nib = 0; nib < M370_HEX_CHARS; ++nib) {
        uint8_t value = 0;
        const uint16_t baseBit = static_cast<uint16_t>(nib) * 4U;
        for (uint8_t k = 0; k < 4U; ++k) {
            const uint16_t bit = baseBit + k;
            if (bit < M370_BITS && packedFrameBit(bits, bit)) value |= static_cast<uint8_t>(1U << (3 - k));
        }
        out[pos++] = HEX_DIGITS[value & 0x0F];
    }
    out[pos] = '\0';
}

uint16_t logicalRowOf(uint16_t index) {
    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        if (index >= ROW_OFFSETS[row] && index < ROW_OFFSETS[row] + ROW_LENGTHS[row]) return row;
    }
    return 0;
}

// =============================================================================
//  General commands
// =============================================================================

void printHelpAll();
void printHelpButtons();
void printHelpLed();
void printHelpAdc();
void printHelpLogs();
void printHelpTests();

// help [buttons|led|adc|logs|tests] -- list commands (this table IS the docs).
void cmdHelp(int argc, char** argv) {
    if (argc >= 2) {
        if (strcasecmp(argv[1], "buttons") == 0) { printHelpButtons(); return; }
        if (strcasecmp(argv[1], "led") == 0)     { printHelpLed();     return; }
        if (strcasecmp(argv[1], "adc") == 0)      { printHelpAdc();     return; }
        if (strcasecmp(argv[1], "logs") == 0)     { printHelpLogs();    return; }
        if (strcasecmp(argv[1], "tests") == 0)    { printHelpTests();   return; }
    }
    printHelpAll();
}

// status -- one-line-per-field runtime snapshot. Hardware effect: none (read).
void cmdStatus(int, char**) {
    const ScrollSessionSnapshot sc = scrollSessionSnapshot();
    const FrameStateSnapshot     f = readFrameStateSnapshot();
    sout("=== STATUS BEGIN ===");
    sout("STATUS mode=%s playback=%s paused=%d brightness=%u color=%s",
         runtimeState().mode.c_str(), runtimeState().playback.c_str(),
         runtimeState().paused ? 1 : 0, f.brightness, f.colorHex);
    sout("STATUS autoFaceIndex=%u faceCount=%u autoIntervalMs=%lu",
         static_cast<unsigned>(runtimeState().autoFaceIndex),
         static_cast<unsigned>(runtimeAutoFaceCount()),
         static_cast<unsigned long>(runtimeState().autoIntervalMs));
    sout("STATUS scrollActive=%d scrollPaused=%d userPaused=%d systemPaused=%d idx=%u count=%u interval=%u",
         sc.firmwareScrollActive ? 1 : 0, sc.firmwareScrollPaused ? 1 : 0,
         sc.firmwareScrollUserPaused ? 1 : 0, sc.firmwareScrollSystemPaused ? 1 : 0,
         static_cast<unsigned>(sc.scrollFrameIndex), static_cast<unsigned>(sc.scrollFrameCount),
         static_cast<unsigned>(sc.scrollIntervalMs));
    sout("STATUS lit=%u queued=%u framesAccepted=%lu lastReason=%s",
         f.litLeds, queuedM370FrameCount(),
         static_cast<unsigned long>(f.framesAccepted), f.lastReason);
    sout("STATUS commandsAccepted=%lu commandsRejected=%lu framesRejected=%lu",
         static_cast<unsigned long>(runtimeState().commandsAccepted),
         static_cast<unsigned long>(runtimeState().commandsRejected),
         static_cast<unsigned long>(runtimeState().framesRejected));
    sout("=== STATUS END ===");
}

// version -- firmware identity + active feature gates + free heap.
void cmdVersion(int, char**) {
    sout("OK version name=%s fw=%s", FIRMWARE_NAME, FIRMWARE_VERSION);
    sout("OK version diagnostics=%d console=%d tests=%d uart0_mirror=%d verbose=%d heap=%lu",
         ENABLE_SERIAL_DIAGNOSTICS, ENABLE_SERIAL_CONSOLE, ENABLE_FIRMWARE_TESTS,
         ENABLE_SERIAL_UART0_MIRROR, RINACHAN_VERBOSE_LOGS,
         static_cast<unsigned long>(ESP.getFreeHeap()));
}

// uptime -- milliseconds since boot, plus h:m:s.
void cmdUptime(int, char**) {
    const uint32_t ms = millis();
    const uint32_t s  = ms / 1000;
    sout("OK uptime ms=%lu hms=%lu:%02lu:%02lu",
         static_cast<unsigned long>(ms),
         static_cast<unsigned long>(s / 3600),
         static_cast<unsigned long>((s % 3600) / 60),
         static_cast<unsigned long>(s % 60));
}

// log level <ERROR|WARN|INFO|DEBUG|TRACE> | log on | log off | log status
// Controls the runtime verbosity of the structured logger. Hardware: none.
void cmdLog(int argc, char** argv) {
    if (argc >= 2 && strcasecmp(argv[1], "level") == 0 && argc >= 3) {
        RinaLogLevel lvl;
        if (!rinaLogParseLevel(argv[2], lvl)) { sout("ERR log unknown_level=%s", argv[2]); return; }
        rinaLogSetLevel(lvl);
        sout("OK log level=%s", rinaLogLevelName(lvl));
        return;
    }
    if (argc >= 2 && strcasecmp(argv[1], "on") == 0)  { rinaLogSetEnabled(true);  sout("OK log on");  return; }
    if (argc >= 2 && strcasecmp(argv[1], "off") == 0) { rinaLogSetEnabled(false); sout("OK log off"); return; }
    if (argc >= 2 && strcasecmp(argv[1], "status") == 0) {
        sout("OK log status enabled=%d level=%s", rinaLogEnabled() ? 1 : 0,
             rinaLogLevelName(rinaLogLevel()));
        return;
    }
    sout("ERR log usage='log level <ERROR|WARN|INFO|DEBUG|TRACE> | log on|off | log status'");
}

// =============================================================================
//  Button emulation commands
//  All paths reuse runButtonAction(code, "serial") or the real GPIO debounce
//  machine via the emulated-raw overlay, so behavior is identical to hardware.
// =============================================================================
//   btn press <ID>          : engage emulated hold (real debounce machine)
//   btn release <ID>        : release emulated hold
//   btn tap <ID>            : immediate logical action (source=serial)
//   btn hold <ID> <ms>      : press now, auto-release after ms (real repeats)
//   btn repeat <ID> <n> <ms>: fire the action n times spaced ms apart
//   btn multi <ID+ID+..> <ms>: press several buttons AT ONCE for <ms>, then
//                              release them together -- driven entirely through
//                              the real debounce/combo/repeat machine, so the
//                              outcome is byte-for-byte what physically pressing
//                              those buttons simultaneously would produce. This
//                              is the general form of "multiple buttons at once"
//                              and works for combos in the code (e.g. B3+B1) as
//                              well as arbitrary pairs that are NOT combos.
//   btn combo B3+B1 tap     : combo action (B3B1) -- legacy logical shortcut
//   btn combo B3+B1 hold ms : combo action (momentary; ms is advisory)
//   btn status              : per-button physical + emulated state
void cmdBtn(int argc, char** argv) {
    if (argc >= 2 && strcasecmp(argv[1], "status") == 0) {
        static const char* CODES[] = {"B1", "B2", "B3", "B4", "B5", "B6"};
        sout("=== BTN BEGIN ===");
        for (const char* c : CODES) {
            sout("BTN id=%s physical=%d serial=%d", c,
                 buttonPhysicalPressed(c) ? 1 : 0, buttonEmulatedPressed(c) ? 1 : 0);
        }
        sout("=== BTN END ===");
        return;
    }

    if (argc >= 2 && strcasecmp(argv[1], "multi") == 0) {
        if (argc < 3) {
            sout("ERR btn multi usage='btn multi <ID+ID+..> <ms>' (e.g. 'btn multi B3+B1 800')");
            return;
        }
        char codes[6][5];
        const char* perr = nullptr;
        const uint8_t n = parseButtonList(argv[2], codes, 6, &perr);
        if (n == 0) { sout("ERR btn multi %s=%s", perr ? perr : "bad_list", argv[2]); return; }
        const uint32_t ms = (argc >= 4) ? strtoul(argv[3], nullptr, 10) : 1000;

        // Engage every overlay in one shot so they all assert before the next
        // serviceHardwareButtons() pass debounces them in the SAME cycle -- i.e.
        // a genuine simultaneous press, not a typed sequence.
        for (uint8_t i = 0; i < n; ++i) emulateButtonRawSet(codes[i], true);

        // Schedule a synchronized release for each (same dueMs => they release
        // together). ms==0 means a momentary tap: one press cycle then release.
        bool slotsOk = true;
        const uint32_t due = millis() + ms;
        for (uint8_t i = 0; i < n; ++i) {
            EmuJob* job = allocEmuJob();
            if (!job) { slotsOk = false; break; }
            job->kind  = EMU_RELEASE;
            strlcpy(job->code, codes[i], sizeof(job->code));
            job->dueMs = due;
        }
        if (!slotsOk) {
            // Roll back so we never leave buttons stuck down if slots ran out.
            for (uint8_t i = 0; i < n; ++i) { cancelReleaseJobsFor(codes[i]); emulateButtonRawSet(codes[i], false); }
            sout("ERR btn multi no_job_slot count=%u", n);
            return;
        }
        sout("OK btn multi %s count=%u ms=%lu", argv[2], n, static_cast<unsigned long>(ms));
        return;
    }

    if (argc >= 2 && strcasecmp(argv[1], "combo") == 0) {
        if (argc < 4) { sout("ERR btn combo usage='btn combo B3+B1 tap|hold <ms>'"); return; }
        const char* code = comboCode(argv[2]);
        if (!code) { sout("ERR btn combo unknown=%s", argv[2]); return; }
        const bool handled = runButtonAction(String(code), "serial");
        if (strcasecmp(argv[3], "hold") == 0 && argc >= 5) {
            sout("OK btn combo %s hold ms=%s handled=%d", argv[2], argv[4], handled ? 1 : 0);
        } else {
            sout("OK btn combo %s tap handled=%d", argv[2], handled ? 1 : 0);
        }
        return;
    }

    if (argc < 3) { sout("ERR btn usage='btn <press|release|tap|hold|repeat> <ID> ...'"); return; }
    char code[5];
    strlcpy(code, argv[2], sizeof(code));
    toUpperInplace(code);
    if (!buttonCodeValid(code)) { sout("ERR btn unknown_id=%s", code); return; }

    if (strcasecmp(argv[1], "press") == 0) {
        emulateButtonRawSet(code, true);
        sout("OK btn press %s", code);
        return;
    }
    if (strcasecmp(argv[1], "release") == 0) {
        cancelReleaseJobsFor(code);
        emulateButtonRawSet(code, false);
        sout("OK btn release %s", code);
        return;
    }
    if (strcasecmp(argv[1], "tap") == 0) {
        const bool handled = runButtonAction(String(code), "serial");
        sout("OK btn tap %s handled=%d", code, handled ? 1 : 0);
        return;
    }
    if (strcasecmp(argv[1], "hold") == 0) {
        const uint32_t ms = (argc >= 4) ? strtoul(argv[3], nullptr, 10) : 1000;
        emulateButtonRawSet(code, true);
        EmuJob* job = allocEmuJob();
        if (!job) { emulateButtonRawSet(code, false); sout("ERR btn hold no_job_slot"); return; }
        job->kind = EMU_RELEASE;
        strlcpy(job->code, code, sizeof(job->code));
        job->dueMs = millis() + ms;
        sout("OK btn hold %s ms=%lu", code, static_cast<unsigned long>(ms));
        return;
    }
    if (strcasecmp(argv[1], "repeat") == 0) {
        const uint16_t n  = (argc >= 4) ? static_cast<uint16_t>(strtoul(argv[3], nullptr, 10)) : 1;
        const uint32_t iv = (argc >= 5) ? strtoul(argv[4], nullptr, 10) : 350;
        if (n == 0) { sout("ERR btn repeat count=0"); return; }
        // Fire the first immediately, schedule the remainder.
        RLOG_INFO("BUTTON", "source=serial id=%s event=repeat", code);
        runButtonAction(String(code), "serial");
        if (n > 1) {
            EmuJob* job = allocEmuJob();
            if (!job) { sout("ERR btn repeat no_job_slot"); return; }
            job->kind = EMU_REPEAT;
            strlcpy(job->code, code, sizeof(job->code));
            job->remaining = static_cast<uint16_t>(n - 1);
            job->interval  = iv;
            job->dueMs     = millis() + iv;
        }
        sout("OK btn repeat %s count=%u interval=%lu", code, n, static_cast<unsigned long>(iv));
        return;
    }
    sout("ERR btn unknown_subcmd=%s", argv[1]);
}

// =============================================================================
//  LED diagnostics commands  (all mutations go through existing apply paths)
// =============================================================================
void cmdLedStatus() {
    const ScrollSessionSnapshot sc = scrollSessionSnapshot();
    const FrameStateSnapshot     f = readFrameStateSnapshot();
    sout("OK led status mode=%s brightness=%u color=%s faceIndex=%u faceCount=%u",
         runtimeState().mode.c_str(), f.brightness, f.colorHex,
         static_cast<unsigned>(runtimeState().autoFaceIndex),
         static_cast<unsigned>(runtimeAutoFaceCount()));
    sout("OK led status lit=%u queuedPending=%u scrollActive=%d scrollIdx=%u lastReason=%s framesAccepted=%lu",
         f.litLeds, queuedM370FrameCount(), sc.firmwareScrollActive ? 1 : 0,
         static_cast<unsigned>(sc.scrollFrameIndex), f.lastReason,
         static_cast<unsigned long>(f.framesAccepted));
}

void cmdLedDump(bool compact) {
    uint8_t frame[FRAME_BYTES];
    copyFrameSnapshot(frame);
    if (compact) {
        char m370[6 + M370_HEX_CHARS];
        packedToM370(frame, m370, sizeof(m370));
        sout("OK led dump compact lit=%u %s", countPackedLit(frame), m370);
        return;
    }
    const FrameStateSnapshot f = readFrameStateSnapshot();
    sout("=== LEDS BEGIN ===");
    sout("LEDS lit=%u bright=%u color=%s", countPackedLit(frame), f.brightness, f.colorHex);
    char rowbuf[40];
    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        const uint16_t start = ROW_OFFSETS[row];
        const uint8_t  len   = ROW_LENGTHS[row];
        uint8_t i = 0;
        for (; i < len && i < sizeof(rowbuf) - 1; ++i) {
            rowbuf[i] = packedFrameBit(frame, static_cast<uint16_t>(start + i)) ? '#' : '.';
        }
        rowbuf[i] = '\0';
        sout("ROW%02u %s", row, rowbuf);
    }
    char m370[6 + M370_HEX_CHARS];
    packedToM370(frame, m370, sizeof(m370));
    sout("hex=%s", m370 + 5);  // 93 hex chars without the M370: prefix
    sout("=== LEDS END ===");
}

void cmdLedCommandHistory() {
    LedCmdRecord recs[16];
    const uint8_t cap = rinaLogLedHistoryCapacity();
    const uint8_t n   = rinaLogCopyLedHistory(recs, cap < 16 ? cap : 16);
    sout("=== LEDCMD BEGIN ===");
    sout("LEDCMD count=%u", n);
    for (uint8_t i = 0; i < n; ++i) {
        sout("LEDCMD ms=%lu reason=%s lit=%u source=%s",
             static_cast<unsigned long>(recs[i].ms), recs[i].reason, recs[i].lit, recs[i].source);
    }
    sout("=== LEDCMD END ===");
}

// Build + apply a named test pattern through applyPackedFrameImmediate (the
// same publish path the WebUI / scroll start use). Hardware effect: replaces
// the current frame.
void cmdLedTestPattern(int argc, char** argv) {
    if (argc < 4) { sout("ERR led test usage='led test pattern <checker|rows|cols|all_on|all_off|single N>'"); return; }
    const char* name = argv[3];
    uint8_t bits[FRAME_BYTES] = {0};

    if (strcasecmp(name, "all_off") == 0) {
        applyBlankFrameImmediate("serial_led_test_all_off");
        sout("OK led test pattern all_off lit=0");
        return;
    }
    if (strcasecmp(name, "all_on") == 0) {
        for (uint16_t i = 0; i < LED_COUNT; ++i) setPackedBit(bits, i);
    } else if (strcasecmp(name, "checker") == 0) {
        for (uint16_t i = 0; i < LED_COUNT; ++i) {
            const uint16_t row = logicalRowOf(i);
            const uint16_t col = i - ROW_OFFSETS[row];
            if (((row + col) & 1U) == 0) setPackedBit(bits, i);
        }
    } else if (strcasecmp(name, "rows") == 0) {
        for (uint16_t i = 0; i < LED_COUNT; ++i) {
            if ((logicalRowOf(i) & 1U) == 0) setPackedBit(bits, i);
        }
    } else if (strcasecmp(name, "cols") == 0) {
        for (uint16_t i = 0; i < LED_COUNT; ++i) {
            const uint16_t row = logicalRowOf(i);
            if (((i - ROW_OFFSETS[row]) & 1U) == 0) setPackedBit(bits, i);
        }
    } else if (strcasecmp(name, "single") == 0) {
        const uint16_t idx = (argc >= 5) ? static_cast<uint16_t>(strtoul(argv[4], nullptr, 10)) : 0;
        if (idx >= LED_COUNT) { sout("ERR led test single out_of_range=%u max=%u", idx, LED_COUNT - 1); return; }
        setPackedBit(bits, idx);
    } else {
        sout("ERR led test unknown_pattern=%s", name);
        return;
    }

    char reason[40];
    snprintf(reason, sizeof(reason), "serial_test_pattern_%s", name);
    stopFirmwareScroll(false, true);
    applyPackedFrameImmediate(bits, reason);
    sout("OK led test pattern %s lit=%u", name, countPackedLit(bits));
}

void cmdLed(int argc, char** argv) {
    if (argc < 2) { sout("ERR led usage='led <status|color|brightness|current|dump|clear|test|command_history>'"); return; }
    if (strcasecmp(argv[1], "status") == 0) { cmdLedStatus(); return; }
    // led color <#RRGGBB|RRGGBB> -- mirrors WebUI set_color. Hardware: changes
    // the global LED color (next render). Full 24-bit space is reachable.
    if (strcasecmp(argv[1], "color") == 0) {
        if (argc < 3) { sout("OK led color value=%s", runtimeState().colorHex.c_str()); return; }
        String err;
        if (setColor(argv[2], err)) sout("OK led color set=%s", runtimeState().colorHex.c_str());
        else                        sout("ERR led color %s", err.c_str());
        return;
    }
    if (strcasecmp(argv[1], "brightness") == 0) {
        if (argc >= 3) {
            const int v = atoi(argv[2]);
            setBrightness(v);
            sout("OK led brightness set=%d effective=%u", v, runtimeState().brightness);
        } else {
            sout("OK led brightness value=%u min=%u max=%u", runtimeState().brightness,
                 MIN_BRIGHTNESS, MAX_BRIGHTNESS);
        }
        return;
    }
    if (strcasecmp(argv[1], "current") == 0) {
        const FrameStateSnapshot f = readFrameStateSnapshot();
        sout("OK led current color=%s brightness=%u lit=%u", f.colorHex, f.brightness, f.litLeds);
        return;
    }
    if (strcasecmp(argv[1], "dump") == 0) {
        cmdLedDump(argc >= 3 && strcasecmp(argv[2], "compact") == 0);
        return;
    }
    if (strcasecmp(argv[1], "clear") == 0) {
        stopFirmwareScroll(false, true);
        applyBlankFrameImmediate("serial_led_clear");
        sout("OK led clear");
        return;
    }
    if (strcasecmp(argv[1], "test") == 0 && argc >= 3 && strcasecmp(argv[2], "pattern") == 0) {
        cmdLedTestPattern(argc, argv);
        return;
    }
    if (strcasecmp(argv[1], "command_history") == 0) { cmdLedCommandHistory(); return; }
    sout("ERR led unknown_subcmd=%s", argv[1]);
}

// =============================================================================
//  ADC / battery commands  (read-only; never disturb the sampling cadence)
// =============================================================================
void printPower(const PowerStatus& p, const char* tag) {
    sout("%s vbat=%.3f vcharge=%.3f percent=%u charging=%d batValid=%d chargeValid=%d",
         tag, p.vbat, p.vcharge, p.batteryPercent, p.charging ? 1 : 0,
         p.batteryValid ? 1 : 0, p.chargeValid ? 1 : 0);
    sout("%s vbatRaw=%u vchargeRaw=%u calibMin=%.3f calibMax=%.3f disconnected=%d",
         tag, p.batteryAdcMv, p.chargeAdcMv, p.batteryCalibMinV, p.batteryCalibMaxV,
         p.batteryDisconnected ? 1 : 0);
}

void cmdAdc(int argc, char** argv) {
    const PowerStatus p = readPowerStatusSnapshot();
    if (argc >= 3 && strcasecmp(argv[1], "read") == 0) {
        if (strcasecmp(argv[2], "raw") == 0) {
            sout("OK adc read raw vbatRaw=%u vchargeRaw=%u", p.batteryAdcMv, p.chargeAdcMv);
            return;
        }
        if (strcasecmp(argv[2], "vbat") == 0) {
            sout("OK adc read vbat vbat=%.3f raw=%u percent=%u", p.vbat, p.batteryAdcMv, p.batteryPercent);
            return;
        }
        if (strcasecmp(argv[2], "charge") == 0) {
            sout("OK adc read charge vcharge=%.3f raw=%u charging=%d", p.vcharge, p.chargeAdcMv, p.charging ? 1 : 0);
            return;
        }
        sout("ERR adc read unknown=%s", argv[2]);
        return;
    }
    // `adc status` / `adc read`
    sout("=== ADC BEGIN ===");
    printPower(p, "ADC");
    sout("=== ADC END ===");
}

void cmdBattery(int argc, char** argv) {
    if (argc >= 2 && strcasecmp(argv[1], "sample") == 0) {
        uint16_t n = (argc >= 3) ? static_cast<uint16_t>(strtoul(argv[2], nullptr, 10)) : 1;
        if (n == 0) n = 1;
        if (n > 50) n = 50;  // bounded: explicit test command, still no long block
        sout("=== BATTERY SAMPLE BEGIN ===");
        for (uint16_t i = 0; i < n; ++i) {
            servicePowerMonitor(true);
            const PowerStatus p = readPowerStatusSnapshot();
            sout("SAMPLE %u vbat=%.3f percent=%u vcharge=%.3f charging=%d",
                 i, p.vbat, p.batteryPercent, p.vcharge, p.charging ? 1 : 0);
        }
        sout("=== BATTERY SAMPLE END ===");
        return;
    }
    // battery reset min|max -- mirrors WebUI reset_battery_min / reset_battery_max.
    if (argc >= 3 && strcasecmp(argv[1], "reset") == 0) {
        if (strcasecmp(argv[2], "min") == 0)      { resetBatteryVoltageMinimum(); sout("OK battery reset min"); }
        else if (strcasecmp(argv[2], "max") == 0) { resetBatteryVoltageMaximum(); sout("OK battery reset max"); }
        else sout("ERR battery reset usage='battery reset min|max'");
        return;
    }
    // battery overlay [single|hold] -- mirrors WebUI battery_overlay (B6 display).
    if (argc >= 2 && strcasecmp(argv[1], "overlay") == 0) {
        const bool singleShot = !(argc >= 3 && strcasecmp(argv[2], "hold") == 0);
        showBatteryOverlay(singleShot);
        sout("OK battery overlay singleShot=%d", singleShot ? 1 : 0);
        return;
    }
    // `battery status`
    const PowerStatus p = readPowerStatusSnapshot();
    sout("=== BATTERY BEGIN ===");
    printPower(p, "BATTERY");
    sout("=== BATTERY END ===");
}

// =============================================================================
//  Mode / face / auto commands  (reuse the WebUI/button internal functions)
// =============================================================================
void cmdMode(int argc, char** argv) {
    if (argc < 2 || strcasecmp(argv[1], "status") == 0) {
        sout("OK mode status mode=%s playback=%s autoIntervalMs=%lu",
             runtimeState().mode.c_str(), runtimeState().playback.c_str(),
             static_cast<unsigned long>(runtimeState().autoIntervalMs));
        return;
    }
    if (strcasecmp(argv[1], "manual") == 0) { setMode("manual", true); sout("OK mode manual"); return; }
    if (strcasecmp(argv[1], "auto") == 0)   { setMode("auto", true);   sout("OK mode auto");   return; }
    sout("ERR mode unknown_subcmd=%s", argv[1]);
}

void cmdFace(int argc, char** argv) {
    if (argc < 2 || strcasecmp(argv[1], "status") == 0) {
        const uint16_t idx = runtimeState().autoFaceIndex;
        const char* id = (runtimeAutoFaceCount() > 0 && idx < runtimeAutoFaceCount())
                             ? runtimeAutoFaces()[idx].id.c_str() : "";
        sout("OK face status index=%u count=%u id=%s", idx, runtimeAutoFaceCount(), id);
        return;
    }
    if (strcasecmp(argv[1], "next") == 0) {
        if (applyRelativeSavedFace(1, "serial_face_next")) sout("OK face next index=%u", runtimeState().autoFaceIndex);
        else sout("ERR face next no_saved_faces");
        return;
    }
    if (strcasecmp(argv[1], "prev") == 0) {
        if (applyRelativeSavedFace(-1, "serial_face_prev")) sout("OK face prev index=%u", runtimeState().autoFaceIndex);
        else sout("ERR face prev no_saved_faces");
        return;
    }
    if (strcasecmp(argv[1], "apply") == 0 && argc >= 3) {
        const uint16_t idx = static_cast<uint16_t>(strtoul(argv[2], nullptr, 10));
        const bool ok = applySavedFaceIndex(idx, "serial_face_apply", DEFAULT_PLAYBACK);
        if (ok) sout("OK face apply index=%u", runtimeState().autoFaceIndex);
        else    sout("ERR face apply failed index=%u count=%u", idx, runtimeAutoFaceCount());
        return;
    }
    sout("ERR face usage='face <status|next|prev|apply N>'");
}

void cmdAuto(int argc, char** argv) {
    if (argc < 2 || strcasecmp(argv[1], "status") == 0) {
        sout("OK auto status mode=%s intervalMs=%lu faceIndex=%u",
             runtimeState().mode.c_str(),
             static_cast<unsigned long>(runtimeState().autoIntervalMs),
             static_cast<unsigned>(runtimeState().autoFaceIndex));
        return;
    }
    if (strcasecmp(argv[1], "interval") == 0) {
        if (argc >= 3) {
            setAutoInterval(strtoul(argv[2], nullptr, 10));
            sout("OK auto interval set=%lu effective=%lu",
                 strtoul(argv[2], nullptr, 10),
                 static_cast<unsigned long>(runtimeState().autoIntervalMs));
        } else {
            sout("OK auto interval value=%lu min=%lu max=%lu",
                 static_cast<unsigned long>(runtimeState().autoIntervalMs),
                 static_cast<unsigned long>(MIN_AUTO_INTERVAL_MS),
                 static_cast<unsigned long>(MAX_AUTO_INTERVAL_MS));
        }
        return;
    }
    if (strcasecmp(argv[1], "start") == 0) { setMode("auto", true);   sout("OK auto start"); return; }
    if (strcasecmp(argv[1], "stop") == 0)  { setMode("manual", true); sout("OK auto stop");  return; }
    sout("ERR auto usage='auto <status|interval [N]|start|stop>'");
}

// =============================================================================
//  Scroll commands  (reuse existing scroll-session logic)
// =============================================================================
void cmdScroll(int argc, char** argv) {
    if (argc < 2 || strcasecmp(argv[1], "status") == 0) {
        const ScrollSessionSnapshot sc = scrollSessionSnapshot();
        sout("OK scroll status active=%d paused=%d userPaused=%d systemPaused=%d idx=%u count=%u interval=%u uploadComplete=%d hasText=%d",
             sc.firmwareScrollActive ? 1 : 0, sc.firmwareScrollPaused ? 1 : 0,
             sc.firmwareScrollUserPaused ? 1 : 0, sc.firmwareScrollSystemPaused ? 1 : 0,
             static_cast<unsigned>(sc.scrollFrameIndex), static_cast<unsigned>(sc.scrollFrameCount),
             static_cast<unsigned>(sc.scrollIntervalMs),
             sc.scrollUploadComplete ? 1 : 0, sc.scrollHasSourceText ? 1 : 0);
        return;
    }
    // scroll start [ms] -- mirrors WebUI start_scroll (plays the cached frames).
    if (strcasecmp(argv[1], "start") == 0) {
        uint16_t iMs = runtimeState().scrollIntervalMs;
        if (argc >= 3) iMs = static_cast<uint16_t>(strtoul(argv[2], nullptr, 10));
        startFirmwareScroll(iMs);
        const ScrollSessionSnapshot s = scrollSessionSnapshot();
        if (s.firmwareScrollActive) sout("OK scroll start interval=%u count=%u",
                                         static_cast<unsigned>(s.scrollIntervalMs),
                                         static_cast<unsigned>(s.scrollFrameCount));
        else sout("WARN scroll start reason=no_scroll_frames");
        return;
    }
    // scroll interval <ms> / scroll fps <n> -- mirrors WebUI set_scroll_interval.
    if (strcasecmp(argv[1], "interval") == 0 && argc >= 3) {
        scrollSessionSetInterval(static_cast<uint16_t>(strtoul(argv[2], nullptr, 10)));
        sout("OK scroll interval set=%s effective=%u min=%u max=%u", argv[2],
             static_cast<unsigned>(runtimeState().scrollIntervalMs),
             MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        return;
    }
    if (strcasecmp(argv[1], "fps") == 0 && argc >= 3) {
        const double fps = atof(argv[2]);
        uint16_t ms = runtimeState().scrollIntervalMs;
        if (fps > 0) ms = static_cast<uint16_t>(constrain(1000.0 / fps,
                          (double)MIN_SCROLL_INTERVAL_MS, (double)MAX_SCROLL_INTERVAL_MS));
        scrollSessionSetInterval(ms);
        sout("OK scroll fps set=%s interval=%u", argv[2],
             static_cast<unsigned>(runtimeState().scrollIntervalMs));
        return;
    }
    if (strcasecmp(argv[1], "pause") == 0)  { const bool c = scrollSessionSetUserPaused(true);  sout("OK scroll pause changed=%d", c ? 1 : 0);  return; }
    if (strcasecmp(argv[1], "resume") == 0) { const bool c = scrollSessionSetUserPaused(false); sout("OK scroll resume changed=%d", c ? 1 : 0); return; }
    if (strcasecmp(argv[1], "stop") == 0) {
        stopFirmwareScroll(scrollSessionGetRestoreAuto(), true);
        sout("OK scroll stop");
        return;
    }
    if (strcasecmp(argv[1], "clear") == 0) {
        stopFirmwareScroll(false, true);
        scrollSessionClearTimeline();
        sout("OK scroll clear");
        return;
    }
    if (strcasecmp(argv[1], "step") == 0 && argc >= 3) {
        const int8_t dir = (strcasecmp(argv[2], "prev") == 0) ? -1 : 1;
        uint8_t f[FRAME_BYTES];
        if (scrollSessionStep(dir, f)) {
            applyPackedFrameImmediate(f, "serial_scroll_step");
            sout("OK scroll step dir=%s idx=%u", dir < 0 ? "prev" : "next",
                 static_cast<unsigned>(runtimeState().scrollFrameIndex));
        } else {
            sout("WARN scroll step reason=no_scroll_frames");
        }
        return;
    }
    sout("ERR scroll usage='scroll <status|start [ms]|interval ms|fps n|pause|resume|stop|clear|step next|prev>'");
}

// pause -- mirrors WebUI global `pause`: pauses an active scroll, else halts auto
// playback (paused=1). Hardware: stops face/scroll advancement until `resume`.
void cmdPause(int, char**) {
    const bool pausedScroll = scrollSessionSetUserPaused(true);
    if (!pausedScroll) {
        runtimeState().paused   = true;
        runtimeState().playback = "paused";
        touchRuntimeState();
    }
    sout("OK pause scrollPaused=%d paused=%d", pausedScroll ? 1 : 0, runtimeState().paused ? 1 : 0);
}

// resume -- mirrors WebUI global `resume`.
void cmdResume(int, char**) {
    bool resumedScroll = false;
    // Resume a paused-with-frames scroll; otherwise clear the global pause.
    if (scrollSessionSnapshot().firmwareScrollPaused) resumedScroll = scrollSessionSetUserPaused(false);
    if (!resumedScroll) {
        runtimeState().paused   = false;
        runtimeState().playback = DEFAULT_PLAYBACK;
        touchRuntimeState();
    }
    sout("OK resume scrollResumed=%d paused=%d", resumedScroll ? 1 : 0, runtimeState().paused ? 1 : 0);
}

// frame <M370[:hex]> -- mirrors WebUI POST /api/frame: push one arbitrary frame
// through the real apply path. Hardware: replaces the current display frame.
void cmdFrame(int argc, char** argv) {
    if (argc < 2) { sout("ERR frame usage='frame <M370:hex | 93-hex>'"); return; }
    stopFirmwareScroll(false, true);
    String err;
    if (applyM370(argv[1], "serial_frame", err)) {
        sout("OK frame accepted lit=%u", countLitLeds());
    } else {
        sout("ERR frame %s", err.c_str());
    }
}

// terminate [scroll|face|all] -- mirrors WebUI terminate_other_activities: stop
// competing activities before switching to a target mode.
void cmdTerminate(int argc, char** argv) {
    const char* target = (argc >= 2) ? argv[1] : "all";
    if (strcasecmp(target, "scroll") != 0) stopFirmwareScroll(false, true);
    if (strcasecmp(target, "face") != 0 && strcasecmp(target, "scroll") != 0) {
        setMode("manual", true);
    } else if (strcasecmp(target, "scroll") == 0 && isAutoMode()) {
        scrollSessionSetRestoreAuto(true);
        runtimeState().mode = "manual";
        touchRuntimeState();
    }
    sout("OK terminate target=%s mode=%s", target, runtimeState().mode.c_str());
}

// =============================================================================
//  Built-in self-test runner
// =============================================================================
#if ENABLE_FIRMWARE_TESTS

int sTestPass = 0, sTestWarn = 0, sTestFail = 0;

void tPass(const char* name, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void tPass(const char* name, const char* fmt, ...) {
    char extra[120]; va_list a; va_start(a, fmt); vsnprintf(extra, sizeof(extra), fmt, a); va_end(a);
    ++sTestPass; sout("[TEST] %s PASS %s", name, extra);
}
void tWarn(const char* name, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void tWarn(const char* name, const char* fmt, ...) {
    char extra[120]; va_list a; va_start(a, fmt); vsnprintf(extra, sizeof(extra), fmt, a); va_end(a);
    ++sTestWarn; sout("[TEST] %s WARN %s", name, extra);
}
void tFail(const char* name, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void tFail(const char* name, const char* fmt, ...) {
    char extra[120]; va_list a; va_start(a, fmt); vsnprintf(extra, sizeof(extra), fmt, a); va_end(a);
    ++sTestFail; sout("[TEST] %s FAIL %s", name, extra);
}

// Pump the REAL hardware-button state machine for ~ms of wall time so an
// emulated-overlay press flows through the identical debounce/combo/repeat path
// the live loop() drives. Used only by the on-demand button self-tests; it is
// the bridge that lets us assert "serial overlay == physical GPIO".
void pumpHardwareButtons(uint32_t ms) {
    const uint32_t start = millis();
    do {
        serviceHardwareButtons();
        delay(2);
    } while (millis() - start < ms);
    serviceHardwareButtons();
}

// Force-clear every emulated overlay and settle, so a test never leaves a
// button latched down for the live loop.
void clearAllEmulatedButtons() {
    static const char* CODES[] = {"B1", "B2", "B3", "B4", "B5", "B6"};
    for (const char* c : CODES) emulateButtonRawSet(c, false);
    pumpHardwareButtons(BUTTON_DEBOUNCE_MS + 20);
}

void testButtons() {
    if (runtimeAutoFaceCount() == 0) { tWarn("buttons.tap_b1", "reason=no_saved_faces"); return; }
    const uint16_t count = runtimeAutoFaceCount();
    // Debounce settle margin used by every overlay-driven case below.
    const uint32_t SETTLE = BUTTON_DEBOUNCE_MS + 20;

    uint16_t before = runtimeState().autoFaceIndex;
    runButtonAction("B1", "serial");
    uint16_t after = runtimeState().autoFaceIndex;
    if (after == (before + 1) % count) tPass("buttons.tap_b1", "before=%u after=%u", before, after);
    else tFail("buttons.tap_b1", "before=%u after=%u expected=%u", before, after, (before + 1) % count);

    before = runtimeState().autoFaceIndex;
    runButtonAction("B2", "serial");
    after = runtimeState().autoFaceIndex;
    if (after == (before + count - 1) % count) tPass("buttons.tap_b2", "before=%u after=%u", before, after);
    else tFail("buttons.tap_b2", "before=%u after=%u expected=%u", before, after, (before + count - 1) % count);

    const String modeBefore = runtimeState().mode;
    runButtonAction("B3", "serial");
    if (runtimeState().mode != modeBefore) tPass("buttons.b3_toggle", "from=%s to=%s", modeBefore.c_str(), runtimeState().mode.c_str());
    else tFail("buttons.b3_toggle", "stuck=%s", modeBefore.c_str());
    runButtonAction("B3", "serial");  // toggle back

    const uint8_t brBefore = runtimeState().brightness;
    setBrightness(MIN_BRIGHTNESS);
    runButtonAction("B4", "serial");
    const uint8_t lo = runtimeState().brightness;
    setBrightness(MAX_BRIGHTNESS);
    runButtonAction("B5", "serial");
    const uint8_t hi = runtimeState().brightness;
    if (lo >= MIN_BRIGHTNESS && hi <= MAX_BRIGHTNESS) tPass("buttons.brightness_limit", "min=%u max=%u", lo, hi);
    else tFail("buttons.brightness_limit", "min=%u max=%u", lo, hi);
    setBrightness(brBefore);

    const uint32_t ivBefore = runtimeState().autoIntervalMs;
    runButtonAction("B3B1", "serial");
    runButtonAction("B3B2", "serial");
    const uint32_t ivAfter = runtimeState().autoIntervalMs;
    if (ivAfter >= MIN_AUTO_INTERVAL_MS && ivAfter <= MAX_AUTO_INTERVAL_MS)
        tPass("buttons.auto_interval", "min=%lu max=%lu now=%lu",
              (unsigned long)MIN_AUTO_INTERVAL_MS, (unsigned long)MAX_AUTO_INTERVAL_MS, (unsigned long)ivAfter);
    else tFail("buttons.auto_interval", "out_of_bounds=%lu", (unsigned long)ivAfter);
    setAutoInterval(ivBefore);

    // -------------------------------------------------------------------------
    // Overlay-driven tests: these drive the EMULATED serial overlay through the
    // real serviceHardwareButtons() debounce/combo machine (via the serial path
    // the `btn` command uses), proving serial emulation behaves like physical
    // GPIO and exercising combinations that are NOT in the firmware.
    // -------------------------------------------------------------------------
    clearAllEmulatedButtons();
    const uint32_t midIv = (MIN_AUTO_INTERVAL_MS + MAX_AUTO_INTERVAL_MS) / 2;

    // (1) serial==gpio: a single emulated B1 press/release must advance the
    // saved face by exactly one, identical to the logical tap above.
    {
        const uint16_t b = runtimeState().autoFaceIndex;
        emulateButtonRawSet("B1", true);
        pumpHardwareButtons(SETTLE);          // debounce + press latch -> next-face
        emulateButtonRawSet("B1", false);
        pumpHardwareButtons(SETTLE);          // release
        const uint16_t a = runtimeState().autoFaceIndex;
        if (a == (b + 1) % count) tPass("buttons.serial_overlay_b1", "before=%u after=%u", b, a);
        else tFail("buttons.serial_overlay_b1", "before=%u after=%u expected=%u", b, a, (b + 1) % count);
    }

    // (2) Sequenced combo B3 (held) THEN B1 -> real B3B1 auto-interval-down.
    {
        setAutoInterval(midIv);
        const uint32_t iv0 = runtimeState().autoIntervalMs;
        emulateButtonRawSet("B3", true);
        pumpHardwareButtons(SETTLE);          // B3 latches pressed (acts on release)
        emulateButtonRawSet("B1", true);
        pumpHardwareButtons(SETTLE);          // B1 latches WHILE B3 held -> combo
        emulateButtonRawSet("B1", false);
        emulateButtonRawSet("B3", false);
        pumpHardwareButtons(SETTLE);          // release both (B3 combo-consumed)
        const uint32_t iv1 = runtimeState().autoIntervalMs;
        const uint32_t expect = (iv0 > AUTO_INTERVAL_BUTTON_STEP_MS)
                                ? iv0 - AUTO_INTERVAL_BUTTON_STEP_MS : MIN_AUTO_INTERVAL_MS;
        if (iv1 == expect) tPass("buttons.combo_b3b1_seq", "iv0=%lu iv1=%lu", (unsigned long)iv0, (unsigned long)iv1);
        else tFail("buttons.combo_b3b1_seq", "iv0=%lu iv1=%lu expected=%lu",
                   (unsigned long)iv0, (unsigned long)iv1, (unsigned long)expect);
    }

    // (3) Sequenced combo B3 (held) THEN B2 -> real B3B2 auto-interval-up.
    {
        setAutoInterval(midIv);
        const uint32_t iv0 = runtimeState().autoIntervalMs;
        emulateButtonRawSet("B3", true);
        pumpHardwareButtons(SETTLE);
        emulateButtonRawSet("B2", true);
        pumpHardwareButtons(SETTLE);
        emulateButtonRawSet("B2", false);
        emulateButtonRawSet("B3", false);
        pumpHardwareButtons(SETTLE);
        const uint32_t iv1 = runtimeState().autoIntervalMs;
        const uint32_t expect = iv0 + AUTO_INTERVAL_BUTTON_STEP_MS > MAX_AUTO_INTERVAL_MS
                                ? MAX_AUTO_INTERVAL_MS : iv0 + AUTO_INTERVAL_BUTTON_STEP_MS;
        if (iv1 == expect) tPass("buttons.combo_b3b2_seq", "iv0=%lu iv1=%lu", (unsigned long)iv0, (unsigned long)iv1);
        else tFail("buttons.combo_b3b2_seq", "iv0=%lu iv1=%lu expected=%lu",
                   (unsigned long)iv0, (unsigned long)iv1, (unsigned long)expect);
    }

    // (4) NOT in the code: a TRUE simultaneous B3+B1 (both asserted in the same
    // debounce cycle). The firmware services B1 before B3 in fixed array order,
    // so B1's press is handled while B3 is not yet 'pressed' -> NO B3B1 combo
    // forms; you get a plain next-face instead. This proves simultaneous press
    // differs from the sequenced combo, and that no phantom combo is invented.
    {
        setAutoInterval(midIv);
        const uint32_t iv0 = runtimeState().autoIntervalMs;
        const uint16_t f0  = runtimeState().autoFaceIndex;
        const String   m0  = runtimeState().mode;
        emulateButtonRawSet("B3", true);
        emulateButtonRawSet("B1", true);      // both at once
        pumpHardwareButtons(SETTLE);
        emulateButtonRawSet("B1", false);
        emulateButtonRawSet("B3", false);
        pumpHardwareButtons(SETTLE);
        const uint32_t iv1 = runtimeState().autoIntervalMs;
        const uint16_t f1  = runtimeState().autoFaceIndex;
        const bool noCombo   = (iv1 == iv0);
        const bool faceMoved = (f1 == (f0 + 1) % count);
        if (noCombo && faceMoved)
            tPass("buttons.combo_simultaneous_b3b1", "no_combo iv=%lu face=%u->%u (B1 wins, expected)",
                  (unsigned long)iv1, f0, f1);
        else
            tFail("buttons.combo_simultaneous_b3b1", "iv0=%lu iv1=%lu face=%u->%u",
                  (unsigned long)iv0, (unsigned long)iv1, f0, f1);
        // Simultaneous B3 released without combo-consume toggles mode; restore.
        if (runtimeState().mode != m0) setMode(m0.c_str(), false);
    }

    // (5) NOT a combo: B4+B5 pressed together. Each fires its own action once
    // (down then up, netting no change) and must NEVER touch auto-interval or
    // escape the brightness clamp -- i.e. an undefined pair degrades safely.
    {
        const uint32_t iv0 = runtimeState().autoIntervalMs;
        setBrightness((MIN_BRIGHTNESS + MAX_BRIGHTNESS) / 2);
        const uint8_t br0 = runtimeState().brightness;
        emulateButtonRawSet("B4", true);
        emulateButtonRawSet("B5", true);
        pumpHardwareButtons(SETTLE);
        emulateButtonRawSet("B4", false);
        emulateButtonRawSet("B5", false);
        pumpHardwareButtons(SETTLE);
        const uint8_t  br1 = runtimeState().brightness;
        const uint32_t iv1 = runtimeState().autoIntervalMs;
        const bool inRange = (br1 >= MIN_BRIGHTNESS && br1 <= MAX_BRIGHTNESS);
        const bool ivSafe  = (iv1 == iv0);
        if (inRange && ivSafe && br1 == br0)
            tPass("buttons.noncombo_b4b5", "br=%u->%u iv_unchanged=%lu", br0, br1, (unsigned long)iv1);
        else
            tFail("buttons.noncombo_b4b5", "br=%u->%u iv0=%lu iv1=%lu",
                  br0, br1, (unsigned long)iv0, (unsigned long)iv1);
    }

    clearAllEmulatedButtons();
    setAutoInterval(ivBefore);
}

void testLed() {
    uint8_t blank[FRAME_BYTES] = {0};
    applyPackedFrameImmediate(blank, "serial_test_led_clear");
    if (countLitLeds() == 0) tPass("led.clear", "lit=0");
    else tFail("led.clear", "lit=%u", countLitLeds());

    uint8_t all[FRAME_BYTES];
    memset(all, 0, sizeof(all));
    for (uint16_t i = 0; i < LED_COUNT; ++i) setPackedBit(all, i);
    applyPackedFrameImmediate(all, "serial_test_all_on");
    if (countLitLeds() == LED_COUNT) tPass("led.pattern_all_on", "lit=%u", countLitLeds());
    else tFail("led.pattern_all_on", "lit=%u expected=%u", countLitLeds(), LED_COUNT);

    uint8_t one[FRAME_BYTES] = {0};
    setPackedBit(one, 0);
    applyPackedFrameImmediate(one, "serial_test_single");
    if (countLitLeds() == 1) tPass("led.pattern_single", "lit=1");
    else tFail("led.pattern_single", "lit=%u expected=1", countLitLeds());
}

void testAdc() {
    const PowerStatus p = readPowerStatusSnapshot();
    if (!p.batteryValid) { tWarn("adc.read", "reason=battery_invalid"); return; }
    if (p.batteryPercent <= 100) tPass("adc.read", "vbat=%.2f percent=%u", p.vbat, p.batteryPercent);
    else tFail("adc.read", "percent_out_of_range=%u", p.batteryPercent);
}

void testModes() {
    const String before = runtimeState().mode;
    setMode("auto", false);
    const bool a = isAutoMode();
    setMode("manual", false);
    const bool m = !isAutoMode();
    if (a && m) tPass("modes.toggle", "auto_ok=1 manual_ok=1");
    else tFail("modes.toggle", "auto_ok=%d manual_ok=%d", a ? 1 : 0, m ? 1 : 0);
    setMode(before.c_str(), false);
}

void testScroll() {
    const ScrollSessionSnapshot sc = scrollSessionSnapshot();
    if (sc.scrollFrameCount == 0) { tWarn("scroll.step_no_data", "reason=no_scroll_frames"); return; }
    scrollSessionSetUserPaused(true);
    const bool paused = scrollSessionSnapshot().firmwareScrollPaused;
    uint8_t f[FRAME_BYTES];
    const bool stepped = scrollSessionStep(1, f);
    scrollSessionSetUserPaused(false);
    if (paused && stepped) tPass("scroll.pause_step", "paused=1 stepped=1");
    else tFail("scroll.pause_step", "paused=%d stepped=%d", paused ? 1 : 0, stepped ? 1 : 0);
}

// Exhaustive option-space sweeps. Each sweep emits ONE summary line (not one
// per value) so output stays parseable. These exercise the FULL reachable range
// of each WebUI option: every brightness step, the web-safe color grid plus
// boundaries, and every scroll-interval value, including clamp behavior. They do
// NOT light all LEDs, so they respect the brightness guardrail.
void testSweeps() {
    // --- brightness: every value MIN..MAX, plus out-of-range clamp ---
    int bFirstBad = -1;
    for (int n = MIN_BRIGHTNESS; n <= MAX_BRIGHTNESS; ++n) {
        setBrightness(n);
        if (runtimeState().brightness != n) { bFirstBad = n; break; }
    }
    setBrightness(0);   const bool bLo = runtimeState().brightness == MIN_BRIGHTNESS;
    setBrightness(255); const bool bHi = runtimeState().brightness == MAX_BRIGHTNESS;
    if (bFirstBad < 0 && bLo && bHi)
        tPass("sweep.brightness", "count=%d range=%u..%u clamp=ok",
              MAX_BRIGHTNESS - MIN_BRIGHTNESS + 1, MIN_BRIGHTNESS, MAX_BRIGHTNESS);
    else
        tFail("sweep.brightness", "firstBad=%d loClamp=%d hiClamp=%d", bFirstBad, bLo ? 1 : 0, bHi ? 1 : 0);

    // --- color: 6x6x6 web-safe grid + boundary colors ---
    static const uint8_t LV[6] = {0x00, 0x33, 0x66, 0x99, 0xcc, 0xff};
    int cFail = 0, cTot = 0; char hex[8]; String err;
    for (int i = 0; i < 6; ++i)
        for (int j = 0; j < 6; ++j)
            for (int k = 0; k < 6; ++k) {
                snprintf(hex, sizeof hex, "#%02x%02x%02x", LV[i], LV[j], LV[k]);
                ++cTot;
                if (!setColor(hex, err) || !(runtimeState().colorHex == hex)) ++cFail;
            }
    static const char* BOUND[] = {"#000000", "#ffffff", "#ff0000", "#00ff00", "#0000ff", "#f971d4"};
    for (const char* b : BOUND) { ++cTot; if (!setColor(b, err) || !(runtimeState().colorHex == b)) ++cFail; }
    if (cFail == 0) tPass("sweep.color", "count=%d websafe+boundaries", cTot);
    else            tFail("sweep.color", "fail=%d/%d", cFail, cTot);

    // --- scroll interval: every value MIN..MAX + clamp ---
    int iFail = 0;
    for (uint32_t ms = MIN_SCROLL_INTERVAL_MS; ms <= MAX_SCROLL_INTERVAL_MS; ++ms) {
        scrollSessionSetInterval(static_cast<uint16_t>(ms));
        if (runtimeState().scrollIntervalMs != ms) ++iFail;
    }
    scrollSessionSetInterval(1);     const bool iLo = runtimeState().scrollIntervalMs == MIN_SCROLL_INTERVAL_MS;
    scrollSessionSetInterval(60000); const bool iHi = runtimeState().scrollIntervalMs == MAX_SCROLL_INTERVAL_MS;
    if (iFail == 0 && iLo && iHi)
        tPass("sweep.scroll_interval", "range=%u..%u clamp=ok", MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
    else
        tFail("sweep.scroll_interval", "fail=%d loClamp=%d hiClamp=%d", iFail, iLo ? 1 : 0, iHi ? 1 : 0);
}

// Snapshot/restore wrapper so the runner never leaves the board in a test state.
void runTests(const char* group) {
    sTestPass = sTestWarn = sTestFail = 0;

    const String   mode0   = runtimeState().mode;
    const uint8_t  bright0 = runtimeState().brightness;
    const uint32_t iv0     = runtimeState().autoIntervalMs;
    const uint16_t face0   = runtimeState().autoFaceIndex;
    const String   color0  = runtimeState().colorHex;
    const uint16_t scrIv0  = runtimeState().scrollIntervalMs;
    const bool     all     = (group == nullptr) || strcasecmp(group, "all") == 0;

    if (all || strcasecmp(group, "buttons") == 0) testButtons();
    if (all || strcasecmp(group, "led") == 0)     testLed();
    if (all || strcasecmp(group, "adc") == 0)     testAdc();
    if (all || strcasecmp(group, "modes") == 0)   testModes();
    if (all || strcasecmp(group, "scroll") == 0)  testScroll();
    // Sweeps are exhaustive/long, so run them only on explicit request.
    if (group != nullptr && strcasecmp(group, "sweep") == 0) testSweeps();

    // Restore prior state (best effort, non-destructive).
    setAutoInterval(iv0, false);
    setMode(mode0.c_str(), false);
    setBrightness(bright0);
    scrollSessionSetInterval(scrIv0);
    { String e; setColor(color0.c_str(), e); }
    if (runtimeAutoFaceCount() > 0) applySavedFaceIndex(face0, "serial_test_restore", DEFAULT_PLAYBACK);

    sout("[TEST] SUMMARY pass=%d warn=%d fail=%d", sTestPass, sTestWarn, sTestFail);
}

void cmdTest(int argc, char** argv) {
    if (argc >= 2 && strcasecmp(argv[1], "list") == 0) {
        sout("OK test groups=all,buttons,led,adc,modes,scroll,sweep");
        sout("OK test tests=buttons.tap_b1,buttons.tap_b2,buttons.b3_toggle,buttons.brightness_limit,buttons.auto_interval");
        sout("OK test tests=buttons.serial_overlay_b1,buttons.combo_b3b1_seq,buttons.combo_b3b2_seq,buttons.combo_simultaneous_b3b1,buttons.noncombo_b4b5");
        sout("OK test tests=led.clear,led.pattern_all_on,led.pattern_single,adc.read,modes.toggle,scroll.pause_step");
        sout("OK test tests=sweep.brightness,sweep.color,sweep.scroll_interval (run via 'test run sweep')");
        return;
    }
    if (argc >= 2 && strcasecmp(argv[1], "report") == 0) {
        sout("OK test report pass=%d warn=%d fail=%d", sTestPass, sTestWarn, sTestFail);
        return;
    }
    if (argc >= 2 && strcasecmp(argv[1], "run") == 0) {
        runTests(argc >= 3 ? argv[2] : "all");
        return;
    }
    sout("ERR test usage='test <list|run all|run buttons|run led|run adc|run modes|run scroll|report>'");
}

#else  // ENABLE_FIRMWARE_TESTS == 0
void cmdTest(int, char**) { sout("ERR test disabled (compile with ENABLE_FIRMWARE_TESTS=1)"); }
#endif  // ENABLE_FIRMWARE_TESTS

// =============================================================================
//  Help text
// =============================================================================
void printHelpAll() {
    sout("=== HELP BEGIN ===");
    sout("help [buttons|led|adc|logs|tests]  # this list / topic help");
    sout("status                             # full runtime snapshot");
    sout("version                            # firmware id + feature gates");
    sout("uptime                             # ms since boot");
    sout("log level <ERROR|WARN|INFO|DEBUG|TRACE> | log on|off | log status");
    sout("btn <press|release|tap|hold|repeat> <B1..B6> [args]  (see 'help buttons')");
    sout("btn multi <ID+ID+..> <ms>  # press several buttons at once (real machine)");
    sout("btn combo <B3+B1|B3+B2> <tap|hold ms> | btn status");
    sout("led <status|color #RRGGBB|brightness [N]|current|dump [compact]|clear|command_history>");
    sout("led test pattern <checker|rows|cols|all_on|all_off|single N>");
    sout("adc <status|read [raw|vbat|charge]>");
    sout("battery <status|sample N|reset min|max|overlay [single|hold]>");
    sout("mode <status|manual|auto> | face <status|next|prev|apply N>");
    sout("auto <status|interval [N]|start|stop>");
    sout("scroll <status|start [ms]|interval ms|fps n|pause|resume|stop|clear|step next|prev>");
    sout("pause | resume | frame <M370> | terminate [scroll|face|all]");
    sout("test <list|run all|run GROUP|run sweep|report>");
    sout("=== HELP END ===");
}
void printHelpButtons() {
    sout("=== HELP BUTTONS BEGIN ===");
    sout("B1=next face/stop scroll  B2=prev face/stop scroll  B3=Manual/Auto toggle (on release)");
    sout("B4=brightness down  B5=brightness up  B6=battery display");
    sout("btn press B1     # engage emulated hold (flows through real debounce)");
    sout("btn release B1   # release emulated hold");
    sout("btn tap B1       # immediate logical action, logs source=serial");
    sout("btn hold B1 1000 # hold 1000ms, auto-release (produces real repeats)");
    sout("btn repeat B1 5 350  # fire 5 times, 350ms apart");
    sout("btn multi B3+B1 800  # press B3 AND B1 at once for 800ms (true combo)");
    sout("btn multi B4+B5 0    # momentary simultaneous press (two buttons at once)");
    sout("  # multi = parameters [buttons joined by '+'] [press-time ms]; flows");
    sout("  # through the identical debounce/combo/repeat path as physical GPIO.");
    sout("btn combo B3+B1 tap | btn combo B3+B1 hold 1000  # legacy logical combo shortcut");
    sout("btn status       # physical + emulated pressed state per button");
    sout("=== HELP BUTTONS END ===");
}
void printHelpLed() {
    sout("=== HELP LED BEGIN ===");
    sout("led status        # mode, brightness, face, scroll, pending frame");
    sout("led color #RRGGBB # set global color (full 24-bit; mirrors set_color)");
    sout("led brightness    # show; led brightness 127 # set (clamped 10..200)");
    sout("led current       # current color/brightness/lit count");
    sout("led dump          # ASCII 18-row matrix + 93-hex frame");
    sout("led dump compact  # M370:<hex> one-liner for copy/paste into tests");
    sout("led clear         # blank the frame (applyBlankFrame)");
    sout("led test pattern checker|rows|cols|all_on|all_off|single <0..369>");
    sout("led command_history  # recent LED apply ring buffer");
    sout("=== HELP LED END ===");
}
void printHelpAdc() {
    sout("=== HELP ADC BEGIN ===");
    sout("adc status            # full power snapshot block");
    sout("adc read             # same as status");
    sout("adc read raw         # raw ADC millivolts");
    sout("adc read vbat        # battery voltage + percent");
    sout("adc read charge      # charger voltage + charging flag");
    sout("battery status       # battery snapshot incl. calib min/max");
    sout("battery sample 10    # force N immediate samples (<=50)");
    sout("battery reset min|max  # reset learned min/max calibration");
    sout("battery overlay [single|hold]  # show battery display (B6)");
    sout("=== HELP ADC END ===");
}
void printHelpLogs() {
    sout("=== HELP LOGS BEGIN ===");
    sout("Levels: ERROR < WARN < INFO < DEBUG < TRACE (default INFO).");
    sout("log level DEBUG  # show ADC reads; TRACE adds rate-limited scroll ticks");
    sout("log on | log off # master enable; log status # show current");
    sout("Line format: [<ms> ms] [LEVEL] [CAT] key=value ...");
    sout("Categories: SYS BUTTON MODE FACE AUTO SCROLL LED ADC CMD TEST");
    sout("=== HELP LOGS END ===");
}
void printHelpTests() {
    sout("=== HELP TESTS BEGIN ===");
    sout("test list           # list groups + test names");
    sout("test run all        # run every non-destructive test, restore state");
    sout("test run buttons|led|adc|modes|scroll  # one group");
    sout("test run sweep      # exhaustive option sweep: every brightness, web-safe colors, every scroll speed");
    sout("test report         # last run pass/warn/fail counts");
    sout("Output: [TEST] <name> PASS|WARN|FAIL ... then [TEST] SUMMARY ...");
    sout("=== HELP TESTS END ===");
}

/*
 * reboot
 * - Test teardown helper: reset the ESP32 after the full HIL/WebUI run.
 * - Hardware effect: ESP.restart() after the OK line has had a short time to flush.
 * - Expected reply: OK reboot restarting=1
 */
void cmdReboot(int argc, char** argv) {
    (void)argc;
    (void)argv;
    RLOG_INFO("SYS", "event=reboot source=serial reason=test_teardown");
    sout("OK reboot restarting=1");
    delay(80);
    ESP.restart();
}

// =============================================================================
//  Dispatch
// =============================================================================
struct SerialCmd { const char* name; void (*handler)(int, char**); const char* help; };

const SerialCmd CMDS[] = {
    { "help",    cmdHelp,    "list commands / topic help" },
    { "status",  cmdStatus,  "full runtime snapshot" },
    { "version", cmdVersion, "firmware id + feature gates" },
    { "uptime",  cmdUptime,  "ms since boot" },
    { "log",     cmdLog,     "control serial logging level/enable" },
    { "btn",     cmdBtn,     "emulate GPIO buttons (source=serial)" },
    { "led",     cmdLed,     "LED diagnostics + test patterns" },
    { "adc",     cmdAdc,     "ADC voltage reads" },
    { "battery", cmdBattery, "battery status / forced sampling" },
    { "mode",    cmdMode,    "manual/auto mode control" },
    { "face",    cmdFace,    "saved-face navigation" },
    { "auto",    cmdAuto,    "auto playback control" },
    { "scroll",  cmdScroll,  "text scroll control" },
    { "pause",   cmdPause,   "global pause (scroll/auto)" },
    { "resume",  cmdResume,  "global resume" },
    { "frame",   cmdFrame,   "push one arbitrary M370 frame" },
    { "terminate", cmdTerminate, "stop competing activities" },
    { "test",    cmdTest,    "built-in self-test runner" },
    { "reboot",  cmdReboot,  "reset board after test teardown" },
};

void dispatch(char* line) {
    char* argv[MAX_ARGS];
    const int argc = tokenize(line, argv, MAX_ARGS);
    if (argc == 0) return;
    for (const SerialCmd& c : CMDS) {
        if (strcasecmp(argv[0], c.name) == 0) { c.handler(argc, argv); return; }
    }
    RLOG_WARN("CMD", "event=reject source=serial cmd=%s err=unknown_command", argv[0]);
    sout("ERR unknown_command=%s (try 'help')", argv[0]);
}

char     sLine[SERIAL_CMD_MAX];
uint16_t sLineLen = 0;

}  // namespace

void initSerialConsole() {
    rinaLogInit();
    sout("=== RinaChan serial console ready (%s) -- type 'help' ===", FIRMWARE_VERSION);
    RLOG_INFO("SYS", "event=console_ready fw=%s", FIRMWARE_VERSION);
}

void serviceSerialConsole() {
    // Non-blocking: consume only buffered bytes, dispatch on newline.
    while (rinaSerialAvailable() > 0) {
        const int b = rinaSerialRead();
        if (b < 0) break;
        const char c = static_cast<char>(b);
        if (c == '\n' || c == '\r') {
            if (sLineLen > 0) {
                sLine[sLineLen] = '\0';
                dispatch(sLine);
                sLineLen = 0;
            }
        } else if (sLineLen < SERIAL_CMD_MAX - 1) {
            sLine[sLineLen++] = c;
        } else {
            sLineLen = 0;  // oversized line: drop it
            sout("ERR line_too_long max=%u", SERIAL_CMD_MAX - 1);
        }
    }
    serviceEmuJobs(millis());
}

#else  // ENABLE_SERIAL_CONSOLE == 0  -> compiled out entirely

void initSerialConsole() {}
void serviceSerialConsole() {}

#endif  // ENABLE_SERIAL_CONSOLE
