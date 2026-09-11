#pragma once

// RinaLink v1 dispatcher. Implements the transport.h client registry and
// frames/parses/dispatches every message from the Core-0 loop(). Carriers
// (transport_tcp.cpp, transport_ble.cpp) only push raw bytes; all
// RuntimeState/faces/scroll_session/led_renderer calls happen here, on Core 0.
// See docs/RINALINK_PROTOCOL_V1.md for the wire format and command set.

void protocolBegin();
void serviceProtocol();
