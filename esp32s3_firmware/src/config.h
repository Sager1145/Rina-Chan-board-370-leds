#pragma once
/*
 * File Description: config.h
 * Declares ESP32-S3 pin mappings, default networking options, and physical constants.
 *
 * Responsibilities:
 * - Maps system GPIO pins (LED strip control pin, physical buttons B1 to B6, battery/ADC pins).
 * - Establishes default WiFi credentials (SSID/Password) and access points details.
 * - Stores firmware brightness boundaries, timing limits, and file paths for LittleFS.
 */
#include <Arduino.h>

constexpr char     AP_SSID[]              = "RinaChanBoard-V2";
constexpr char     AP_PASSWORD[]          = "rinachan";
constexpr char     AP_DOMAIN[]            = "rina.io";
constexpr uint16_t HTTP_PORT             = 80;
constexpr uint16_t DNS_PORT              = 53;

#include <IPAddress.h>

extern const IPAddress AP_IP_ADDR;
extern const IPAddress AP_GATEWAY_ADDR;
extern const IPAddress AP_SUBNET_MASK;

inline const IPAddress& apIP()      { return AP_IP_ADDR; }

inline const IPAddress& apGateway() { return AP_GATEWAY_ADDR; }

inline const IPAddress& apSubnet()  { return AP_SUBNET_MASK; }
constexpr uint16_t LED_PIN               = 2;
constexpr uint16_t LED_COUNT             = 370;
constexpr uint8_t  BUTTON_B1_PIN         = 17;
constexpr uint8_t  BUTTON_B2_PIN         = 16;
constexpr uint8_t  BUTTON_B3_PIN         = 15;
constexpr uint8_t  BUTTON_B4_PIN         = 40;
constexpr uint8_t  BUTTON_B5_PIN         = 41;
constexpr uint8_t  BUTTON_B6_PIN         = 42;

constexpr uint8_t  BATTERY_ADC_PIN       = 10;
constexpr uint8_t  CHARGE_ADC_PIN        = 1;
constexpr float    BATTERY_DIVIDER_R1_K  = 100.0f;
constexpr float    BATTERY_DIVIDER_R2_K  = 57.0f;
constexpr float    CHARGE_DIVIDER_R1_K   = 270.0f;
constexpr float    CHARGE_DIVIDER_R2_K   = 47.0f;
constexpr float    BATTERY_CAL_SCALE     = 2.708333f;  // Explains power, battery, charging, or ADC calibration logic.
constexpr float    BATTERY_CAL_OFFSET_V  = 0.2033f;    // Explains the responsibilities and maintenance constraints of the current code block in hardware, matrix, and timing configuration.
constexpr float    CHARGE_CAL_SCALE      = 6.684982f;  // Explains power, battery, charging, or ADC calibration logic.
constexpr float    CHARGE_CAL_OFFSET_V   = 0.0712f;    // Explains the responsibilities and maintenance constraints of the current code block in hardware, matrix, and timing configuration.
constexpr float    BATTERY_EMPTY_V       = 6.2f;
constexpr float    BATTERY_FULL_V        = 8.0f;
constexpr float    BATTERY_UNPOWERED_LOW_V = 5.0f;  // Explains power, battery, charging, or ADC calibration logic.
constexpr float    CHARGE_PRESENT_V      = 4.0f;
constexpr uint8_t  POWER_ADC_SAMPLES     = 16;
constexpr uint8_t  POWER_ADC_TRIM_COUNT  = 4;
static_assert(POWER_ADC_TRIM_COUNT * 2U < POWER_ADC_SAMPLES,
              "trimmed ADC sampling must leave at least one averaged sample");
constexpr uint32_t BATTERY_SAMPLE_MS     = 1000;
constexpr uint32_t CHARGE_SAMPLE_MS      = 1000;
constexpr uint32_t POWER_WEB_SLOW_PUBLISH_MS = 10000;
constexpr float    POWER_WEB_VBAT_EPS_V      = 0.01f;
constexpr float    POWER_WEB_VCHARGE_EPS_V   = 0.05f;
constexpr uint16_t BATTERY_DISCONNECT_ADC_DROP_MV = 1000;
constexpr uint16_t BATTERY_DISCONNECT_ADC_LOW_MV  = 900;
constexpr uint16_t BATTERY_RECONNECT_ADC_MV       = 1500;
constexpr char     BATTERY_CALIB_PATH[]  = "/resources/battery_calib.json";

