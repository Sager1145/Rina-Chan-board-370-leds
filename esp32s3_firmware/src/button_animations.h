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

/**
 * @brief Start an overlay for a completed GPIO button action.
 * @param buttonCode Button or combo code such as B3, B3B1, B4, or B5.
 * @return None.
 */
void startButtonAnimationForGpioAction(const String& buttonCode);

/**
 * @brief Notify overlay logic of a debounced GPIO press.
 * @param buttonCode Button code; only B6 is consumed here.
 * @return None.
 */
void handleButtonAnimationGpioPress(const char* buttonCode);

/**
 * @brief Notify overlay logic of a debounced GPIO release.
 * @param buttonCode Button code; only B6 is consumed here.
 * @return None.
 */
void handleButtonAnimationGpioRelease(const char* buttonCode);

/**
 * @brief Service live physical-button chord state for B6 long-press behavior.
 * @param b6Pressed Debounced B6 state.
 * @param b2Pressed Debounced B2 state, used to suppress battery long-press.
 * @param b3Pressed Debounced B3 state, used to suppress battery long-press.
 * @return None.
 */
void serviceButtonAnimationButtonInputs(bool b6Pressed, bool b2Pressed, bool b3Pressed);

/**
 * @brief Expire overlays, advance battery pages, and request animated redraws.
 * @param None.
 * @return None.
 */
void serviceButtonAnimations();

/**
 * @brief Copy the active overlay frame for the LED renderer.
 * @param rgbOut Destination RGB buffer, LED_COUNT * 3 bytes.
 * @param ledCount Capacity expressed as logical LED count.
 * @return true when rgbOut contains a full overlay frame.
 */
bool copyButtonAnimationOverlay(uint8_t* rgbOut, uint16_t ledCount);

