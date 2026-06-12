#pragma once
#include <Arduino.h>


// 本文件集中声明硬件引脚、LED 矩阵、时序和默认运行参数；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 硬件（Hardware） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
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

// ---------------------------------------------------------------------------
// 电源监测 ADC（Power monitor ADC） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint8_t  BATTERY_ADC_PIN       = 10;
constexpr uint8_t  CHARGE_ADC_PIN        = 1;
constexpr float    BATTERY_DIVIDER_R1_K  = 100.0f;
constexpr float    BATTERY_DIVIDER_R2_K  = 57.0f;
constexpr float    CHARGE_DIVIDER_R1_K   = 270.0f;
constexpr float    CHARGE_DIVIDER_R2_K   = 47.0f;
constexpr float    BATTERY_CAL_SCALE     = 2.708333f;  // 说明电源、电池、充电或 ADC 校准相关逻辑。
constexpr float    BATTERY_CAL_OFFSET_V  = 0.2033f;    // 说明 硬件、矩阵和时序配置 中当前代码块的职责和维护约束。
constexpr float    CHARGE_CAL_SCALE      = 6.684982f;  // 说明电源、电池、充电或 ADC 校准相关逻辑。
constexpr float    CHARGE_CAL_OFFSET_V   = 0.0712f;    // 说明 硬件、矩阵和时序配置 中当前代码块的职责和维护约束。
constexpr float    BATTERY_EMPTY_V       = 6.2f;
constexpr float    BATTERY_FULL_V        = 8.0f;
constexpr float    BATTERY_UNPOWERED_LOW_V = 5.0f;  // 说明电源、电池、充电或 ADC 校准相关逻辑。
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

// ---------------------------------------------------------------------------
// 电池电量百分比查找表（Battery percentage look-up table，2S LiPo 分段线性放电曲线） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
// 每个条目为 { real-world voltage at the battery terminals (V), percent }，即 { 电池端子处的实际电压（V），百分比 }。 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
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

// ---------------------------------------------------------------------------
// LED 矩阵几何布局（LED matrix geometry） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// 亮度（Brightness） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint8_t  DEFAULT_BRIGHTNESS    = 50;
constexpr uint8_t  MIN_BRIGHTNESS        = 10;
constexpr uint8_t  MAX_BRIGHTNESS        = 200;
constexpr int8_t   BRIGHTNESS_BUTTON_STEP = 8;

// ---------------------------------------------------------------------------
// 实时帧率限制（Realtime frame rate limits） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint16_t M370_FRAME_MIN_INTERVAL_MS    = 33;
constexpr uint8_t  M370_FRAME_QUEUE_DEPTH        = 3;
constexpr uint8_t  M370_FRAME_REASON_CHARS       = 64;

// ---------------------------------------------------------------------------
// 自动播放（Auto-playback） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint32_t DEFAULT_AUTO_INTERVAL_MS      = 3000;
constexpr uint32_t MIN_AUTO_INTERVAL_MS          = 500;
constexpr uint32_t MAX_AUTO_INTERVAL_MS          = 10000;
constexpr uint32_t AUTO_INTERVAL_BUTTON_STEP_MS  = 500;
constexpr uint16_t MAX_AUTO_FACES                = 128;

// ---------------------------------------------------------------------------
// 滚动（Scroll） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint16_t MAX_SCROLL_FRAMES             = 3072;
constexpr uint16_t MIN_SCROLL_INTERVAL_MS        = M370_FRAME_MIN_INTERVAL_MS;
constexpr uint16_t MAX_SCROLL_INTERVAL_MS        = 1000;
constexpr uint16_t DEFAULT_SCROLL_INTERVAL_MS    = 100;
constexpr uint8_t  SCROLL_DRIFT_RESET_INTERVALS  = 4;

// 文字滚动源文本同步（Scroll source-text sync）：上传携带的 Unicode 源文本与
// 元数据的硬限制。文本上限按 UTF-8 字节计，无 code-point 上限。
constexpr uint16_t MAX_SCROLL_TEXT_BYTES        = 4096;
constexpr uint8_t  MAX_SCROLL_TIMELINE_ID_CHARS = 47;
constexpr uint8_t  MAX_SCROLL_FONT_ID_CHARS     = 47;
constexpr uint8_t  MAX_SCROLL_GENERATOR_CHARS   = 47;

// ---------------------------------------------------------------------------
// 按钮去抖 / 重复（Button debounce / repeat） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint32_t BUTTON_DEBOUNCE_MS            = 25;
constexpr uint32_t FACE_REPEAT_DELAY_MS          = 650;
constexpr uint32_t FACE_REPEAT_MS                = 350;
constexpr uint32_t BRIGHTNESS_REPEAT_DELAY_MS    = 450;
constexpr uint32_t BRIGHTNESS_REPEAT_MS          = 120;

// ---------------------------------------------------------------------------
// LED 渲染任务（LED render task，FreeRTOS） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint8_t  LED_RENDER_TASK_CORE          = 1;
constexpr uint32_t LED_RENDER_TASK_STACK_BYTES   = 6144;
constexpr uint8_t  LED_RENDER_TASK_PRIORITY      = 3;

// ---------------------------------------------------------------------------
// LED 时序（LED timing，考虑 BSS138 电平转换器） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
// 在每次 strip.show() 调用前后插入的拉低空闲窗口（Idle-low window inserted before and after each strip.show() call）。 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
constexpr uint16_t LED_SIGNAL_RESET_US           = 300;

constexpr uint16_t LED_RENDER_MIN_GAP_US         = 2500;

// ---------------------------------------------------------------------------
// 启动 / 停止清屏时序（Boot / stop-clear timing） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr uint16_t LED_STOP_CLEAR_BLANK_HOLD_MS    = 90;
constexpr uint16_t LED_BOOT_DATA_LOW_HOLD_MS        = 20;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS           = 350;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS       = 120;

// ---------------------------------------------------------------------------
// 默认值 / 字符串常量（Defaults / string constants） 相关代码，维护 集中声明硬件引脚、LED 矩阵、时序和默认运行参数。
// ---------------------------------------------------------------------------
constexpr char DEFAULT_COLOR[]          = "#f971d4";
constexpr char DEFAULT_MODE[]           = "manual";
constexpr char DEFAULT_PLAYBACK[]       = "idle";
constexpr char STARTUP_FACE_REASON[]    = "startup_sequence_complete_saved_face";
constexpr char LITTLEFS_BASE_PATH[]     = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
constexpr char SAVED_FACES_PATH[]       = "/resources/saved_faces.json";
constexpr char SETTINGS_PATH[]          = "/resources/runtime_settings.json";
