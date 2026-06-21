#include "button_animations.h"
#include "faces.h"
#include "led_renderer.h"
#include "power_monitor.h"
#include "state.h"
#include "sync.h"
#include "utils.h"
#include "scroll_session.h"
#include "serial_log.h"

#include <math.h>
#include <string.h>

namespace {

constexpr uint8_t COLS = 22;
constexpr uint8_t ROWS = 18;

constexpr uint32_t FLASH_HOLD_MS = 1000;
constexpr uint32_t EDGE_FLASH_MS = 305;
constexpr uint32_t EDGE_ATTACK_MS = 45;
constexpr uint32_t EDGE_DECAY_MS = 260;
constexpr uint32_t BATTERY_SHORT_HOLD_MS = 2000;
constexpr uint32_t BATTERY_LONG_PRESS_MS = 700;
constexpr uint32_t BATTERY_PHASE_MS = 2000;
constexpr uint32_t BATTERY_REFRESH_MS = 100;
constexpr uint32_t BATTERY_ANIM_REFRESH_MS = 50;

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr Rgb MODE_COLOR = {180, 0, 255};
constexpr Rgb BRIGHTNESS_COLOR = {0, 120, 255};
constexpr Rgb EDGE_COLOR = {0, 120, 255};
constexpr Rgb WHITE_COLOR = {255, 255, 255};
constexpr Rgb RED_COLOR = {255, 0, 0};

enum class OverlayKind : uint8_t {
    None,
    Mode,
    Interval,
    Brightness,
    Battery,
};

enum class EdgeKind : uint8_t {
    None,
    Top,
    Bottom,
};

struct AnimationState {
    bool active = false;
    OverlayKind kind = OverlayKind::None;
    uint32_t startedMs = 0;
    uint32_t expiresMs = 0;
    uint32_t nextRenderMs = 0;

    bool modeAuto = false;
    uint32_t intervalMs = DEFAULT_AUTO_INTERVAL_MS;
    uint8_t brightnessRaw = DEFAULT_BRIGHTNESS;

    EdgeKind edge = EdgeKind::None;
    bool edgeUsesModeColor = false;
    uint32_t edgeStartedMs = 0;

    bool pausedScroll = false;

    bool b6Pressed = false;
    bool b6LongFired = false;
    uint32_t b6PressedAtMs = 0;

    bool batValid = false;
    bool batCharging = false;
    uint8_t batPercent = 0;
    float batVbat = NAN;
    float batVcharge = NAN;

