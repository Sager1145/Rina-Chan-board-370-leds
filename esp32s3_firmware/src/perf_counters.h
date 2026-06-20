#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

#ifndef ENABLE_PERF_PROFILING
#define ENABLE_PERF_PROFILING 1
#endif

#if ENABLE_PERF_PROFILING

// API Frame counters
void perfRecordApiFrame(uint32_t totalUs, uint32_t parseUs, uint32_t applyUs, uint32_t responseUs, size_t bodySize, uint16_t deltaCount, bool isLive, bool isDelta);

// Render counters
void perfRecordRender(uint32_t requestToStartUs, uint32_t pixelLoopUs, uint32_t showUs, uint32_t totalUs);

// Queue counters
void perfRecordQueueEnqueue();
void perfRecordQueueDequeue(uint32_t ageUs);
void perfRecordQueueDropped();

// Button counters
void perfRecordButtonScan(uint32_t scanUs);
void perfRecordButtonAction(uint32_t actionUs);

// Power counters
void perfRecordPowerService(uint32_t serviceUs);

// Serial Log counters
void perfRecordSerialLogBytes(size_t attempted, size_t emitted, size_t dropped);

// Control functions
void perfClearCounters();
void perfSerializeCounters(JsonDocument& doc);

// Render Request age tracking helper variables
extern volatile uint32_t currentFrameAcceptedUs;
extern volatile uint32_t lastRenderRequestUs;
extern volatile uint32_t renderStartUs;
extern volatile uint32_t showDoneUs;

#else

// Inline empty stubs when ENABLE_PERF_PROFILING is 0
inline void perfRecordApiFrame(uint32_t, uint32_t, uint32_t, uint32_t, size_t, uint16_t, bool, bool) {}
inline void perfRecordRender(uint32_t, uint32_t, uint32_t, uint32_t) {}
inline void perfRecordQueueEnqueue() {}
inline void perfRecordQueueDequeue(uint32_t) {}
inline void perfRecordQueueDropped() {}
inline void perfRecordButtonScan(uint32_t) {}
inline void perfRecordButtonAction(uint32_t) {}
inline void perfRecordPowerService(uint32_t) {}
inline void perfRecordSerialLogBytes(size_t, size_t, size_t) {}
inline void perfClearCounters() {}

#endif