//
struct BatteryLutPoint { float voltage; uint8_t percent; };
constexpr BatteryLutPoint BATTERY_PERCENT_LUT[] = {
    { 8.40f, 100 },
    { 8.10f,  90 },
    { 7.90f,  80 },
    { 7.70f,  65 },
    { 7.50f,  50 },
    { 7.30f,  35 },
    { 7.10f,  20 },
    { 6.80f,  10 },
    { 6.50f,   5 },
    { 6.20f,   0 },
};
constexpr uint8_t BATTERY_PERCENT_LUT_SIZE =
    static_cast<uint8_t>(sizeof(BATTERY_PERCENT_LUT) / sizeof(BATTERY_PERCENT_LUT[0]));
constexpr uint32_t BATTERY_CALIB_SHRINK_TIMEOUT_MS = 7UL * 24UL * 60UL * 60UL * 1000UL;
constexpr uint32_t BATTERY_CALIB_SAVE_DELAY_MS     = 15000;
constexpr float    BATTERY_CALIB_SHRINK_STEP_V     = 0.02f;
constexpr float    BATTERY_CALIB_MIN_SPAN_V        = 0.10f;

constexpr uint16_t M370_HEX_CHARS        = 93;
constexpr uint16_t M370_BITS             = 370;
constexpr uint16_t FRAME_BYTES           = (LED_COUNT + 7) / 8;
static_assert(M370_HEX_CHARS == (M370_BITS + 3U) / 4U,
              "M370 hex character count must match packed bit count");
constexpr uint8_t  MATRIX_ROWS           = 18;
constexpr bool     SERPENTINE_WIRING             = true;
constexpr bool     SERPENTINE_ODD_ROWS_REVERSED  = true;

constexpr uint8_t  ROW_LENGTHS[MATRIX_ROWS] = {
    18, 20, 20, 20, 22, 22, 22, 22, 22,
    22, 22, 22, 22, 20, 20, 20, 18, 16
};
constexpr uint16_t ROW_OFFSETS[MATRIX_ROWS] = {
    0, 18, 38, 58, 78, 100, 122, 144, 166,
    188, 210, 232, 254, 276, 296, 316, 336, 354
};
static_assert(ROW_OFFSETS[MATRIX_ROWS - 1] + ROW_LENGTHS[MATRIX_ROWS - 1] == LED_COUNT,
              "matrix row layout must cover exactly LED_COUNT logical cells");

constexpr uint8_t  DEFAULT_BRIGHTNESS    = 50;
constexpr uint8_t  MIN_BRIGHTNESS        = 10;
constexpr uint8_t  MAX_BRIGHTNESS        = 200;
constexpr int8_t   BRIGHTNESS_BUTTON_STEP = 8;

constexpr uint16_t M370_FRAME_MIN_INTERVAL_MS    = 33;
constexpr uint8_t  M370_FRAME_QUEUE_DEPTH        = 3;
constexpr uint8_t  M370_FRAME_REASON_CHARS       = 64;

constexpr uint32_t DEFAULT_AUTO_INTERVAL_MS      = 3000;
constexpr uint32_t MIN_AUTO_INTERVAL_MS          = 500;
constexpr uint32_t MAX_AUTO_INTERVAL_MS          = 10000;
constexpr uint32_t AUTO_INTERVAL_BUTTON_STEP_MS  = 500;
constexpr uint16_t MAX_AUTO_FACES                = 128;

// Production safety: by default the ~144 KB scroll frame cache must live in PSRAM.
// If PSRAM is missing/misconfigured/fails, do NOT silently fall back to internal
// SRAM -- that starves WiFi/LwIP/WebServer/JSON of contiguous internal heap and
// causes long-runtime OOM panics. Define ALLOW_INTERNAL_SCROLL_CACHE=1 at build
// time only for boards intentionally run without PSRAM (text scroll degraded).
#ifndef ALLOW_INTERNAL_SCROLL_CACHE
#define ALLOW_INTERNAL_SCROLL_CACHE 0
#endif