    bool batterySingleShot = true;
    uint8_t batteryPhaseIndex = 0;
    uint8_t batteryPhaseCount = 1;
    uint32_t batteryNextPhaseMs = 0;
    uint32_t batteryDisplayStartedMs = 0;
};

portMUX_TYPE sAnimMux = portMUX_INITIALIZER_UNLOCKED;
AnimationState sAnim;

const char* const GLYPH_0[] = {".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."};
const char* const GLYPH_1[] = {".##..", "#.#..", "..#..", "..#..", "..#..", "..#..", "#####"};
const char* const GLYPH_2[] = {".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"};
const char* const GLYPH_3[] = {"####.", "....#", "....#", ".###.", "....#", "....#", "####."};
const char* const GLYPH_4[] = {"...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."};
const char* const GLYPH_5[] = {"#####", "#....", "####.", "....#", "....#", "#...#", ".###."};
const char* const GLYPH_6[] = {".###.", "#...#", "#....", "####.", "#...#", "#...#", ".###."};
const char* const GLYPH_7[] = {"#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."};
const char* const GLYPH_8[] = {".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."};
const char* const GLYPH_9[] = {".###.", "#...#", "#...#", ".####", "....#", "#...#", ".###."};
const char* const GLYPH_S[] = {".####", "#....", "#....", ".###.", "....#", "....#", "####."};
const char* const GLYPH_V[] = {"#...#", "#...#", "#...#", ".#.#.", ".#.#.", "..#..", "..#.."};
const char* const GLYPH_DOT[] = {".", ".", ".", ".", ".", ".", "#"};
const char* const GLYPH_PCT[] = {"#.#", "..#", ".#.", ".#.", "#..", "#.#", "..."};

const char* const BIG_A[] = {
    "...####...",
    "..######..",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".########.",
    ".########.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
};

const char* const BIG_M[] = {
    "##......##",
    "###....###",
    "####..####",
    "##.####.##",
    "##..##..##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
};

const char* const CLOCK_ICON[] = {
    "......................",
    ".........####.........",
    "........#...##........",
    "........#..#.#........",
    "........#....#........",
    "........#....#........",
    ".........####.........",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
};

const char* const SUN_ICON[] = {
    "......................",
    ".......#......#.##....",
    "....##.#......#.......",
    "........#....#........",
    ".........####..#......",
    ".......#........#.....",
    "......#....#..........",
    "...........#..........",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
};

const char* const BATTERY_ICON[] = {
    "......................",
    "......#########.......",
    "......#........#......",
    "......#........#......",
    "......#........#......",
    "......#########.......",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
};

struct Glyph {
    const char* const* rows;
    uint8_t width;
};

Glyph glyphFor(char ch) {
    switch (ch) {
    case '0':
        return {GLYPH_0, 5};
    case '1':
        return {GLYPH_1, 5};
    case '2':
        return {GLYPH_2, 5};
    case '3':
        return {GLYPH_3, 5};
    case '4':
        return {GLYPH_4, 5};
    case '5':
        return {GLYPH_5, 5};
    case '6':
        return {GLYPH_6, 5};
    case '7':
        return {GLYPH_7, 5};
    case '8':
        return {GLYPH_8, 5};
    case '9':
        return {GLYPH_9, 5};
    case 'S':
        return {GLYPH_S, 5};
    case 'V':
        return {GLYPH_V, 5};
    case '.':
        return {GLYPH_DOT, 1};
    case '%':
        return {GLYPH_PCT, 3};
    default:
        return {nullptr, 0};
    }
}

bool overlayExpired(const AnimationState& state, uint32_t now) {
    if (!state.active || state.expiresMs == 0)
        return false;
    if (state.kind == OverlayKind::Battery && !state.batterySingleShot)
        return false;
    return millisReached(now, state.expiresMs);
}

int16_t xyToLogical(uint8_t x, uint8_t y) {
    if (x >= COLS || y >= ROWS)
        return -1;
    const uint8_t rowLength = ROW_LENGTHS[y];
    const uint8_t leftPad = (COLS - rowLength) / 2;
    if (x < leftPad || x >= leftPad + rowLength)
        return -1;
    return static_cast<int16_t>(ROW_OFFSETS[y] + (x - leftPad));
}

void putPixel(uint8_t* out, uint8_t x, uint8_t y, Rgb color) {
    const int16_t logical = xyToLogical(x, y);
    if (logical < 0)
        return;
    const uint16_t offset = static_cast<uint16_t>(logical) * 3U;
    out[offset] = color.r;
    out[offset + 1] = color.g;
    out[offset + 2] = color.b;
}

void clearOverlay(uint8_t* out) {
    memset(out, 0, static_cast<size_t>(LED_COUNT) * 3U);
}

void drawBitmap(uint8_t* out, const char* const* rows, uint8_t width, uint8_t height,
                int8_t x0, int8_t y0, Rgb color) {
    if (!rows)
        return;
    for (uint8_t y = 0; y < height; ++y) {
        for (uint8_t x = 0; x < width; ++x) {
            if (rows[y][x] == '#') {
                const int16_t px = static_cast<int16_t>(x0) + x;
                const int16_t py = static_cast<int16_t>(y0) + y;
                if (px >= 0 && py >= 0 && px < COLS && py < ROWS) {
                    putPixel(out, static_cast<uint8_t>(px), static_cast<uint8_t>(py), color);
                }
            }
        }
    }
}

void drawText(uint8_t* out, const char* text, Rgb color, bool hasIcon, bool voltageLayout = false) {
    constexpr uint8_t GAP = 1;
    constexpr uint8_t MAX_TEXT_GLYPHS = 8; // 说明 按钮反馈、电量提示和网络信息 overlay 中当前代码块的职责和维护约束。

    uint8_t len = 0;
    uint8_t totalW = 0;
    for (; len < MAX_TEXT_GLYPHS && text[len] != '\0'; ++len) {
        if (len > 0)
            totalW += GAP;
        totalW += glyphFor(text[len]).width;
    }
    if (len == 0 || totalW > COLS)
        return;

    int8_t x0 = static_cast<int8_t>((COLS - totalW) / 2);
    const int8_t y0 = hasIcon ? 9 : 5;

    for (uint8_t i = 0; i < len; ++i) {
        const Glyph g = glyphFor(text[i]);
        if (g.rows && g.width > 0)
            drawBitmap(out, g.rows, g.width, 7, x0, y0, color);
        x0 += g.width + GAP;
        if (voltageLayout && i == 2)
            ++x0;
    }
}

void drawIconText(uint8_t* out, const char* text, Rgb color, const char* const* iconRows,
                  bool voltageLayout = false, Rgb textColor = {0, 0, 0}, bool useTextColor = false) {
    clearOverlay(out);
    if (iconRows)
        drawBitmap(out, iconRows, COLS, ROWS, 0, 0, color);
    drawText(out, text, useTextColor ? textColor : color, iconRows != nullptr, voltageLayout);
}

uint8_t brightnessPercent(uint8_t raw) {
    const uint8_t clamped = min<uint8_t>(raw, MAX_BRIGHTNESS);
    return static_cast<uint8_t>(lroundf((static_cast<float>(clamped) * 100.0f) /
                                        static_cast<float>(MAX_BRIGHTNESS)));
}

void formatInterval(uint32_t intervalMs, char* out, size_t outSize) {
    const uint16_t tenths = static_cast<uint16_t>((intervalMs + 50U) / 100U);
    const uint16_t whole = tenths / 10U;
    const uint16_t frac = tenths % 10U;
    if (whole == 10 && frac == 0)
        snprintf(out, outSize, "10S");
    else
        snprintf(out, outSize, "%u.%uS", whole, frac);
}

Rgb batteryColor(uint8_t percent) {
    const uint8_t p = min<uint8_t>(percent, 100);
    if (p <= 10)
        return RED_COLOR;
    if (p <= 30) {
        const float t = (static_cast<float>(p) - 10.0f) / 20.0f;
        return {255, static_cast<uint8_t>(165.0f * t), 0};
    }
    if (p <= 50) {
        const float t = (static_cast<float>(p) - 30.0f) / 20.0f;
        return {
            static_cast<uint8_t>(255.0f * (1.0f - t)),
            static_cast<uint8_t>(165.0f + (90.0f * t)),
            0,
        };
    }
    return {0, 255, 0};
}

uint8_t batteryFillCols(uint8_t percent) {
    const uint8_t p = min<uint8_t>(percent, 100);
    if (p < 10)
        return 0;
    if (p > 90)
        return 8;
    return static_cast<uint8_t>(((static_cast<uint16_t>(p) - 10U) * 8U + 79U) / 80U);
}

void drawBatteryIcon(uint8_t* out, Rgb color, uint8_t percent, bool animate, uint32_t phaseMs) {
    drawBitmap(out, BATTERY_ICON, COLS, ROWS, 0, 0, color);

    uint8_t cols = batteryFillCols(percent);
    if (animate) {
        if (percent < 10) {
            cols = ((phaseMs / 300U) % 2U) == 0 ? 1 : 0;
        } else {
            const uint8_t target = percent > 90 ? 8 : max<uint8_t>(1, batteryFillCols(percent));
            cols = static_cast<uint8_t>(((phaseMs / 200U) % target) + 1U);
        }
    }

    for (uint8_t x = 0; x < cols; ++x) {
        for (uint8_t y = 2; y <= 4; ++y) {
            putPixel(out, static_cast<uint8_t>(7 + x), y, color);
        }
    }
}

void drawBatteryPage(uint8_t* out, const AnimationState& state, uint32_t now) {
    clearOverlay(out);

    const bool batteryValid = state.batValid;
    const uint8_t pct = batteryValid ? state.batPercent : 0;
    const bool charging = state.batCharging;
    const Rgb iconColor = batteryValid ? batteryColor(pct) : RED_COLOR;
    const bool animate = !state.batterySingleShot && charging;
    const uint32_t phaseMs = now - state.batteryDisplayStartedMs;

    drawBatteryIcon(out, iconColor, pct, animate, phaseMs);

    char text[8] = {};
    if (state.batteryPhaseIndex == 1) {
        const float v = batteryValid && isfinite(state.batVbat) ? state.batVbat : 0.0f;
        snprintf(text, sizeof(text), "%.1fV", static_cast<double>(v));
        drawText(out, text, iconColor, true, true);
    } else if (state.batteryPhaseIndex == 2) {
        const float v = state.batCharging && isfinite(state.batVcharge) ? state.batVcharge : 0.0f;
        snprintf(text, sizeof(text), "%.1f", static_cast<double>(v));
        drawText(out, text, WHITE_COLOR, true);
    } else {
        snprintf(text, sizeof(text), "%u%%", pct);
        drawText(out, text, iconColor, true);
    }
}

void overlayEdgeFlash(uint8_t* out, const AnimationState& state, uint32_t now) {
    if (state.edge == EdgeKind::None)
        return;
    const uint32_t elapsed = now - state.edgeStartedMs;
    if (elapsed > EDGE_FLASH_MS)
        return;

    float factor = 0.0f;
    if (elapsed <= EDGE_ATTACK_MS) {
        factor = static_cast<float>(elapsed) / static_cast<float>(EDGE_ATTACK_MS);
    } else {
        const float t = static_cast<float>(elapsed - EDGE_ATTACK_MS) / static_cast<float>(EDGE_DECAY_MS);
        factor = max(0.0f, 1.0f - t);
    }

    const Rgb base = state.edgeUsesModeColor ? MODE_COLOR : EDGE_COLOR;
    const uint8_t y = state.edge == EdgeKind::Top ? 0 : ROWS - 1;
    for (uint8_t x = 0; x < COLS; ++x) {
        const float dist = fabsf(static_cast<float>(x) - 10.5f);
        const float spatial = max(0.20f, 1.0f - (dist / 10.5f));
        const float level = factor * spatial;
        putPixel(out, x, y, {
                                static_cast<uint8_t>(static_cast<float>(base.r) * level),
                                static_cast<uint8_t>(static_cast<float>(base.g) * level),
                                static_cast<uint8_t>(static_cast<float>(base.b) * level),
                            });
    }
}

void pauseScrollForOverlay() {
    if (sAnim.pausedScroll)
        return;

    bool shouldPause = false;
    withScrollLock([&]() {
        shouldPause = (runtimeState().firmwareScrollActive ||
                       runtimeState().firmwareScrollPaused) &&
                      !runtimeState().firmwareScrollSystemPaused &&
                      runtimeState().scrollFrameCount > 0;
    });
    if (shouldPause && scrollSessionSetSystemPaused(true)) {
        sAnim.pausedScroll = true;
    }
}

void resumeScrollAfterOverlayIfNeeded() {
    bool resume = false;
    portENTER_CRITICAL(&sAnimMux);
    resume = sAnim.pausedScroll;
    sAnim.pausedScroll = false;
    portEXIT_CRITICAL(&sAnimMux);

    if (!resume)
        return;

    scrollSessionSetSystemPaused(false);
}

void stopOverlay(bool requestRender) {
    bool wasActive = false;
    portENTER_CRITICAL(&sAnimMux);
    wasActive = sAnim.active;
    sAnim.active = false;
    sAnim.kind = OverlayKind::None;
    sAnim.expiresMs = 0;
    sAnim.edge = EdgeKind::None;
    sAnim.batterySingleShot = true;
    sAnim.batteryPhaseIndex = 0;
    sAnim.batteryPhaseCount = 1;
    sAnim.batteryNextPhaseMs = 0;
    portEXIT_CRITICAL(&sAnimMux);

    if (wasActive) {
        resumeScrollAfterOverlayIfNeeded();
        if (requestRender)
            requestLedRender();
    }
}

void startOverlay(const AnimationState& next) {
    portENTER_CRITICAL(&sAnimMux);
    sAnim.active = true;
    sAnim.kind = next.kind;
    sAnim.startedMs = next.startedMs;
    sAnim.expiresMs = next.expiresMs;
    sAnim.nextRenderMs = next.nextRenderMs;
    sAnim.modeAuto = next.modeAuto;
    sAnim.intervalMs = next.intervalMs;
    sAnim.brightnessRaw = next.brightnessRaw;
    sAnim.edge = next.edge;
    sAnim.edgeUsesModeColor = next.edgeUsesModeColor;
    sAnim.edgeStartedMs = next.edgeStartedMs;
    sAnim.batterySingleShot = next.batterySingleShot;
    sAnim.batteryPhaseIndex = next.batteryPhaseIndex;
    sAnim.batteryPhaseCount = next.batteryPhaseCount;
    sAnim.batteryNextPhaseMs = next.batteryNextPhaseMs;
    sAnim.batteryDisplayStartedMs = next.batteryDisplayStartedMs;
    portEXIT_CRITICAL(&sAnimMux);

    pauseScrollForOverlay();
    requestLedRender();
}

void startBatteryOverlay(bool singleShot) {
    const uint32_t now = millis();
    const PowerStatus power = readPowerStatusSnapshot();
    AnimationState next;
    next.kind = OverlayKind::Battery;
    next.startedMs = now;
    next.expiresMs = singleShot ? now + BATTERY_SHORT_HOLD_MS : 0;
    next.nextRenderMs = now + BATTERY_REFRESH_MS;
    next.batterySingleShot = singleShot;
    next.batteryPhaseIndex = 0;
    next.batteryPhaseCount = (!singleShot && power.chargeValid && power.charging) ? 3 : 2;
    next.batteryNextPhaseMs = singleShot ? 0 : now + BATTERY_PHASE_MS;
    next.batteryDisplayStartedMs = now;
    next.batValid = power.batteryValid;
    next.batCharging = power.chargeValid && power.charging;
    next.batPercent = power.batteryPercent;
    next.batVbat = power.vbat;
    next.batVcharge = power.vcharge;
    startOverlay(next);
}

} // 说明 按钮反馈、电量提示和网络信息 overlay 中当前代码块的职责和维护约束。

