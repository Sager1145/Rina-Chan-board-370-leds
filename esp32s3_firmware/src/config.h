#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Hardware
// ---------------------------------------------------------------------------
constexpr char     AP_SSID[]              = "RinaChanBoard-V2";
constexpr char     AP_PASSWORD[]          = "rinachan";
constexpr char     AP_DOMAIN[]            = "rina.io";
constexpr uint16_t HTTP_PORT             = 80;
constexpr uint16_t DNS_PORT              = 53;

#include <IPAddress.h>

extern const IPAddress AP_IP_ADDR;
extern const IPAddress AP_GATEWAY_ADDR;
extern const IPAddress AP_SUBNET_MASK;

/**
 * @brief Return SoftAP IP address configured in config.cpp.
 * @param None.
 * @return SoftAP IP address reference.
 */
inline const IPAddress& apIP()      { return AP_IP_ADDR; }

/**
 * @brief Return SoftAP gateway address configured in config.cpp.
 * @param None.
 * @return SoftAP gateway address reference.
 */
inline const IPAddress& apGateway() { return AP_GATEWAY_ADDR; }

/**
 * @brief Return SoftAP subnet mask configured in config.cpp.
 * @param None.
 * @return SoftAP subnet mask reference.
 */
inline const IPAddress& apSubnet()  { return AP_SUBNET_MASK; }
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
// Calibration: empirical scale and offset corrections derived from two-point
// measurements against a reference multimeter.
// Battery:  adc=2.912V->8.09V, adc=2.864V->7.96V  => scale=2.708333, offset=+0.2033V
// Charge:   adc=0.661V->4.49V, adc=1.753V->11.79V => scale=6.684982, offset=+0.0712V
constexpr float    BATTERY_CAL_SCALE     = 2.708333f;  // replaces dividerScale for battery
constexpr float    BATTERY_CAL_OFFSET_V  = 0.2033f;    // additive offset after scaling
constexpr float    CHARGE_CAL_SCALE      = 6.684982f;  // replaces dividerScale for charge
constexpr float    CHARGE_CAL_OFFSET_V   = 0.0712f;    // additive offset after scaling
constexpr float    BATTERY_EMPTY_V       = 6.2f;
constexpr float    BATTERY_FULL_V        = 8.0f;
constexpr float    BATTERY_UNPOWERED_LOW_V = 5.0f;  // below this at boot/run-time is treated as not battery-powered
constexpr float    CHARGE_PRESENT_V      = 4.0f;
constexpr uint8_t  POWER_ADC_SAMPLES     = 16;
constexpr uint8_t  POWER_ADC_TRIM_COUNT  = 4;
constexpr uint32_t BATTERY_SAMPLE_MS     = 1000;
constexpr uint32_t CHARGE_SAMPLE_MS      = 1000;
constexpr uint32_t POWER_WEB_SLOW_PUBLISH_MS = 10000;
constexpr float    POWER_WEB_VBAT_EPS_V      = 0.01f;
constexpr float    POWER_WEB_VCHARGE_EPS_V   = 0.05f;
constexpr uint16_t BATTERY_DISCONNECT_ADC_DROP_MV = 1000;
constexpr uint16_t BATTERY_DISCONNECT_ADC_LOW_MV  = 900;
constexpr uint16_t BATTERY_RECONNECT_ADC_MV       = 1500;
constexpr char     BATTERY_CALIB_PATH[]  = "/resources/battery_calib.json";

// ---------------------------------------------------------------------------
// Battery percentage look-up table (2S LiPo piecewise-linear discharge curve)
// ---------------------------------------------------------------------------
// Each entry is { real-world voltage at the battery terminals (V), percent }.
// Points must be sorted highest-voltage first.  batteryPercentFromVoltage()
// uses piecewise-linear interpolation between adjacent entries; voltages above
// the first entry clamp to 100 % and below the last entry clamp to 0 %.
//
// Derived from a typical 2S (2 * 3.1 V to 2 * 4.2 V) lithium-polymer cell:
//   full about 8.40 V (2 * 4.20 V); empty about 6.20 V (2 * 3.10 V cutoff)
// The curve is intentionally non-linear to match the flat mid-range plateau
// and the steep drop-off near the bottom that linear arithmetic misses.
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
// Realtime frame rate limits
// ---------------------------------------------------------------------------
constexpr uint16_t M370_FRAME_MIN_INTERVAL_MS    = 33;
constexpr uint8_t  M370_FRAME_QUEUE_DEPTH        = 3;
constexpr uint8_t  M370_FRAME_REASON_CHARS       = 64;

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
constexpr uint16_t MAX_SCROLL_FRAMES             = 3072;
constexpr uint16_t MIN_SCROLL_INTERVAL_MS        = M370_FRAME_MIN_INTERVAL_MS;
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
constexpr uint16_t LED_BOOT_DATA_LOW_HOLD_MS        = 20;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS           = 350;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS       = 120;

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