constexpr uint16_t MAX_SCROLL_FRAMES             = 3072;
constexpr uint16_t MIN_SCROLL_INTERVAL_MS        = M370_FRAME_MIN_INTERVAL_MS;
constexpr uint16_t MAX_SCROLL_INTERVAL_MS        = 1000;
constexpr uint16_t DEFAULT_SCROLL_INTERVAL_MS    = 100;
constexpr uint8_t  SCROLL_DRIFT_RESET_INTERVALS  = 4;

// Scroll source-text sync: Hard limits for uploaded Unicode source text and
// metadata. The text limit is in UTF-8 bytes, with no code-point limit.
constexpr uint16_t MAX_SCROLL_TEXT_BYTES        = 4096;
constexpr uint8_t  MAX_SCROLL_TIMELINE_ID_CHARS = 47;
constexpr uint8_t  MAX_SCROLL_FONT_ID_CHARS     = 47;
constexpr uint8_t  MAX_SCROLL_GENERATOR_CHARS   = 47;

// =============================================================================
// HTTP server memory hardening -- crash protection against sudden WebUI refreshes.
//
// A browser refresh aborts the in-flight request and immediately fires a burst of
// new ones (index.html + assets + /api/status + /api/scroll/meta + /api/frame ...).
// Every dynamic endpoint allocates *internal* DRAM: the request-body copy, the
// serialized JSON response String, per-frame temporaries. If such a burst lands
// while internal heap is already low or fragmented, an allocation -- ours or the
// WiFi/LwIP stack's -- can fail and panic the board (the "crash on refresh").
//
// Defence is admission control: before a handler does its big allocations it checks
// the free internal heap, and if it is below this floor it sheds the request with
// HTTP 503 instead of attempting the allocation and risking an OOM crash. This is
// mode-independent (manual / auto / scroll) because every mode shares these
// endpoints. The floor leaves headroom for one heavy response plus the WiFi stack.
constexpr uint32_t HTTP_MIN_FREE_HEAP_BYTES      = 40960;  // 40 KB internal-heap admission floor
// Free heap alone is not enough: internal DRAM fragments over long uptime (per-poll
// JSON response Strings, WiFi/LwIP churn), so total free can stay high while the
// largest *contiguous* block shrinks below what one response or a WiFi buffer needs.
// A contiguous allocation then panics even though getFreeHeap() looks healthy. We
// therefore also require a minimum largest-free-block before doing big allocations.
constexpr uint32_t HTTP_MIN_LARGEST_BLOCK_BYTES  = 20480;  // 20 KB largest contiguous internal block
constexpr uint32_t HTTP_MAX_REQUEST_BODY_BYTES   = 65536;  // hard cap on any POST body we will parse
constexpr uint32_t SCROLL_MAX_UPLOAD_BODY_BYTES  = 16384;  // tighter cap on a single /api/scroll chunk body
// /api/frame_bin reads its body straight off the raw socket. Bound each blocking
// read so a slow/lossy client cannot stall the Core-0 cooperative loop for the
// WiFiClient default (~1000 ms) timeout (P1-B).
constexpr uint32_t BIN_FRAME_READ_TIMEOUT_MS     = 50;

// P1-6: an interrupted timeline upload (WebUI refresh / WiFi drop / browser abort mid-
// upload) can leave a staged, never-completed replacement timeline in progress. It is
// not playable (D2) and is replaced on the next upload, but we also reclaim it on a
// timer so it cannot linger. Checked at most once per SCROLL_UPLOAD_STALE_CHECK_MS from
// webServerTick(); a staged upload with no chunk activity for SCROLL_UPLOAD_STALE_
// TIMEOUT_MS is abandoned (the active, playing timeline is never touched).
constexpr uint32_t SCROLL_UPLOAD_STALE_TIMEOUT_MS = 10000;
constexpr uint32_t SCROLL_UPLOAD_STALE_CHECK_MS   = 2000;

constexpr uint32_t BUTTON_DEBOUNCE_MS            = 25;
constexpr uint32_t FACE_REPEAT_DELAY_MS          = 650;
constexpr uint32_t FACE_REPEAT_MS                = 350;
constexpr uint32_t BRIGHTNESS_REPEAT_DELAY_MS    = 450;
constexpr uint32_t BRIGHTNESS_REPEAT_MS          = 120;

