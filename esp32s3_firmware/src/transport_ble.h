#pragma once
// RinaLink BLE transport (NimBLE-Arduino 2.x). See docs/RINALINK_PROTOCOL_V1.md
// §1.1 for the GATT layout and §2 for the shared framing. Implements
// rinalink::ITransport (see src/transport.h) internally; only these
// lifecycle entry points are public.

#include <Arduino.h> // String
#include <stddef.h>

// Initialize the BLE GATT server/advertising. Call once from setup(), any core.
// Reads runtimeState().deviceName, so call it after loadRuntimeSettings().
void bleTransportBegin();

// Non-blocking, O(1) deferred-work pump (advertising restart, INFO refresh).
// Call every Core-0 loop() iteration.
void bleTransportService();

// Write the effective advertised name into `out` — runtimeState().deviceName
// when the user has set one, otherwise the full-MAC-derived
// "RinaBoard-AABBCCDDEEFF". Safe
// to call before bleTransportBegin(). `out` is always NUL-terminated.
void bleTransportDeviceName(char* out, size_t outLen);

// The full-MAC-derived default name ("RinaBoard-AABBCCDDEEFF"), ignoring any
// user override.
// Lets the app show what the board would be called if the name were cleared.
void bleTransportDefaultDeviceName(char* out, size_t outLen);

// Set the user-visible board name and re-advertise it without a reboot.
// Pass nullptr or "" to clear the override and fall back to the MAC default.
// Returns false (and leaves the name unchanged) if `name` is not valid UTF-8 or
// exceeds MAX_DEVICE_NAME_BYTES; `error` then holds a human-readable reason.
// Caller is responsible for persisting via saveRuntimeSettings().
bool bleTransportSetDeviceName(const char* name, String& error);
