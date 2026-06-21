#pragma once
#include <Arduino.h>
#include "config.h"

//

void startButtonAnimationForGpioAction(const String& buttonCode);

void showBatteryOverlay(bool singleShot);

void handleButtonAnimationGpioPress(const char* buttonCode);

void handleButtonAnimationGpioRelease(const char* buttonCode);

void serviceButtonAnimationButtonInputs(bool b6Pressed, bool b2Pressed, bool b3Pressed);

void serviceButtonAnimations();

bool copyButtonAnimationOverlay(uint8_t* rgbOut, uint16_t ledCount);