constexpr uint8_t  LED_RENDER_TASK_CORE          = 1;
constexpr uint32_t LED_RENDER_TASK_STACK_BYTES   = 6144;
constexpr uint8_t  LED_RENDER_TASK_PRIORITY      = 3;

constexpr uint16_t LED_SIGNAL_RESET_US           = 300;

constexpr uint16_t LED_RENDER_MIN_GAP_US         = 2500;

constexpr uint16_t LED_STOP_CLEAR_BLANK_HOLD_MS    = 90;
constexpr uint16_t LED_BOOT_DATA_LOW_HOLD_MS        = 20;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS           = 350;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS       = 120;

constexpr char DEFAULT_COLOR[]          = "#ec3fc7";
constexpr char DEFAULT_MODE[]           = "manual";
constexpr char DEFAULT_PLAYBACK[]       = "idle";
constexpr char STARTUP_FACE_REASON[]    = "startup_sequence_complete_saved_face";
constexpr char LITTLEFS_BASE_PATH[]     = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
constexpr char SAVED_FACES_PATH[]       = "/resources/saved_faces.json";
// Hard cap on saved_faces.json read at load time. Matches the HTTP write cap so a
// file we accepted over the API is always loadable, while a corrupt/oversized file
// is rejected before allocating a buffer of its size. 128 faces * generous per-face
// JSON stays well under this.
constexpr size_t SAVED_FACES_MAX_FILE_BYTES = 65536;
constexpr char SETTINGS_PATH[]          = "/resources/runtime_settings.json";

#ifndef RINACHAN_VERBOSE_LOGS
#define RINACHAN_VERBOSE_LOGS 0
#endif

#if RINACHAN_VERBOSE_LOGS
#define LOGV(...) Serial.printf(__VA_ARGS__)
#else
#define LOGV(...) do {} while (0)
#endif

// =============================================================================
// Serial diagnostics / test console feature gates.
//
// All three default ON because the feature is purely additive and non-blocking:
// with no serial commands issued and the default INFO log level, normal LED /
// WebUI / button / battery / scroll behavior is unchanged. Set any of these to 0
// at build time (e.g. a stripped production image) to compile the feature out
// entirely -- every hook then becomes a no-op `do {} while (0)`.
//   ENABLE_SERIAL_DIAGNOSTICS : the structured logger (RLOG_* + LED history)
//   ENABLE_SERIAL_CONSOLE     : the text command parser / button emulator
//   ENABLE_FIRMWARE_TESTS     : the built-in `test run ...` self-test runner
//   ENABLE_SERIAL_UART0_MIRROR: mirror diagnostics I/O to UART0 when Serial is
//                               native USB-CDC (ESP32-S3 dual COM-port tests)
// The console depends on the logger (it drives the `log` commands and reads the
// LED history), so the combination console=1 + diagnostics=0 is rejected.
// =============================================================================
#ifndef ENABLE_PERF_PROFILING
#define ENABLE_PERF_PROFILING 1
#endif
#ifndef ENABLE_SERIAL_DIAGNOSTICS
#define ENABLE_SERIAL_DIAGNOSTICS 1
#endif
#ifndef ENABLE_SERIAL_CONSOLE
#define ENABLE_SERIAL_CONSOLE 1
#endif
#ifndef ENABLE_FIRMWARE_TESTS
#define ENABLE_FIRMWARE_TESTS 1
#endif
#ifndef ENABLE_SERIAL_UART0_MIRROR
#define ENABLE_SERIAL_UART0_MIRROR 0
#endif
#if ENABLE_SERIAL_CONSOLE && !ENABLE_SERIAL_DIAGNOSTICS
#error "ENABLE_SERIAL_CONSOLE=1 requires ENABLE_SERIAL_DIAGNOSTICS=1"
#endif
#if ENABLE_SERIAL_UART0_MIRROR && !ARDUINO_USB_CDC_ON_BOOT
#error "ENABLE_SERIAL_UART0_MIRROR=1 requires ARDUINO_USB_CDC_ON_BOOT=1 so Serial0 is distinct from Serial"
#endif

// Reported by the `version` serial command.
constexpr char FIRMWARE_NAME[]    = "RinaChanBoard-V2";
constexpr char FIRMWARE_VERSION[] = "serial-diagnostics-1.0";
