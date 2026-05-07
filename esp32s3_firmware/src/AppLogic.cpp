#include "AppLogic.h"

#include <cstring>

#include <Arduino.h>

namespace rina {
namespace {

constexpr uint8_t kOverlayEdge = 1U << 0;
constexpr uint8_t kOverlayBattery = 1U << 1;
constexpr uint32_t kDefaultRntHoldMs = config::FRAME_PERIOD_US / 1000UL;

uint8_t clampByte(uint32_t value) {
    return value > 255U ? 255U : static_cast<uint8_t>(value);
}

bool startsWith(const char* line, size_t len, const char* prefix) {
    size_t i = 0;
    while (prefix[i] != '\0') {
        if (i >= len || line[i] != prefix[i]) {
            return false;
        }
        ++i;
    }
    return true;
}

}  // namespace

AppLogic::AppLogic()
    : display_(nullptr),
      assets_(nullptr),
      hardware_(nullptr),
      network_(nullptr),
      baseFrame_{},
      composedFrame_{},
      rntReader_(),
      settings_(),
      stats_(),
      mode_(AppMode::Manual),
      begun_(false),
      renderRequested_(false),
      rntLoop_(false),
      rntPath_{},
      lastAutoAdvanceMs_(0),
      nextRntDueMs_(0),
      edgeFlashStartedMs_(0),
      edgeFlashUntilMs_(0),
      batteryOverlayUntilMs_(0) {
}

bool AppLogic::begin(
    DisplayEngine& display,
    AssetManager& assets,
    HardwareMonitor& hardware,
    NetworkManager& network) {
    display_ = &display;
    assets_ = &assets;
    hardware_ = &hardware;
    network_ = &network;

    settings_ = assets.settings();
    mode_ = settings_.autoMode ? AppMode::Auto : AppMode::Manual;
    baseFrame_.fill(0);
    composedFrame_.fill(0);

    display_->setDemoMode(false);
    display_->setBrightnessPct(settings_.brightnessPct);
    display_->setPowerBudgetMa(settings_.powerBudgetMa);

    begun_ = true;
    renderRequested_ = true;
    drawBuiltInFace(settings_.faceIndex, millis());
    composeAndSubmit(millis());
    updateStatsState();
    return true;
}

void AppLogic::tick() {
    if (!begun_) {
        return;
    }

    const uint32_t nowMs = millis();
    ++stats_.tickCount;

    pollNetworkQueue();
    pollHardwareQueue();
    serviceRnt(nowMs);
    serviceAutoMode(nowMs);

    const uint8_t overlays = activeOverlayMask(nowMs);
    if (renderRequested_ || overlays != 0 || stats_.activeOverlays != overlays) {
        composeAndSubmit(nowMs);
    }

    updateStatsState();
}

bool AppLogic::startRnt(const char* path, bool loop) {
    if (!begun_ || path == nullptr || path[0] == '\0') {
        return false;
    }

    stopRnt();

    const size_t len = strnlen(path, sizeof(rntPath_) - 1U);
    memcpy(rntPath_, path, len);
    rntPath_[len] = '\0';

    if (!rntReader_.open(rntPath_)) {
        rntPath_[0] = '\0';
        return false;
    }

    rntLoop_ = loop;
    mode_ = AppMode::Rnt;
    nextRntDueMs_ = 0;
    renderRequested_ = true;
    updateStatsState();
    return true;
}

void AppLogic::stopRnt() {
    rntReader_.close();
    rntLoop_ = false;
    nextRntDueMs_ = 0;
    if (mode_ == AppMode::Rnt) {
        mode_ = settings_.autoMode ? AppMode::Auto : AppMode::Manual;
    }
    updateStatsState();
}

NetworkRuntimeSnapshot AppLogic::networkSnapshot() const {
    NetworkRuntimeSnapshot snapshot;
    if (assets_ != nullptr) {
        const auto settings = assets_->settings();
        snapshot.brightnessPct = settings.brightnessPct;
        snapshot.brightnessCap = settings.brightnessCap;
        snapshot.faceIndex = settings.faceIndex;
        snapshot.powerBudgetMa = settings.powerBudgetMa;
    }
    if (display_ != nullptr) {
        const auto& displayStats = display_->stats();
        snapshot.displayFrames = displayStats.frameCounter;
        snapshot.displayDropped = displayStats.droppedFrameCount;
    }
    if (hardware_ != nullptr) {
        snapshot.batteryMv = hardware_->batteryMilliVolts();
        snapshot.chargeMv = hardware_->chargeMilliVolts();
    }
    if (assets_ != nullptr) {
        snapshot.settingsDirty = assets_->stats().settingsDirty;
    }
    return snapshot;
}

AppLogicStats AppLogic::stats() const {
    return stats_;
}

const char* AppLogic::modeName(AppMode mode) {
    switch (mode) {
        case AppMode::Manual:
            return "manual";
        case AppMode::Auto:
            return "auto";
        case AppMode::Rnt:
            return "rnt";
        default:
            return "unknown";
    }
}

uint32_t AppLogic::parseUnsigned(const char* text, size_t len, uint32_t fallback) {
    if (text == nullptr || len == 0) {
        return fallback;
    }

    uint32_t value = 0;
    for (size_t i = 0; i < len; ++i) {
        if (text[i] < '0' || text[i] > '9') {
            return fallback;
        }
        value = (value * 10U) + static_cast<uint32_t>(text[i] - '0');
    }
    return value;
}

void AppLogic::pollNetworkQueue() {
    if (network_ == nullptr) {
        return;
    }

    protocol::Command command;
    uint8_t drained = 0;
    while (drained < config::UDP_BURST_LIMIT && network_->pollCommand(command)) {
        ++drained;
        handleNetworkCommand(command);
    }
}

void AppLogic::pollHardwareQueue() {
    if (hardware_ == nullptr) {
        return;
    }

    ButtonEvent event;
    while (hardware_->pollButtonEvent(event)) {
        handleButtonEvent(event);
    }
}

void AppLogic::handleNetworkCommand(const protocol::Command& command) {
    ++stats_.networkCommandCount;

    switch (command.type) {
        case protocol::CommandType::M370Frame:
            stopRnt();
            settings_.autoMode = false;
            mode_ = AppMode::Manual;
            baseFrame_ = command.m370.rgb;
            if (assets_ != nullptr) {
                assets_->setAutoModeDebounced(false);
            }
            renderRequested_ = true;
            break;
        case protocol::CommandType::RntStart:
            if (startRnt(command.rntPath, command.rntLoop)) {
                settings_.autoMode = false;
                if (assets_ != nullptr) {
                    assets_->setAutoModeDebounced(false);
                }
            } else {
                ++stats_.rntDecodeErrorCount;
            }
            break;
        case protocol::CommandType::RntStop:
            stopRnt();
            renderRequested_ = true;
            break;
        default:
            break;
    }
}

void AppLogic::handleButtonEvent(const ButtonEvent& event) {
    ++stats_.buttonEventCount;

    const uint32_t nowMs = millis();
    if (event.type == ButtonEventType::ComboPressed) {
        requestEdgeFlash(nowMs);
        return;
    }

    if (event.type == ButtonEventType::LongPress && event.button == ButtonId::ResetBattery) {
        requestBatteryOverlay(nowMs);
        return;
    }

    if (event.type != ButtonEventType::ShortPress) {
        return;
    }

    switch (event.button) {
        case ButtonId::Auto:
            setAutoMode(!settings_.autoMode);
            requestEdgeFlash(nowMs);
            break;
        case ButtonId::Prev:
            setAutoMode(false);
            selectFaceDelta(-1);
            requestEdgeFlash(nowMs);
            break;
        case ButtonId::Next:
            setAutoMode(false);
            selectFaceDelta(1);
            requestEdgeFlash(nowMs);
            break;
        case ButtonId::BrightnessDown:
            if (settings_.brightnessPct > config::BRIGHTNESS_MIN + config::BRIGHTNESS_STEP) {
                settings_.brightnessPct -= config::BRIGHTNESS_STEP;
            } else {
                settings_.brightnessPct = config::BRIGHTNESS_MIN;
            }
            settings_.brightnessCap = AssetManager::capFromPct(settings_.brightnessPct);
            if (assets_ != nullptr) {
                assets_->setBrightnessPctDebounced(settings_.brightnessPct);
            }
            if (display_ != nullptr) {
                display_->setBrightnessPct(settings_.brightnessPct);
            }
            requestEdgeFlash(nowMs);
            break;
        case ButtonId::BrightnessUp:
            if (settings_.brightnessPct + config::BRIGHTNESS_STEP < config::BRIGHTNESS_MAX) {
                settings_.brightnessPct += config::BRIGHTNESS_STEP;
            } else {
                settings_.brightnessPct = config::BRIGHTNESS_MAX;
            }
            settings_.brightnessCap = AssetManager::capFromPct(settings_.brightnessPct);
            if (assets_ != nullptr) {
                assets_->setBrightnessPctDebounced(settings_.brightnessPct);
            }
            if (display_ != nullptr) {
                display_->setBrightnessPct(settings_.brightnessPct);
            }
            requestEdgeFlash(nowMs);
            break;
        case ButtonId::ResetBattery:
            requestBatteryOverlay(nowMs);
            break;
        default:
            break;
    }
}

void AppLogic::setAutoMode(bool enabled) {
    settings_.autoMode = enabled;
    mode_ = enabled ? AppMode::Auto : AppMode::Manual;
    if (!enabled) {
        stopRnt();
    }
    if (assets_ != nullptr) {
        assets_->setAutoModeDebounced(enabled);
    }
    lastAutoAdvanceMs_ = 0;
    renderRequested_ = true;
}

void AppLogic::selectFaceDelta(int8_t delta) {
    stopRnt();
    const int16_t count = static_cast<int16_t>(config::NUM_FACES);
    int16_t next = static_cast<int16_t>(settings_.faceIndex) + delta;
    while (next < 0) {
        next += count;
    }
    next %= count;
    settings_.faceIndex = static_cast<uint16_t>(next);
    if (assets_ != nullptr) {
        assets_->setFaceIndexDebounced(settings_.faceIndex);
    }
    drawBuiltInFace(settings_.faceIndex, millis());
    renderRequested_ = true;
}

void AppLogic::requestEdgeFlash(uint32_t nowMs) {
    edgeFlashStartedMs_ = nowMs;
    edgeFlashUntilMs_ = nowMs + config::EDGE_FLASH_TOTAL_MS;
    renderRequested_ = true;
}

void AppLogic::requestBatteryOverlay(uint32_t nowMs) {
    batteryOverlayUntilMs_ = nowMs + config::BATTERY_SHORT_SHOW_MS;
    renderRequested_ = true;
}

void AppLogic::serviceAutoMode(uint32_t nowMs) {
    if (mode_ != AppMode::Auto) {
        return;
    }

    const uint32_t intervalMs = static_cast<uint32_t>(settings_.intervalS * 1000.0f);
    if (lastAutoAdvanceMs_ != 0 && nowMs - lastAutoAdvanceMs_ < intervalMs) {
        return;
    }

    lastAutoAdvanceMs_ = nowMs;
    settings_.faceIndex = (settings_.faceIndex + 1U) % config::NUM_FACES;
    if (assets_ != nullptr) {
        assets_->setFaceIndexDebounced(settings_.faceIndex);
    }
    drawBuiltInFace(settings_.faceIndex, nowMs);
    renderRequested_ = true;
}

void AppLogic::serviceRnt(uint32_t nowMs) {
    if (!rntReader_.isOpen()) {
        return;
    }

    if (nextRntDueMs_ != 0 && static_cast<int32_t>(nowMs - nextRntDueMs_) < 0) {
        return;
    }

    if (!readNextRntFrame(nowMs)) {
        stopRnt();
    }
}

bool AppLogic::readNextRntFrame(uint32_t nowMs) {
    char line[config::RNT_LINE_MAX_BYTES]{};
    size_t len = 0;

    for (uint8_t attempts = 0; attempts < 12; ++attempts) {
        const RntReadResult result = rntReader_.readLine(line, sizeof(line), len);
        if (result == RntReadResult::Eof) {
            if (rntLoop_ && rntPath_[0] != '\0' && rntReader_.open(rntPath_)) {
                continue;
            }
            return false;
        }
        if (result != RntReadResult::Line) {
            ++stats_.rntDecodeErrorCount;
            return false;
        }
        if (len == 0 || line[0] == '#' || startsWith(line, len, "RNT2|")) {
            continue;
        }

        uint32_t holdMs = kDefaultRntHoldMs;
        if (!decodeRntLine(line, len, holdMs)) {
            ++stats_.rntDecodeErrorCount;
            continue;
        }

        nextRntDueMs_ = nowMs + holdMs;
        ++stats_.rntFrameCount;
        renderRequested_ = true;
        return true;
    }

    return true;
}

bool AppLogic::decodeRntLine(const char* line, size_t len, uint32_t& holdMs) {
    const char* fields[4]{};
    size_t fieldLens[4]{};
    uint8_t field = 0;
    size_t fieldStart = 0;

    for (size_t i = 0; i <= len; ++i) {
        if (i == len || line[i] == '|') {
            if (field >= 4) {
                return false;
            }
            fields[field] = line + fieldStart;
            fieldLens[field] = i - fieldStart;
            ++field;
            fieldStart = i + 1U;
        }
    }

    if (field != 4) {
        return false;
    }

    const uint32_t holdFrames = parseUnsigned(fields[1], fieldLens[1], 1);
    holdMs = parseUnsigned(fields[2], fieldLens[2], holdFrames * kDefaultRntHoldMs);
    if (holdMs == 0) {
        holdMs = kDefaultRntHoldMs;
    }

    protocol::M370Frame frame;
    const auto parsed = protocol::parseM370Hex(
        reinterpret_cast<const uint8_t*>(fields[3]),
        fieldLens[3],
        frame);
    if (parsed != protocol::ParseResult::Ok) {
        return false;
    }

    baseFrame_ = frame.rgb;
    return true;
}

void AppLogic::drawBuiltInFace(uint16_t faceIndex, uint32_t nowMs) {
    baseFrame_.fill(0);

    const uint8_t huePhase = static_cast<uint8_t>((faceIndex * 37U + (nowMs / 50U)) & 0xffU);
    const uint8_t accentR = static_cast<uint8_t>(40U + (huePhase % 80U));
    const uint8_t accentG = static_cast<uint8_t>(20U + ((huePhase * 3U) % 90U));
    const uint8_t accentB = static_cast<uint8_t>(90U + ((huePhase * 5U) % 120U));

    for (size_t row = 0; row < config::ROWS; ++row) {
        const size_t len = config::ROW_LENGTHS[row];
        for (size_t col = 0; col < len; ++col) {
            const bool eye =
                (row >= 5U && row <= 7U) &&
                ((col >= len / 4U && col <= len / 4U + 2U) ||
                 (col >= (len * 3U) / 4U - 2U && col <= (len * 3U) / 4U));
            const bool mouth =
                (row >= 12U && row <= 13U) &&
                (col >= len / 3U && col <= (len * 2U) / 3U);
            const bool cheek =
                row == 10U &&
                (col == len / 5U || col == (len * 4U) / 5U);

            if (eye) {
                putRowPixel(baseFrame_, row, col, 0, 160, 255);
            } else if (mouth) {
                putRowPixel(baseFrame_, row, col, 255, 64, 90);
            } else if (cheek) {
                putRowPixel(baseFrame_, row, col, 255, 48, 96);
            } else if (((row + col + faceIndex) % 11U) == 0) {
                putRowPixel(baseFrame_, row, col, accentR, accentG, accentB);
            }
        }
    }
}

void AppLogic::composeAndSubmit(uint32_t nowMs) {
    if (display_ == nullptr) {
        return;
    }

    const uint32_t startUs = micros();
    composedFrame_ = baseFrame_;

    const uint8_t overlays = activeOverlayMask(nowMs);
    if ((overlays & kOverlayEdge) != 0) {
        applyEdgeFlash(nowMs);
    }
    if ((overlays & kOverlayBattery) != 0) {
        applyBatteryOverlay();
    }

    display_->submitBaseFrame(composedFrame_);

    const uint32_t elapsedUs = micros() - startUs;
    stats_.lastComposeUs = elapsedUs;
    if (elapsedUs > stats_.maxComposeUs) {
        stats_.maxComposeUs = elapsedUs;
    }
    stats_.activeOverlays = overlays;
    ++stats_.composeCount;
    renderRequested_ = false;
}

uint8_t AppLogic::activeOverlayMask(uint32_t nowMs) const {
    uint8_t mask = 0;
    if (edgeFlashUntilMs_ != 0 && static_cast<int32_t>(edgeFlashUntilMs_ - nowMs) > 0) {
        mask |= kOverlayEdge;
    }
    if (batteryOverlayUntilMs_ != 0 && static_cast<int32_t>(batteryOverlayUntilMs_ - nowMs) > 0) {
        mask |= kOverlayBattery;
    }
    return mask;
}

void AppLogic::applyEdgeFlash(uint32_t nowMs) {
    uint32_t scale = 0;
    const uint32_t elapsed = nowMs - edgeFlashStartedMs_;
    if (elapsed < config::EDGE_FLASH_ATTACK_MS) {
        scale = (elapsed * 255U) / config::EDGE_FLASH_ATTACK_MS;
    } else {
        const uint32_t decayElapsed = elapsed - config::EDGE_FLASH_ATTACK_MS;
        scale = decayElapsed >= config::EDGE_FLASH_DECAY_MS
                    ? 0
                    : 255U - ((decayElapsed * 255U) / config::EDGE_FLASH_DECAY_MS);
    }

    const uint8_t r = clampByte((config::EDGE_FLASH_COLOR[0] * scale) / 255U);
    const uint8_t g = clampByte((config::EDGE_FLASH_COLOR[1] * scale) / 255U);
    const uint8_t b = clampByte((config::EDGE_FLASH_COLOR[2] * scale) / 255U);

    for (size_t row = 0; row < config::ROWS; ++row) {
        const size_t len = config::ROW_LENGTHS[row];
        for (size_t col = 0; col < len; ++col) {
            if (row == 0 || row == config::ROWS - 1U || col == 0 || col == len - 1U) {
                putRowPixel(composedFrame_, row, col, r, g, b);
            }
        }
    }
}

void AppLogic::applyBatteryOverlay() {
    if (hardware_ == nullptr) {
        return;
    }

    const uint8_t percent = hardware_->batteryPercent();
    const size_t row = config::ROWS - 1U;
    const size_t len = config::ROW_LENGTHS[row];
    const size_t fill = (static_cast<size_t>(percent) * len + 99U) / 100U;

    uint8_t r = 32;
    uint8_t g = 220;
    uint8_t b = 48;
    if (percent < 20) {
        r = 255;
        g = 32;
        b = 24;
    } else if (percent < 45) {
        r = 255;
        g = 180;
        b = 24;
    }

    for (size_t col = 0; col < len; ++col) {
        if (col < fill) {
            putRowPixel(composedFrame_, row, col, r, g, b);
        } else {
            putRowPixel(composedFrame_, row, col, 8, 8, 8);
        }
    }
}

void AppLogic::putPixel(DisplayEngine::FrameBuffer& frame, size_t index, uint8_t r, uint8_t g, uint8_t b) {
    if (index >= config::NUM_LEDS) {
        return;
    }

    const size_t base = index * 3U;
    frame[base] = r;
    frame[base + 1U] = g;
    frame[base + 2U] = b;
}

void AppLogic::putRowPixel(DisplayEngine::FrameBuffer& frame, size_t row, size_t col, uint8_t r, uint8_t g, uint8_t b) {
    if (row >= config::ROWS || col >= config::ROW_LENGTHS[row]) {
        return;
    }
    putPixel(frame, rowStart(row) + col, r, g, b);
}

size_t AppLogic::rowStart(size_t row) const {
    size_t start = 0;
    for (size_t i = 0; i < row && i < config::ROWS; ++i) {
        start += config::ROW_LENGTHS[i];
    }
    return start;
}

void AppLogic::updateStatsState() {
    stats_.begun = begun_;
    stats_.autoMode = settings_.autoMode;
    stats_.rntActive = rntReader_.isOpen();
    stats_.faceIndex = settings_.faceIndex;
    stats_.mode = mode_;
}

}  // namespace rina
