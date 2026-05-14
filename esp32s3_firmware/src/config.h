#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Hardware
// ---------------------------------------------------------------------------
constexpr char     AP_SSID[]              = "RinaChanBoard-V2";
constexpr char     AP_PASSWORD[]          = "rinachan";
constexpr uint16_t HTTP_PORT             = 80;

// AP network configuration — defined as inline functions to avoid
// multiple-definition errors when config.h is included in several TUs.
#include <IPAddress.h>
inline IPAddress apIP()      { return IPAddress(192, 168, 1, 14); }
inline IPAddress apGateway() { return IPAddress(192, 168, 1, 14); }
inline IPAddress apSubnet()  { return IPAddress(255, 255, 255, 0); }
constexpr uint16_t LED_PIN               = 2;
constexpr uint16_t LED_COUNT             = 370;
constexpr uint8_t  BUTTON_B1_PIN         = 17;
constexpr uint8_t  BUTTON_B2_PIN         = 16;
constexpr uint8_t  BUTTON_B3_PIN         = 15;
constexpr uint8_t  BUTTON_B4_PIN         = 40;
constexpr uint8_t  BUTTON_B5_PIN         = 41;
constexpr uint8_t  BUTTON_B6_PIN         = 42;

// ---------------------------------------------------------------------------
// Power monitor ADC
// ---------------------------------------------------------------------------
constexpr uint8_t  BATTERY_ADC_PIN       = 10;
constexpr uint8_t  CHARGE_ADC_PIN        = 1;
constexpr float    BATTERY_DIVIDER_R1_K  = 100.0f;
constexpr float    BATTERY_DIVIDER_R2_K  = 57.0f;
constexpr float    CHARGE_DIVIDER_R1_K   = 270.0f;
constexpr float    CHARGE_DIVIDER_R2_K   = 47.0f;
constexpr float    BATTERY_EMPTY_V       = 6.2f;
constexpr float    BATTERY_FULL_V        = 8.0f;
constexpr float    CHARGE_PRESENT_V      = 4.0f;
constexpr uint8_t  POWER_ADC_SAMPLES     = 16;
constexpr uint8_t  POWER_ADC_TRIM_COUNT  = 4;
constexpr uint32_t BATTERY_SAMPLE_MS     = 10000;
constexpr uint32_t CHARGE_SAMPLE_MS      = 1000;

// ---------------------------------------------------------------------------
// LED matrix geometry
// ---------------------------------------------------------------------------
constexpr uint16_t M370_HEX_CHARS        = 93;
constexpr uint16_t M370_BITS             = 370;
constexpr uint16_t FRAME_BYTES           = (LED_COUNT + 7) / 8;
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

// ---------------------------------------------------------------------------
// Brightness
// ---------------------------------------------------------------------------
constexpr uint8_t  DEFAULT_BRIGHTNESS    = 50;
constexpr uint8_t  MIN_BRIGHTNESS        = 10;
constexpr uint8_t  MAX_BRIGHTNESS        = 200;
constexpr int8_t   BRIGHTNESS_BUTTON_STEP = 8;

// ---------------------------------------------------------------------------
// Auto-playback
// ---------------------------------------------------------------------------
constexpr uint32_t DEFAULT_AUTO_INTERVAL_MS      = 3000;
constexpr uint32_t MIN_AUTO_INTERVAL_MS          = 500;
constexpr uint32_t MAX_AUTO_INTERVAL_MS          = 10000;
constexpr uint32_t AUTO_INTERVAL_BUTTON_STEP_MS  = 500;
constexpr uint16_t MAX_AUTO_FACES                = 128;

// ---------------------------------------------------------------------------
// Scroll
// ---------------------------------------------------------------------------
constexpr uint16_t MAX_SCROLL_FRAMES             = 2048;
constexpr uint16_t MIN_SCROLL_INTERVAL_MS        = 8;
constexpr uint16_t MAX_SCROLL_INTERVAL_MS        = 1000;
constexpr uint16_t DEFAULT_SCROLL_INTERVAL_MS    = 100;
constexpr uint8_t  SCROLL_DRIFT_RESET_INTERVALS  = 4;

// ---------------------------------------------------------------------------
// Button debounce / repeat
// ---------------------------------------------------------------------------
constexpr uint32_t BUTTON_DEBOUNCE_MS            = 25;
constexpr uint32_t FACE_REPEAT_DELAY_MS          = 650;
constexpr uint32_t FACE_REPEAT_MS                = 350;
constexpr uint32_t BRIGHTNESS_REPEAT_DELAY_MS    = 450;
constexpr uint32_t BRIGHTNESS_REPEAT_MS          = 120;

// ---------------------------------------------------------------------------
// LED render task (FreeRTOS)
// ---------------------------------------------------------------------------
constexpr uint8_t  LED_RENDER_TASK_CORE          = 1;
constexpr uint32_t LED_RENDER_TASK_STACK_BYTES   = 6144;
constexpr uint8_t  LED_RENDER_TASK_PRIORITY      = 3;

// ---------------------------------------------------------------------------
// LED timing  (BSS138 level-shifter aware)
// ---------------------------------------------------------------------------
// Idle-low window inserted before and after each strip.show() call.
// Deliberately longer than the WS2812 protocol minimum because the BSS138
// has slow pull-up-dependent rising edges that can leave the first LED near
// its timing threshold during rapid refreshes.
constexpr uint16_t LED_SIGNAL_RESET_US           = 300;

// Minimum wall-clock gap enforced between consecutive strip.show() calls.
// Must be > LED_SIGNAL_RESET_US so the post-show reset is always contained
// inside the gap window.
constexpr uint16_t LED_RENDER_MIN_GAP_US         = 2500;

// ---------------------------------------------------------------------------
// Boot / stop-clear timing
// ---------------------------------------------------------------------------
constexpr uint16_t LED_STOP_CLEAR_BLANK_HOLD_MS    = 90;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS           = 120;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS       = 40;

// ---------------------------------------------------------------------------
// Defaults / string constants
// ---------------------------------------------------------------------------
constexpr char DEFAULT_COLOR[]          = "#f971d4";
constexpr char DEFAULT_MODE[]           = "manual";
constexpr char DEFAULT_PLAYBACK[]       = "idle";
constexpr char STARTUP_FACE_REASON[]    = "startup_sequence_complete_saved_face";
constexpr char LITTLEFS_BASE_PATH[]     = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
constexpr char SAVED_FACES_PATH[]       = "/resources/saved_faces.json";
constexpr char SETTINGS_PATH[]          = "/resources/runtime_settings.json";
