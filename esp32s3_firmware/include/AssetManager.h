#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include <FS.h>

#include "Config.h"

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/timers.h"

namespace rina {

struct RuntimeSettings {
    uint8_t brightnessPct = config::DEFAULT_BRIGHTNESS_PCT;
    uint8_t brightnessCap = config::MAX_BRIGHTNESS_DEFAULT;
    uint16_t faceIndex = config::DEFAULT_FACE;
    bool autoMode = false;
    float intervalS = config::DEFAULT_INTERVAL_S;
    uint32_t powerBudgetMa = config::POWER_BUDGET_MA_DEFAULT;
    uint32_t schemaVersion = 1;
};

struct AssetManagerStats {
    bool mounted = false;
    bool settingsLoaded = false;
    bool settingsDirty = false;
    uint32_t dirtyMarkCount = 0;
    uint32_t flushAttemptCount = 0;
    uint32_t flushSuccessCount = 0;
    uint32_t flushFailureCount = 0;
    uint32_t lastFlushMs = 0;
};

enum class RntReadResult : uint8_t {
    Line,
    Eof,
    Overflow,
    Error,
};

class RntLineReader {
public:
    RntLineReader();

    bool open(const char* path);
    void close();
    RntReadResult readLine(char* out, size_t outCapacity, size_t& outLength);
    bool isOpen() const;
    uint32_t lineNumber() const;

private:
    bool refill();
    void discardUntilLineEnd();

    File file_;
    std::array<uint8_t, config::RNT_CHUNK_SIZE> buffer_;
    size_t pos_;
    size_t len_;
    uint32_t lineNumber_;
    bool eof_;
};

class AssetManager {
public:
    AssetManager();

    bool begin(bool formatOnFail = false);
    bool mounted() const;

    RuntimeSettings settings() const;
    bool loadSettings(RuntimeSettings& out);
    void setSettingsDebounced(const RuntimeSettings& settings);
    void setBrightnessPctDebounced(uint8_t pct);
    void setFaceIndexDebounced(uint16_t faceIndex);
    void setAutoModeDebounced(bool autoMode);
    void setIntervalDebounced(float intervalS);
    void setPowerBudgetDebounced(uint32_t powerBudgetMa);

    bool flushNow();
    const AssetManagerStats& stats() const;

    static uint8_t clampBrightnessPct(uint8_t pct);
    static uint8_t capFromPct(uint8_t pct);

private:
    static void timerThunk(TimerHandle_t timer);

    bool loadSettingsFromFs(RuntimeSettings& out);
    bool writeSettingsAtomic(const RuntimeSettings& settings);
    void markDirtyLocked(uint32_t nowMs);
    void serviceDirtyQueue();
    bool lock(TickType_t ticks = portMAX_DELAY) const;
    void unlock() const;

    mutable SemaphoreHandle_t mutex_;
    TimerHandle_t dirtyTimer_;
    RuntimeSettings settings_;
    AssetManagerStats stats_;
    bool dirty_;
    uint32_t firstDirtyMs_;
    uint32_t lastDirtyMs_;
    uint32_t dirtyGeneration_;
};

}  // namespace rina