void showBatteryOverlay(bool singleShot) {
    RLOG_INFO("LED", "event=battery_display action=B6 singleShot=%d", singleShot ? 1 : 0);
    startBatteryOverlay(singleShot);
}

void startButtonAnimationForGpioAction(const String& buttonCode) {
    String code = buttonCode;
    code.trim();
    code.toUpperCase();

    const uint32_t now = millis();
    AnimationState next;
    next.startedMs = now;
    next.expiresMs = now + FLASH_HOLD_MS;
    next.nextRenderMs = now + 33;

    if (code == "B3") {
        next.kind = OverlayKind::Mode;
        next.modeAuto = isAutoMode();
    } else if (code == "B3B1" || code == "B3B2") {
        next.kind = OverlayKind::Interval;
        next.intervalMs = runtimeState().autoIntervalMs;
        if ((code == "B3B1" && runtimeState().autoIntervalMs <= MIN_AUTO_INTERVAL_MS) ||
            (code == "B3B2" && runtimeState().autoIntervalMs >= MAX_AUTO_INTERVAL_MS)) {
            next.edge = code == "B3B1" ? EdgeKind::Bottom : EdgeKind::Top;
            next.edgeUsesModeColor = true;
            next.edgeStartedMs = now;
        }
    } else if (code == "B4" || code == "B5") {
        next.kind = OverlayKind::Brightness;
        next.brightnessRaw = runtimeState().brightness;
        if ((code == "B4" && runtimeState().brightness <= MIN_BRIGHTNESS) ||
            (code == "B5" && runtimeState().brightness >= MAX_BRIGHTNESS)) {
            next.edge = code == "B4" ? EdgeKind::Bottom : EdgeKind::Top;
            next.edgeUsesModeColor = false;
            next.edgeStartedMs = now;
        }
    } else {
        return;
    }

    startOverlay(next);
}

