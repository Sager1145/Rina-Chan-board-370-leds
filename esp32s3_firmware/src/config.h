#pragma once
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
constexpr float    BATTERY_CAL_SCALE     = 2.708333f;
constexpr float    BATTERY_CAL_OFFSET_V  = 0.2033f;
constexpr float    CHARGE_CAL_SCALE      = 6.684982f;
constexpr float    CHARGE_CAL_OFFSET_V   = 0.0712f;
constexpr float    BATTERY_EMPTY_V       = 6.2f;
constexpr float    BATTERY_FULL_V        = 8.0f;
constexpr float    BATTERY_UNPOWERED_LOW_V = 5.0f;
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

constexpr uint16_t PACKED_FRAME_BITS       = LED_COUNT;
constexpr uint16_t FRAME_BYTES             = (LED_COUNT + 7) / 8;
static_assert(FRAME_BYTES == 47, "370 LEDs require exactly 47 packed bytes");

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

constexpr uint16_t PACKED_FRAME_MIN_INTERVAL_MS    = 33;
constexpr uint8_t  PACKED_FRAME_QUEUE_DEPTH        = 3;
constexpr uint8_t  PACKED_FRAME_REASON_CHARS       = 64;

constexpr uint32_t DEFAULT_AUTO_INTERVAL_MS      = 3000;
constexpr uint32_t MIN_AUTO_INTERVAL_MS          = 500;
constexpr uint32_t MAX_AUTO_INTERVAL_MS          = 10000;
constexpr uint32_t AUTO_INTERVAL_BUTTON_STEP_MS  = 500;
constexpr uint16_t MAX_AUTO_FACES                = 128;

constexpr uint16_t MAX_SCROLL_FRAMES             = 3072;
constexpr uint16_t MIN_SCROLL_INTERVAL_MS        = 17;  // 60 fps nominal scroll playback.
constexpr uint16_t MAX_SCROLL_INTERVAL_MS        = 1000;
constexpr uint16_t DEFAULT_SCROLL_INTERVAL_MS    = 100;
constexpr uint8_t  SCROLL_DRIFT_RESET_INTERVALS  = 4;

constexpr uint16_t MAX_SCROLL_TEXT_BYTES        = 4096;
constexpr uint8_t  MAX_SCROLL_TIMELINE_ID_CHARS = 47;
constexpr uint8_t  MAX_SCROLL_FONT_ID_CHARS     = 47;
constexpr uint8_t  MAX_SCROLL_GENERATOR_CHARS   = 47;

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

// 中文说明：LED 物理传输后端选择（见 led_driver.cpp）。
//   ADAFRUIT = 历史 Adafruit_NeoPixel 后端，作为默认与安全回退；
//   RMT      = ESP-IDF 5.x 新 RMT TX 驱动，可选 DMA（ESP32-S3 支持）。
// 通过 platformio.ini 的 build_flags 选择，例如 -D RINACHAN_LED_BACKEND=1。
// 三组测试固件：默认(adafruit) / esp32s3-rmt(无DMA) / esp32s3-rmt-dma(DMA)。
#define RINACHAN_LED_BACKEND_ADAFRUIT 0
#define RINACHAN_LED_BACKEND_RMT      1
#ifndef RINACHAN_LED_BACKEND
#define RINACHAN_LED_BACKEND RINACHAN_LED_BACKEND_ADAFRUIT
#endif
// RMT backend tunables (only used when RINACHAN_LED_BACKEND == RMT).
#ifndef RINACHAN_LED_RMT_WITH_DMA
#define RINACHAN_LED_RMT_WITH_DMA 0
#endif
#ifndef RINACHAN_LED_RMT_RESOLUTION_HZ
#define RINACHAN_LED_RMT_RESOLUTION_HZ 10000000  // 10 MHz, per Espressif example
#endif
// 中文：RMT ISR 优先级。驱动只接受 1..3（0=自动）。3 = 抗 Wi-Fi 抖动最好。
#ifndef RINACHAN_LED_RMT_INTR_PRIORITY
#define RINACHAN_LED_RMT_INTR_PRIORITY 3
#endif
#ifndef RINACHAN_LED_RMT_MEM_BLOCK_SYMBOLS
// 中文：DMA 时为 DMA 缓冲符号数。**ESP-IDF 的 RMT DMA 硬上限是 2047，且必须是偶数**
// （驱动报错：mem_block_symbols can't exceed 2047 / must be even and at least 48），
// 所以无法把整帧（370*24=8880 symbol）一次装下——那是 I2S/LCD 才能做的。这里取
// 合法最大值 2046：缓冲越大、一帧内 refill 次数越少、抗 Wi-Fi 抖动越强。
// 配合 IRAM 编码器 + intr_priority=3 + 关 Wi-Fi 省电，实测已不再乱码。
// 非 DMA 时为专用 RMT 内存块大小（偶数、>=48，硬件总量有限），默认 64。
// led_driver 的 begin() 会自动降级重试（2046→1024→…→64），不会黑屏。
#  if RINACHAN_LED_RMT_WITH_DMA
#    define RINACHAN_LED_RMT_MEM_BLOCK_SYMBOLS 2046
#  else
#    define RINACHAN_LED_RMT_MEM_BLOCK_SYMBOLS 64
#  endif
#endif
constexpr uint16_t LED_STOP_CLEAR_BLANK_HOLD_MS  = 90;
constexpr uint16_t LED_BOOT_DATA_LOW_HOLD_MS     = 20;
constexpr uint16_t LED_BOOT_CLEAR_HOLD_MS        = 350;
constexpr uint16_t LED_BOOT_STARTUP_SETTLE_MS    = 120;

constexpr char DEFAULT_COLOR[]          = "#f971d4";
constexpr char DEFAULT_MODE[]           = "manual";
constexpr char DEFAULT_PLAYBACK[]       = "idle";
constexpr char STARTUP_FACE_REASON[]    = "startup_sequence_complete_saved_face";
constexpr char LITTLEFS_BASE_PATH[]     = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
constexpr char SAVED_FACES_PATH[]       = "/resources/saved_faces.json";
constexpr char SETTINGS_PATH[]          = "/resources/runtime_settings.json";

#ifndef RINACHAN_VERBOSE_LOGS
#define RINACHAN_VERBOSE_LOGS 0
#endif

#if RINACHAN_VERBOSE_LOGS
#define LOGV(...) Serial.printf(__VA_ARGS__)
#else
#define LOGV(...) do {} while (0)
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
#error "ENABLE_SERIAL_UART0_MIRROR requires ARDUINO_USB_CDC_ON_BOOT=1"
#endif

constexpr char FIRMWARE_NAME[]    = "RinaChanBoard-V2";
constexpr char FIRMWARE_VERSION[] = "packed-frame-protocol-1.1";
