#pragma once
#include <Arduino.h>
#include "config.h"
#include "state.h"

bool validatePackedFrame(const uint8_t* packedBits, String& error);

void setFrameBit(uint16_t index, bool on);

bool frameBit(uint16_t index);

bool packedFrameBit(const uint8_t* bits, uint16_t index);

uint16_t countLitLeds();
FrameStateSnapshot readFrameStateSnapshot();

bool applyPackedFrameQueued(const uint8_t* packedBits, const String& reason, String& error);

void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason);

void applyBlankFrame(const String& reason);

void servicePackedFrameQueue();

void clearQueuedPackedFrames();

uint8_t queuedPackedFrameCount();

void setColorStateNoRender(const String& input);

bool setColor(const String& input, String& error);

void setBrightness(int raw);

void requestLedRender();

bool consumeLedRenderRequest();

void showCurrentFrameNoLock();

void renderCurrentFrameToLedStrip();

void initLedIndexMap();

void ledStripBegin();