void handleButtonAnimationGpioPress(const char* buttonCode) {
    if (!buttonCode || strcmp(buttonCode, "B6") != 0)
        return;
    const uint32_t now = millis();
    portENTER_CRITICAL(&sAnimMux);
    sAnim.b6Pressed = true;
    sAnim.b6LongFired = false;
    sAnim.b6PressedAtMs = now;
    portEXIT_CRITICAL(&sAnimMux);
}

void handleButtonAnimationGpioRelease(const char* buttonCode) {
    if (!buttonCode || strcmp(buttonCode, "B6") != 0)
        return;

    bool longFired = false;
    portENTER_CRITICAL(&sAnimMux);
    longFired = sAnim.b6LongFired;
    sAnim.b6Pressed = false;
    sAnim.b6LongFired = false;
    sAnim.b6PressedAtMs = 0;
    portEXIT_CRITICAL(&sAnimMux);

    if (longFired)
        stopOverlay(true);
    else
        startBatteryOverlay(true);
}

void serviceButtonAnimationButtonInputs(bool b6Pressed, bool b2Pressed, bool b3Pressed) {
    bool shouldStartLong = false;
    const uint32_t now = millis();

    portENTER_CRITICAL(&sAnimMux);
    if (sAnim.b6Pressed && b6Pressed && !sAnim.b6LongFired &&
        !b2Pressed && !b3Pressed && now - sAnim.b6PressedAtMs >= BATTERY_LONG_PRESS_MS) {
        sAnim.b6LongFired = true;
        shouldStartLong = true;
    }
    if (!b6Pressed)
        sAnim.b6Pressed = false;
    portEXIT_CRITICAL(&sAnimMux);

    if (shouldStartLong)
        startBatteryOverlay(false);
}

