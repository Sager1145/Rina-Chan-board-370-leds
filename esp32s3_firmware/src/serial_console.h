#pragma once
#include <Arduino.h>
#include "config.h"

// =============================================================================
// serial_console -- line-based command interface on USB Serial and, when
// ENABLE_SERIAL_UART0_MIRROR=1, UART0. Each input has an independent line
// buffer. Non-blocking: serviceSerialConsole() drains only the bytes already
// buffered each loop and never calls delay().
//
// Wiring (the only two touch-points in main.cpp):
//   setup(): initSerialConsole();
//   loop():  serviceSerialConsole();
//
// Both are no-ops when ENABLE_SERIAL_CONSOLE == 0, so a stripped production
// image is byte-for-byte unaffected apart from two elided calls.
// =============================================================================

void initSerialConsole();
void serviceSerialConsole();
