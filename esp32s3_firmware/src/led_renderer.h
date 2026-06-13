#pragma once
#include <Arduino.h>
#include "config.h"
#include "state.h"

bool normalizeM370(const String& input, String& normalized, String& error);

bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error);

String blankM370();

void setFrameBit(uint16_t index, bool on);

bool frameBit(uint16_t index);

bool packedFrameBit(const uint8_t* bits, uint16_t index);

uint16_t countLitLeds();
FrameStateSnapshot readFrameStateSnapshot();

bool applyM370(const String& input, const String& reason, String& error);

void applyPackedFrame(const uint8_t* packedBits, const String& reason);

void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason);

void applyBlankFrame(const String& reason);

void serviceM370FrameQueue();

void clearQueuedM370Frames();

uint8_t queuedM370FrameCount();

void setColorStateNoRender(const String& input);

bool setColor(const String& input, String& error);

void setBrightness(int raw);

void requestLedRender();

bool consumeLedRenderRequest();

void showCurrentFrameNoLock();

void renderCurrentFrameToLedStrip();

void initLedIndexMap();

void ledStripBegin();
