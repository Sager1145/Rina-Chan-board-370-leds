#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace rina {
namespace config {

// Version and identity
constexpr const char* VERSION = "1.8.0";
constexpr const char* PROTOCOL_VERSION = "1.7.4-rnt-command-only";
constexpr const char* BANNER =
    "RinaChanBoard ESP32-S3 370LED modular 1.8.0 "
    "color_module-authority brightness-sync AP+protocol+RNT2 battery";

// Hardware pins
constexpr uint8_t LED_PIN = 2;
constexpr uint8_t LED_RMT_CHANNEL = 1;
constexpr uint8_t BATTERY_ADC_GPIO = 10;
constexpr uint8_t CHARGE_DETECT_ADC_GPIO = 1;
constexpr uint8_t BUTTON_AUTO_GPIO = 15;
constexpr uint8_t BUTTON_NEXT_GPIO = 16;
constexpr uint8_t BUTTON_PREV_GPIO = 17;
constexpr uint8_t BUTTON_BRIGHTNESS_DOWN_GPIO = 40;
constexpr uint8_t BUTTON_BRIGHTNESS_UP_GPIO = 41;
constexpr uint8_t BUTTON_RESET_BATTERY_GPIO = 42;
constexpr bool BUTTON_ACTIVE_LOW = true;

// LED matrix geometry
constexpr size_t NUM_LEDS = 370;
constexpr size_t LED_FRAME_BYTES = NUM_LEDS * 3;
constexpr size_t FRAMEBUFFER_ALLOC_BYTES = 1112;
constexpr std::array<uint8_t, 18> ROW_LENGTHS = {
    18,
    20, 20, 20,
    22, 22, 22, 22, 22, 22, 22, 22, 22,
    20, 20, 20,
    18,
    16,
};
constexpr size_t ROWS = ROW_LENGTHS.size();
constexpr size_t COLS = 22;
constexpr bool SERPENTINE = true;
constexpr bool FLIP_X = false;
constexpr bool FLIP_Y = false;

// Legacy RinaChanBoard-main 18x16 source mapping.
constexpr size_t SRC_ROWS = 16;
constexpr size_t SRC_COLS = 18;
constexpr int8_t SRC_TO_DST_ROW_OFFSET = 1;
constexpr int8_t SRC_TO_DST_COL_OFFSET = 2;
constexpr uint8_t SRC_INVALID_COL_0 = 0;
constexpr uint8_t SRC_INVALID_COL_1 = 17;
constexpr size_t FACE_FULL_LEN = 36;
constexpr size_t FACE_TEXT_LITE_LEN = 16;
constexpr size_t FACE_LITE_LEN = 4;
constexpr size_t M370_HEX_CHARS = 93;
constexpr size_t M370_TEXT_CHARS = 98;

// Timing
constexpr uint16_t TARGET_FPS = 30;
constexpr uint32_t FRAME_PERIOD_US = 1000000UL / TARGET_FPS;
constexpr float FRAME_PERIOD_MS_DISPLAY = FRAME_PERIOD_US / 1000.0f;
constexpr uint32_t FRAME_TIME_US = FRAME_PERIOD_US;
constexpr uint16_t POLL_PERIOD_MS = 15;
constexpr uint16_t WDT_TIMEOUT_MS = 3000;
constexpr uint16_t SAFE_MODE_HOLD_MS = 500;
constexpr uint8_t RENDER_TASK_PRIORITY = 6;
constexpr uint8_t NETWORK_TASK_PRIORITY = 5;
constexpr uint8_t APP_LOGIC_TASK_PRIORITY = 3;
constexpr uint8_t RENDER_TASK_CORE = 1;
constexpr uint8_t NETWORK_TASK_CORE = 0;
constexpr uint8_t APP_LOGIC_TASK_CORE = 1;
constexpr uint16_t RENDER_TASK_STACK_WORDS = 4096;
constexpr uint16_t NETWORK_TASK_STACK_WORDS = 8192;
constexpr uint16_t APP_LOGIC_TASK_STACK_WORDS = 8192;
constexpr uint16_t APP_LOGIC_TICK_MS = 5;
constexpr uint16_t NETWORK_TASK_PERIOD_MS = 20;

// Buttons and UI timing
constexpr uint16_t BUTTON_SCAN_PERIOD_MS = 10;
constexpr uint16_t DEBOUNCE_MS = 25;
constexpr uint16_t BUTTON_REPEAT_INITIAL_DELAY_MS = 400;
constexpr uint16_t BUTTON_REPEAT_PERIOD_MS = 140;
constexpr uint16_t BUTTON_LONG_PRESS_MS = 700;
constexpr uint16_t FLASH_HOLD_MS = 1000;
constexpr uint16_t BATTERY_SHORT_SHOW_MS = 2000;
constexpr uint16_t BRIGHTNESS_RESET_IGNORE_MS = 300;
constexpr uint16_t B6_LONG_PRESS_MS = 700;
constexpr uint16_t EDGE_FLASH_ATTACK_MS = 45;
constexpr uint16_t EDGE_FLASH_DECAY_MS = 260;
constexpr uint16_t EDGE_FLASH_TOTAL_MS = EDGE_FLASH_ATTACK_MS + EDGE_FLASH_DECAY_MS;
constexpr std::array<uint8_t, 3> EDGE_FLASH_COLOR = {0, 120, 255};

// Face and brightness defaults
constexpr uint8_t DEFAULT_FACE = 0;
constexpr uint8_t NUM_FACES = 11;
constexpr float DEFAULT_INTERVAL_S = 1.0f;
constexpr float INTERVAL_STEP_S = 0.5f;
constexpr float INTERVAL_MIN_S = 0.5f;
constexpr float INTERVAL_MAX_S = 10.0f;
constexpr uint8_t DEFAULT_BRIGHTNESS = 30;
constexpr uint8_t DEFAULT_BRIGHTNESS_PCT = DEFAULT_BRIGHTNESS;
constexpr uint8_t BRIGHTNESS_STEP = 5;
constexpr uint8_t BRIGHTNESS_MIN = 5;
constexpr uint8_t BRIGHTNESS_MAX = 100;
constexpr uint8_t BRIGHTNESS_MAX_CHANNEL = 170;
constexpr uint8_t MAX_BRIGHTNESS_HARD_CAP = 170;
constexpr uint8_t MAX_BRIGHTNESS_FLOOR = 1;
constexpr uint8_t MAX_BRIGHTNESS_DEFAULT = 51;

// Battery ADC and display calibration
constexpr float BATTERY_ADC_REF_V = 3.3f;
constexpr uint16_t ADC_REF_MV = 3300;
constexpr uint16_t ADC_MAX_RAW = 4095;
constexpr uint8_t BATTERY_SAMPLES = 16;
constexpr uint32_t BATTERY_DIVIDER_R1 = 100000;
constexpr uint32_t BATTERY_DIVIDER_R2 = 57000;
constexpr float BATTERY_DEFAULT_MIN_V = 6.2f;
constexpr float BATTERY_DEFAULT_MAX_V = 8.0f;
constexpr float BATTERY_DISPLAY_TOL_V = 0.12f;
constexpr uint8_t BATTERY_CAL_VERSION = 4;
constexpr uint16_t BATTERY_REFRESH_MS = 100;
constexpr uint16_t BATTERY_ANIMATION_REFRESH_MS = 50;
constexpr uint16_t BATTERY_MEAN_UPDATE_MS = 1000;
constexpr uint16_t BATTERY_MEAN_SAMPLE_INTERVAL_MS = 20;
constexpr uint16_t BATTERY_DISPLAY_CYCLE_MS = 2000;
constexpr uint32_t BATTERY_LOG_INTERVAL_MS = 30000;
constexpr uint16_t BATTERY_RELEARN_EVERY_MEASUREMENTS = 2000;
constexpr float BATTERY_RELEARN_MAX_STEP_V = 0.05f;
constexpr float BATTERY_RELEARN_MIN_STEP_V = 0.05f;
constexpr uint8_t BATTERY_RELEARN_HOLDOFF_MEASUREMENTS = 20;
constexpr uint8_t BATTERY_RELEARN_MAX_CONSECUTIVE = 2;
constexpr float BATTERY_MIN_SPAN_V = 0.20f;
constexpr uint8_t BATTERY_HISTORY_MAX_SAMPLES = 96;
constexpr float BATTERY_HISTORY_MIN_RATE_PCT_PER_H = 0.25f;
constexpr float BATTERY_HISTORY_SAME_MODE_WEIGHT = 2.5f;
constexpr uint8_t BATTERY_HISTORY_BRIGHTNESS_WINDOW = 20;
constexpr float BATTERY_DEFAULT_USAGE_HOURS = 1.0f;
constexpr float BATTERY_DEFAULT_CHARGE_HOURS = 0.5f;

struct BatteryCurvePoint {
    float x;
    float percent;
};

constexpr std::array<BatteryCurvePoint, 14> BATTERY_PERCENT_CURVE = {{
    {0.000f,   0.0f},
    {0.222f,   3.0f},
    {0.389f,   7.0f},
    {0.444f,  10.0f},
    {0.500f,  14.0f},
    {0.556f,  18.0f},
    {0.611f,  26.0f},
    {0.667f,  35.0f},
    {0.722f,  45.0f},
    {0.778f,  58.0f},
    {0.833f,  70.0f},
    {0.889f,  82.0f},
    {0.944f,  92.0f},
    {1.000f, 100.0f},
}};

// Charge-detect ADC
constexpr float CHARGE_DETECT_ADC_REF_V = 3.3f;
constexpr uint8_t CHARGE_DETECT_SAMPLES = 16;
constexpr uint32_t CHARGE_DETECT_DIVIDER_R1 = 270000;
constexpr uint32_t CHARGE_DETECT_DIVIDER_R2 = 47000;
constexpr float CHARGE_DETECT_NON_CHARGING_V = 3.0f;
constexpr float CHARGE_DETECT_HYSTERESIS_LOW_V = CHARGE_DETECT_NON_CHARGING_V;
constexpr float CHARGE_DETECT_CHARGING_MIN_V = 4.0f;
constexpr float CHARGE_DISPLAY_THRESHOLD_V = 4.5f;
constexpr float BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S = 0.2f;
constexpr float BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S = 0.2f;
constexpr uint8_t BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT = 90;
constexpr float BATTERY_CHARGE_ANIM_FULL_CYCLE_S = 0.2f;
constexpr uint16_t BATTERY_CHARGE_LAST_COLUMN_FLASH_MS = 300;

// Dynamic Power Scaling budget
constexpr uint16_t LED_FULL_WHITE_MA = 60;
constexpr uint32_t LED_THEORETICAL_MAX_MA = NUM_LEDS * LED_FULL_WHITE_MA;
constexpr uint32_t POWER_SOURCE_MAX_W = 65;
constexpr float BUCK_EFFICIENCY = 0.90f;
constexpr float POWER_RAIL_V = 5.0f;
constexpr uint32_t POWER_SOURCE_MAX_MW = POWER_SOURCE_MAX_W * 1000UL;
constexpr uint16_t BUCK_EFFICIENCY_PER_MILLE = 900;
constexpr uint16_t POWER_RAIL_MV = 5000;
constexpr uint32_t POWER_THEORETICAL_MAX_MA =
    (POWER_SOURCE_MAX_MW * BUCK_EFFICIENCY_PER_MILLE / 1000UL) * 1000UL / POWER_RAIL_MV;
constexpr uint32_t PCB_TRACE_AMPACITY_MA = 12000;
constexpr uint32_t CONNECTOR_RATING_MA = 10000;
constexpr uint32_t BATTERY_BMS_DISCHARGE_MA = 15000;
constexpr uint32_t HARDWARE_SUSTAINED_MAX_MA = CONNECTOR_RATING_MA;
constexpr uint32_t POWER_BUDGET_MA_ABSOLUTE_MAX = HARDWARE_SUSTAINED_MAX_MA * 90UL / 100UL;
constexpr uint32_t POWER_BUDGET_MA_DEFAULT = POWER_BUDGET_MA_ABSOLUTE_MAX * 95UL / 100UL;
constexpr uint32_t POWER_BUDGET_MA_ACCEPTANCE_PEAK = POWER_BUDGET_MA_ABSOLUTE_MAX * 105UL / 100UL;
constexpr uint32_t POWER_BUDGET_MA_CONFIG_MIN = 3000;
constexpr uint32_t POWER_BUDGET_MA_CONFIG_MAX = 11000;

// AP-only network and protocol
constexpr const char* AP_SSID = "RinaChanBoard-ESP32S3";
constexpr const char* AP_PASSWORD = "rinachan";
constexpr uint8_t AP_CHANNEL = 6;
constexpr const char* AP_IP = "192.168.4.1";
constexpr const char* AP_GATEWAY = "192.168.4.1";
constexpr const char* AP_NETMASK = "255.255.255.0";
constexpr uint8_t AP_MAX_CLIENTS = 4;
constexpr uint16_t HTTP_PORT = 80;
constexpr uint16_t LOCAL_UDP_PORT = 1234;
constexpr uint16_t REMOTE_UDP_PORT = 4321;
constexpr uint8_t NETWORK_M370_QUEUE_DEPTH = 4;
constexpr uint16_t UDP_RX_BUF_BYTES = 1024;
constexpr uint16_t HTTP_RX_BUF_BYTES = 1024;
constexpr uint16_t UDP_BURST_LIMIT = 8;
constexpr uint16_t UDP_RX_BUDGET_US = 2000;
constexpr uint16_t TX_CHUNK_BYTES = 512;
constexpr uint32_t TX_STALL_TIMEOUT_MS = 30000;
constexpr uint16_t TX_STALL_TIMEOUT_AGGRESSIVE_MS = 5000;
constexpr uint16_t WAIT_REPLY_TIMEOUT_MS = 1500;
constexpr uint16_t HTTP_MAX_BODY_BYTES = 4096;
constexpr uint16_t RAM_TIMELINE_MAX_BODY_BYTES = 4096;
constexpr uint16_t PATHB_JSON_MAX_BODY_BYTES = 4096;
constexpr uint16_t PATHB_M370_MAX_BODY_BYTES = 16384;
constexpr uint16_t HTTP_MAX_BODY_BYTES_HARD = 16384;
constexpr uint8_t M370_ON_R = 255;
constexpr uint8_t M370_ON_G = 255;
constexpr uint8_t M370_ON_B = 255;

// Captive portal DNS
constexpr bool CAPTIVE_PORTAL_ENABLED = true;
constexpr uint16_t DNS_PORT = 53;
constexpr const char* CAPTIVE_PORTAL_IP = AP_IP;
constexpr uint16_t DNS_RX_BUF_SIZE = 512;
constexpr uint16_t DNS_RX_BUDGET_US = 1000;

// Storage and assets
constexpr const char* LITTLEFS_BASE_PATH = "/littlefs";
constexpr const char* LITTLEFS_PARTITION_LABEL = "littlefs";
constexpr const char* SETTINGS_FILE = "/linaboard_settings.json";
constexpr const char* SETTINGS_TMP_FILE = "/linaboard_settings.json.tmp";
constexpr const char* WEBUI_GZIP_FILE = "/webui_index.html.gz";
constexpr const char* ASSET_ROOT = "/isolated_led_assets";
constexpr uint16_t SETTINGS_MAX_JSON_BYTES = 4096;
constexpr uint8_t BATTERY_HISTORY_SETTINGS_MAX_SAMPLES = 32;
constexpr uint16_t DIRTY_QUEUE_TIMER_MS = 500;
constexpr uint32_t FLASH_FLUSH_DEBOUNCE_MS = 5000;
constexpr uint32_t MAX_DIRTY_DURATION_MS = 30000;
constexpr uint16_t FLASH_DEBOUNCE_MS_HIGH = 1000;
constexpr uint16_t FLASH_DEBOUNCE_MS_NORMAL = 5000;
constexpr uint16_t FLASH_DEBOUNCE_MS_LOW = 30000;
constexpr uint16_t LOW_BATTERY_FORCE_FLUSH_DEBOUNCE_MS = 500;
constexpr uint16_t RNT_CHUNK_SIZE = 4096;
constexpr uint16_t RNT_LINE_MAX_BYTES = 160;
constexpr uint16_t ASSET_BUNDLE_MAX_BYTES = 32768;

// Optional CPU downclock targets; disabled until later phases wire policy.
constexpr uint32_t CPU_FREQ_ACTIVE_HZ = 240000000UL;
constexpr uint32_t CPU_FREQ_IDLE_HZ = 80000000UL;
constexpr uint16_t CPU_FREQ_IDLE_ENTER_MS = 5000;

static_assert(LED_FRAME_BYTES == 1110, "370 LEDs require 1110 RGB bytes");
static_assert(FRAMEBUFFER_ALLOC_BYTES >= LED_FRAME_BYTES, "framebuffer allocation must cover LED bytes");
static_assert(
    18 + 20 + 20 + 20 + 22 + 22 + 22 + 22 + 22 + 22 + 22 + 22 + 22 + 20 + 20 + 20 + 18 + 16 == NUM_LEDS,
    "ROW_LENGTHS must sum to NUM_LEDS");
static_assert(FRAME_PERIOD_US == 33333, "30 FPS frame period must remain 33333 us");
static_assert(POWER_THEORETICAL_MAX_MA == 11700, "DPS L1 theoretical budget drifted");
static_assert(HARDWARE_SUSTAINED_MAX_MA == 10000, "DPS L2 hardware budget drifted");
static_assert(POWER_BUDGET_MA_ABSOLUTE_MAX == 9000, "DPS L3 absolute max budget drifted");
static_assert(POWER_BUDGET_MA_DEFAULT == 8550, "DPS L4 default budget drifted");
static_assert(POWER_BUDGET_MA_ACCEPTANCE_PEAK == 9450, "DPS acceptance peak drifted");

}  // namespace config
}  // namespace rina