void serviceButtonAnimations() {
    const uint32_t now = millis();
    bool request = false;
    bool stop = false;

    // Snapshot power state OUTSIDE sAnimMux. readPowerStatusSnapshot() takes its
    // own spinlock and copies a ~120-byte struct; calling it while holding
    // sAnimMux would nest spinlocks and extend the interrupts-disabled window on
    // the WiFi/HTTP core (audit M1). serviceButtonAnimations() runs only on
    // Core 0's cooperative loop, so sAnim cannot be mutated between these two
    // critical sections.
    bool needPower = false;
    portENTER_CRITICAL(&sAnimMux);
    needPower = sAnim.active && sAnim.kind == OverlayKind::Battery && !sAnim.batterySingleShot;
    portEXIT_CRITICAL(&sAnimMux);

    PowerStatus power;
    if (needPower)
        power = readPowerStatusSnapshot();

    portENTER_CRITICAL(&sAnimMux);
    if (sAnim.active) {
        if (overlayExpired(sAnim, now)) {
            stop = true;
        } else if (sAnim.kind == OverlayKind::Battery && !sAnim.batterySingleShot) {
            sAnim.batValid = power.batteryValid;
            sAnim.batCharging = power.chargeValid && power.charging;
            sAnim.batPercent = power.batteryPercent;
            sAnim.batVbat = power.vbat;
            sAnim.batVcharge = power.vcharge;
            if (sAnim.batteryNextPhaseMs != 0 && millisReached(now, sAnim.batteryNextPhaseMs)) {
                const uint8_t targetCount = sAnim.batCharging ? 3 : 2;
                sAnim.batteryPhaseCount = targetCount;
                sAnim.batteryPhaseIndex = static_cast<uint8_t>((sAnim.batteryPhaseIndex + 1U) % targetCount);
                sAnim.batteryNextPhaseMs = now + BATTERY_PHASE_MS;
                request = true;
            }
            if (millisReached(now, sAnim.nextRenderMs)) {
                sAnim.nextRenderMs = now + (sAnim.batCharging
                                                ? BATTERY_ANIM_REFRESH_MS
                                                : BATTERY_REFRESH_MS);
                request = true;
            }
        } else if (sAnim.kind == OverlayKind::Battery) {
            if (millisReached(now, sAnim.nextRenderMs)) {
                sAnim.nextRenderMs = now + BATTERY_REFRESH_MS;
                request = true;
            }
        } else if (sAnim.edge != EdgeKind::None && now - sAnim.edgeStartedMs <= EDGE_FLASH_MS &&
                   millisReached(now, sAnim.nextRenderMs)) {
            sAnim.nextRenderMs = now + 33;
            request = true;
        }
    }
    portEXIT_CRITICAL(&sAnimMux);

    if (stop)
        stopOverlay(true);
    else if (request)
        requestLedRender();
}

