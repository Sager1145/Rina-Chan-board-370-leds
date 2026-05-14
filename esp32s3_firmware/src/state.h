#pragma once
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include "config.h"

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------
struct RuntimeState {
    String   colorHex            = DEFAULT_COLOR;
    uint8_t  colorR              = 0xf9;
    uint8_t  colorG              = 0x71;
    uint8_t  colorB              = 0xd4;
    uint8_t  brightness          = DEFAULT_BRIGHTNESS;
    String   mode                = DEFAULT_MODE;
    String   playback            = DEFAULT_PLAYBACK;
    String   lastM370;
    String   lastReason          = "boot";
    bool     paused              = false;

    // Stats
    uint32_t framesAccepted      = 0;
    uint32_t framesRejected      = 0;
    uint32_t commandsAccepted    = 0;
    uint32_t commandsRejected    = 0;
    uint32_t savedFacesWrites    = 0;
    uint32_t settingsWrites      = 0;
    uint32_t bootMs              = 0;

    // Auto-playback
    uint32_t autoIntervalMs      = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs    = 0;
    uint16_t autoFaceIndex       = 0;

    // Scroll
    bool     firmwareScrollActive  = false;
    bool     firmwareScrollPaused  = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount      = 0;
    uint16_t scrollFrameIndex      = 0;
    uint16_t scrollIntervalMs      = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs     = 0;

    // Deferred face restore after an explicit all-off clear frame.
    // Used to avoid delay() inside HTTP / button handlers while still
    // giving the LED render task enough time to physically latch blank.
    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    String   deferredFaceRestoreReason;
};

// ---------------------------------------------------------------------------
// Saved face record (runtime copy of one face from saved_faces.json)
// ---------------------------------------------------------------------------
struct RuntimeFace {
    String   id;
    String   name;
    String   m370;
    int32_t  order           = 0;
    uint16_t jsonIndex       = 0;
    bool     isDefault       = false;
    bool     isStartupDefault = false;
};

// ---------------------------------------------------------------------------
// Shared globals  (defined in state.cpp)
// ---------------------------------------------------------------------------
extern RuntimeState       state;
extern RuntimeFace        autoFaces[MAX_AUTO_FACES];
extern uint16_t           autoFaceCount;

// Frame buffer (packed bits, logical order)
extern uint8_t            frameBits[FRAME_BYTES];
// Scroll frame cache
extern uint8_t            scrollFrameBits[MAX_SCROLL_FRAMES][FRAME_BYTES];

// LittleFS mount flag
extern bool               fsMounted;

// FreeRTOS primitives
extern SemaphoreHandle_t  frameMutex;
extern SemaphoreHandle_t  scrollMutex;
extern TaskHandle_t       scrollTaskHandle;

// LED render request (written from any core, consumed by render task)
extern portMUX_TYPE       ledRenderRequestMux;
extern volatile bool      ledRenderRequested;
extern uint32_t           lastLedShowUs;

// Logical-to-physical LED index lookup table
extern uint16_t           logicalToPhysicalMap[LED_COUNT];
