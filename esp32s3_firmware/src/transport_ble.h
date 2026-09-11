#pragma once
// RinaLink BLE transport (NimBLE-Arduino 2.x). See docs/RINALINK_PROTOCOL_V1.md
// §1.1 for the GATT layout and §2 for the shared framing. Implements
// rinalink::ITransport (see src/transport.h) internally; only these two
// lifecycle entry points are public.

// Initialize the BLE GATT server/advertising. Call once from setup(), any core.
void bleTransportBegin();

// Non-blocking, O(1) deferred-work pump (advertising restart, INFO refresh).
// Call every Core-0 loop() iteration.
void bleTransportService();
