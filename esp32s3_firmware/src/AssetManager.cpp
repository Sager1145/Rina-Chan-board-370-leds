#include "AssetManager.h"

#include <algorithm>

#include <Arduino.h>
#include <ArduinoJson.h>
#include <LittleFS.h>

#include "FixedJsonAllocator.h"

namespace rina {
namespace {

float clampInterval(float value) {
    if (value < config::INTERVAL_MIN_S) {
        return config::INTERVAL_MIN_S;
    }
    if (value > config::INTERVAL_MAX_S) {
        return config::INTERVAL_MAX_S;
    }
    return value;
}

uint32_t clampPowerBudget(uint32_t value) {
    if (value < config::POWER_BUDGET_MA_CONFIG_MIN) {
        return config::POWER_BUDGET_MA_CONFIG_MIN;
    }
    if (value > config::POWER_BUDGET_MA_ABSOLUTE_MAX) {
        return config::POWER_BUDGET_MA_ABSOLUTE_MAX;
    }
    return value;
}

}  // namespace

RntLineReader::RntLineReader()
    : file_(),
      buffer_{},
      pos_(0),
      len_(0),
      lineNumber_(0),
      eof_(false) {
}

bool RntLineReader::open(const char* path) {
    close();
    file_ = LittleFS.open(path, "r");
    pos_ = 0;
    len_ = 0;
    lineNumber_ = 0;
    eof_ = false;
    return static_cast<bool>(file_);
}

void RntLineReader::close() {
    if (file_) {
        file_.close();
    }
    pos_ = 0;
    len_ = 0;
    lineNumber_ = 0;
    eof_ = false;
}

RntReadResult RntLineReader::readLine(char* out, size_t outCapacity, size_t& outLength) {
    outLength = 0;

    if (!file_) {
        return RntReadResult::Error;
    }

    if (out == nullptr || outCapacity == 0) {
        discardUntilLineEnd();
        return RntReadResult::Overflow;
    }

    const size_t maxPayload = outCapacity - 1U;

    while (true) {
        if (pos_ >= len_ && !refill()) {
            if (outLength > 0) {
                if (out[outLength - 1U] == '\r') {
                    --outLength;
                }
                out[outLength] = '\0';
                ++lineNumber_;
                return RntReadResult::Line;
            }
            return RntReadResult::Eof;
        }

        while (pos_ < len_) {
            const char c = static_cast<char>(buffer_[pos_++]);
            if (c == '\n') {
                if (outLength > 0 && out[outLength - 1U] == '\r') {
                    --outLength;
                }
                out[outLength] = '\0';
                ++lineNumber_;
                return RntReadResult::Line;
            }

            if (outLength >= maxPayload) {
                discardUntilLineEnd();
                out[maxPayload] = '\0';
                return RntReadResult::Overflow;
            }

            out[outLength++] = c;
        }
    }
}

bool RntLineReader::isOpen() const {
    return static_cast<bool>(file_);
}

uint32_t RntLineReader::lineNumber() const {
    return lineNumber_;
}

bool RntLineReader::refill() {
    if (eof_) {
        return false;
    }

    const int bytesRead = file_.read(buffer_.data(), buffer_.size());
    if (bytesRead <= 0) {
        eof_ = true;
        pos_ = 0;
        len_ = 0;
        return false;
    }

    pos_ = 0;
    len_ = static_cast<size_t>(bytesRead);
    return true;
}

void RntLineReader::discardUntilLineEnd() {
    while (true) {
        if (pos_ >= len_ && !refill()) {
            return;
        }

        while (pos_ < len_) {
            if (buffer_[pos_++] == '\n') {
                ++lineNumber_;
                return;
            }
        }
    }
}

AssetManager::AssetManager()
    : mutex_(nullptr),
      dirtyTimer_(nullptr),
      ioTask_(nullptr),
      settings_(),
      stats_(),
      dirty_(false),
      flushPending_(false),
      firstDirtyMs_(0),
      lastDirtyMs_(0),
      dirtyGeneration_(0) {
}

bool AssetManager::begin(bool formatOnFail) {
    if (stats_.mounted) {
        return true;
    }

    mutex_ = xSemaphoreCreateMutex();
    if (mutex_ == nullptr) {
        return false;
    }

    if (!LittleFS.begin(
            formatOnFail,
            config::LITTLEFS_BASE_PATH,
            10,
            config::LITTLEFS_PARTITION_LABEL)) {
        return false;
    }

    stats_.mounted = true;
    stats_.settingsLoaded = loadSettingsFromFs(settings_);

    dirtyTimer_ = xTimerCreate(
        "asset_dirty",
        pdMS_TO_TICKS(config::DIRTY_QUEUE_TIMER_MS),
        pdTRUE,
        this,
        &AssetManager::timerThunk);
    if (dirtyTimer_ == nullptr) {
        return false;
    }

    return xTimerStart(dirtyTimer_, 0) == pdPASS;
}

bool AssetManager::mounted() const {
    if (mutex_ == nullptr || !lock()) {
        return false;
    }
    const bool value = stats_.mounted;
    unlock();
    return value;
}

RuntimeSettings AssetManager::settings() const {
    RuntimeSettings copy;
    if (lock()) {
        copy = settings_;
        unlock();
    }
    return copy;
}

bool AssetManager::loadSettings(RuntimeSettings& out) {
    if (!stats_.mounted) {
        return false;
    }

    const bool ok = loadSettingsFromFs(out);
    if (ok && lock()) {
        settings_ = out;
        stats_.settingsLoaded = true;
        unlock();
    }
    return ok;
}

void AssetManager::setSettingsDebounced(const RuntimeSettings& settings) {
    if (!lock()) {
        return;
    }

    settings_ = settings;
    settings_.brightnessPct = clampBrightnessPct(settings_.brightnessPct);
    settings_.brightnessCap = capFromPct(settings_.brightnessPct);
    settings_.faceIndex = settings_.faceIndex % config::NUM_FACES;
    settings_.intervalS = clampInterval(settings_.intervalS);
    settings_.powerBudgetMa = clampPowerBudget(settings_.powerBudgetMa);
    markDirtyLocked(millis());
    unlock();
}

void AssetManager::setBrightnessPctDebounced(uint8_t pct) {
    if (!lock()) {
        return;
    }
    settings_.brightnessPct = clampBrightnessPct(pct);
    settings_.brightnessCap = capFromPct(settings_.brightnessPct);
    markDirtyLocked(millis());
    unlock();
}

void AssetManager::setFaceIndexDebounced(uint16_t faceIndex) {
    if (!lock()) {
        return;
    }
    settings_.faceIndex = faceIndex % config::NUM_FACES;
    markDirtyLocked(millis());
    unlock();
}

void AssetManager::setAutoModeDebounced(bool autoMode) {
    if (!lock()) {
        return;
    }
    settings_.autoMode = autoMode;
    markDirtyLocked(millis());
    unlock();
}

void AssetManager::setIntervalDebounced(float intervalS) {
    if (!lock()) {
        return;
    }
    settings_.intervalS = clampInterval(intervalS);
    markDirtyLocked(millis());
    unlock();
}

void AssetManager::setPowerBudgetDebounced(uint32_t powerBudgetMa) {
    if (!lock()) {
        return;
    }
    settings_.powerBudgetMa = clampPowerBudget(powerBudgetMa);
    markDirtyLocked(millis());
    unlock();
}

void AssetManager::setIoTaskHandle(TaskHandle_t task) {
    if (!lock()) {
        return;
    }
    ioTask_ = task;
    unlock();
}

void AssetManager::serviceIo() {
    bool shouldFlush = false;

    if (!lock()) {
        return;
    }

    shouldFlush = flushPending_;
    flushPending_ = false;
    unlock();

    if (shouldFlush) {
        (void)flushNow();
    }
}

bool AssetManager::flushNow() {
    RuntimeSettings snapshot;
    uint32_t generation = 0;

    if (!lock()) {
        return false;
    }

    if (!dirty_) {
        unlock();
        return true;
    }

    snapshot = settings_;
    generation = dirtyGeneration_;
    ++stats_.flushAttemptCount;
    unlock();

    const bool ok = writeSettingsAtomic(snapshot);

    if (lock()) {
        if (ok) {
            ++stats_.flushSuccessCount;
            stats_.lastFlushMs = millis();
            if (generation == dirtyGeneration_) {
                dirty_ = false;
                flushPending_ = false;
                stats_.settingsDirty = false;
            }
        } else {
            ++stats_.flushFailureCount;
        }
        unlock();
    }

    return ok;
}

AssetManagerStats AssetManager::stats() const {
    AssetManagerStats copy;
    if (mutex_ == nullptr) {
        return stats_;
    }
    (void)lock();
    copy = stats_;
    unlock();
    return copy;
}

uint8_t AssetManager::clampBrightnessPct(uint8_t pct) {
    if (pct < config::BRIGHTNESS_MIN) {
        return config::BRIGHTNESS_MIN;
    }
    if (pct > config::BRIGHTNESS_MAX) {
        return config::BRIGHTNESS_MAX;
    }
    return pct;
}

uint8_t AssetManager::capFromPct(uint8_t pct) {
    pct = clampBrightnessPct(pct);
    return static_cast<uint8_t>(
        (static_cast<uint16_t>(pct) * config::MAX_BRIGHTNESS_HARD_CAP + 50U) / 100U);
}

void AssetManager::timerThunk(TimerHandle_t timer) {
    auto* self = static_cast<AssetManager*>(pvTimerGetTimerID(timer));
    if (self != nullptr) {
        self->serviceDirtyQueue();
    }
}

bool AssetManager::loadSettingsFromFs(RuntimeSettings& out) {
    out = RuntimeSettings{};

    File file = LittleFS.open(config::SETTINGS_FILE, "r");
    if (!file) {
        return false;
    }

    FixedJsonAllocator<config::SETTINGS_JSON_POOL_BYTES> allocator;
    JsonDocument doc(&allocator);
    const DeserializationError err = deserializeJson(doc, file);
    file.close();
    if (err || doc.overflowed()) {
        return false;
    }

    out.schemaVersion = doc["schema_version"] | out.schemaVersion;
    out.brightnessPct = clampBrightnessPct(doc["brightness_pct"] | out.brightnessPct);
    out.brightnessCap = capFromPct(out.brightnessPct);
    out.faceIndex = static_cast<uint16_t>(doc["face_index"] | out.faceIndex) % config::NUM_FACES;
    out.autoMode = doc["auto"] | out.autoMode;
    out.intervalS = clampInterval(doc["interval_s"] | out.intervalS);
    out.powerBudgetMa = clampPowerBudget(doc["power_budget_ma"] | out.powerBudgetMa);
    return true;
}

bool AssetManager::writeSettingsAtomic(const RuntimeSettings& settings) {
    if (!stats_.mounted) {
        return false;
    }

    LittleFS.remove(config::SETTINGS_TMP_FILE);

    File file = LittleFS.open(config::SETTINGS_TMP_FILE, "w");
    if (!file) {
        return false;
    }

    FixedJsonAllocator<config::SETTINGS_JSON_POOL_BYTES> allocator;
    JsonDocument doc(&allocator);
    doc["schema_version"] = settings.schemaVersion;
    doc["version"] = config::VERSION;
    doc["brightness_pct"] = settings.brightnessPct;
    doc["brightness_cap"] = settings.brightnessCap;
    doc["face_index"] = settings.faceIndex;
    doc["auto"] = settings.autoMode;
    doc["interval_s"] = settings.intervalS;
    doc["power_budget_ma"] = settings.powerBudgetMa;

    if (doc.overflowed()) {
        file.close();
        LittleFS.remove(config::SETTINGS_TMP_FILE);
        return false;
    }

    const size_t written = serializeJson(doc, file);
    file.println();
    file.flush();
    file.close();

    if (written == 0) {
        LittleFS.remove(config::SETTINGS_TMP_FILE);
        return false;
    }

    if (!LittleFS.rename(config::SETTINGS_TMP_FILE, config::SETTINGS_FILE)) {
        LittleFS.remove(config::SETTINGS_FILE);
        if (!LittleFS.rename(config::SETTINGS_TMP_FILE, config::SETTINGS_FILE)) {
            LittleFS.remove(config::SETTINGS_TMP_FILE);
            return false;
        }
    }

    return true;
}

void AssetManager::markDirtyLocked(uint32_t nowMs) {
    if (!dirty_) {
        firstDirtyMs_ = nowMs;
    }
    dirty_ = true;
    lastDirtyMs_ = nowMs;
    ++dirtyGeneration_;
    ++stats_.dirtyMarkCount;
    stats_.settingsDirty = true;
}

void AssetManager::serviceDirtyQueue() {
    bool shouldFlush = false;
    TaskHandle_t ioTask = nullptr;

    if (!lock(0)) {
        return;
    }

    if (dirty_) {
        const uint32_t nowMs = millis();
        const bool quietEnough = (nowMs - lastDirtyMs_) >= config::FLASH_FLUSH_DEBOUNCE_MS;
        const bool tooOld = (nowMs - firstDirtyMs_) >= config::MAX_DIRTY_DURATION_MS;
        shouldFlush = quietEnough || tooOld;
        if (shouldFlush) {
            flushPending_ = true;
            ioTask = ioTask_;
        }
    }

    unlock();

    if (shouldFlush && ioTask != nullptr) {
        xTaskNotifyGive(ioTask);
    }
}

bool AssetManager::lock(TickType_t ticks) const {
    return mutex_ != nullptr && xSemaphoreTake(mutex_, ticks) == pdTRUE;
}

void AssetManager::unlock() const {
    xSemaphoreGive(mutex_);
}

}  // namespace rina