bool copyButtonAnimationOverlay(uint8_t* rgbOut, uint16_t ledCount) {
    if (!rgbOut || ledCount < LED_COUNT)
        return false;

    AnimationState state;
    const uint32_t now = millis();
    portENTER_CRITICAL(&sAnimMux);
    state = sAnim;
    portEXIT_CRITICAL(&sAnimMux);

    if (!state.active)
        return false;
    if (overlayExpired(state, now))
        return false;

    if (state.kind == OverlayKind::Mode) {
        clearOverlay(rgbOut);
        drawBitmap(rgbOut, state.modeAuto ? BIG_A : BIG_M, 10, 13, 6, 2, MODE_COLOR);
    } else if (state.kind == OverlayKind::Interval) {
        char text[8] = {};
        formatInterval(state.intervalMs, text, sizeof(text));
        drawIconText(rgbOut, text, MODE_COLOR, CLOCK_ICON);
        overlayEdgeFlash(rgbOut, state, now);
    } else if (state.kind == OverlayKind::Brightness) {
        char text[8] = {};
        snprintf(text, sizeof(text), "%u%%", brightnessPercent(state.brightnessRaw));
        drawIconText(rgbOut, text, BRIGHTNESS_COLOR, SUN_ICON);
        overlayEdgeFlash(rgbOut, state, now);
    } else if (state.kind == OverlayKind::Battery) {
        drawBatteryPage(rgbOut, state, now);
    } else {
        return false;
    }

    return true;
}
