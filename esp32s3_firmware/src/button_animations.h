#pragma once
#include <Arduino.h>
#include "config.h"

// ---------------------------------------------------------------------------
// GPIO button LED animation overlay
// ---------------------------------------------------------------------------
//
// The overlay is intentionally separate from runtimeFrameBits(): it only
// replaces the physical LED output while active, then the current firmware
// frame/scroll content is rendered again.

// Start an overlay for a completed GPIO button action such as B3, B3B1, B4.
void startButtonAnimationForGpioAction(const String& buttonCode);

// Debounced GPIO B6 press/release hooks used for short/long battery overlays.
void handleButtonAnimationGpioPress(const char* buttonCode);
void handleButtonAnimationGpioRelease(const char* buttonCode);

// Called from the GPIO button service so B6 long-press can fire at 700 ms.
void serviceButtonAnimationButtonInputs(bool b6Pressed, bool b2Pressed, bool b3Pressed);

// Called once per loop() to expire overlays, advance battery pages, and request
// redraws for animated edge flashes / charging sweeps.
void serviceButtonAnimations();

// Called by the Core-1 LED renderer. Returns true when rgbOut contains a full
// LED_COUNT RGB overlay frame in logical LED order.
bool copyButtonAnimationOverlay(uint8_t* rgbOut, uint16_t ledCount);

