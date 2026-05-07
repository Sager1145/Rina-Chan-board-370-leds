#pragma once

#include <cstdint>

#include "AssetManager.h"
#include "DisplayEngine.h"
#include "HardwareMonitor.h"
#include "NetworkManager.h"
#include "Protocol.h"

namespace rina {

enum class AppMode : uint8_t {
    Manual,
    Auto,
    Rnt,
};

struct AppLogicStats {
    bool begun = false;
    bool autoMode = false;
    bool rntActive = false;
    uint8_t activeOverlays = 0;
    uint16_t faceIndex = config::DEFAULT_FACE;
    uint32_t tickCount = 0;
    uint32_t networkCommandCount = 0;
    uint32_t buttonEventCount = 0;
    uint32_t composeCount = 0;
    uint32_t rntFrameCount = 0;
    uint32_t rntDecodeErrorCount = 0;
    uint32_t lastComposeUs = 0;
    uint32_t maxComposeUs = 0;
    AppMode mode = AppMode::Manual;
};

class AppLogic {
public:
    AppLogic();

    bool begin(
        DisplayEngine& display,
        AssetManager& assets,
        HardwareMonitor& hardware,
        NetworkManager& network);

    void tick();
    bool startRnt(const char* path, bool loop);
    void stopRnt();

    NetworkRuntimeSnapshot networkSnapshot() const;
    AppLogicStats stats() const;
    static const char* modeName(AppMode mode);

private:
    static uint32_t parseUnsigned(const char* text, size_t len, uint32_t fallback);

    void pollNetworkQueue();
    void pollHardwareQueue();
    void handleNetworkCommand(const protocol::Command& command);
    void handleButtonEvent(const ButtonEvent& event);
    void setAutoMode(bool enabled);
    void selectFaceDelta(int8_t delta);
    void requestEdgeFlash(uint32_t nowMs);
    void requestBatteryOverlay(uint32_t nowMs);
    void serviceAutoMode(uint32_t nowMs);
    void serviceRnt(uint32_t nowMs);
    bool readNextRntFrame(uint32_t nowMs);
    bool decodeRntLine(const char* line, size_t len, uint32_t& holdMs);
    void drawBuiltInFace(uint16_t faceIndex, uint32_t nowMs);
    void composeAndSubmit(uint32_t nowMs);
    uint8_t activeOverlayMask(uint32_t nowMs) const;
    void applyEdgeFlash(uint32_t nowMs);
    void applyBatteryOverlay();
    void putPixel(DisplayEngine::FrameBuffer& frame, size_t index, uint8_t r, uint8_t g, uint8_t b);
    void putRowPixel(DisplayEngine::FrameBuffer& frame, size_t row, size_t col, uint8_t r, uint8_t g, uint8_t b);
    size_t rowStart(size_t row) const;
    void updateStatsState();

    DisplayEngine* display_;
    AssetManager* assets_;
    HardwareMonitor* hardware_;
    NetworkManager* network_;
    DisplayEngine::FrameBuffer baseFrame_;
    DisplayEngine::FrameBuffer composedFrame_;
    RntLineReader rntReader_;
    RuntimeSettings settings_;
    AppLogicStats stats_;
    AppMode mode_;
    bool begun_;
    bool renderRequested_;
    bool rntLoop_;
    char rntPath_[96];
    uint32_t lastAutoAdvanceMs_;
    uint32_t nextRntDueMs_;
    uint32_t edgeFlashStartedMs_;
    uint32_t edgeFlashUntilMs_;
    uint32_t batteryOverlayUntilMs_;
};

}  // namespace rina
