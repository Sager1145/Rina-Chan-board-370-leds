#pragma once

// RinaLink TCP carrier: WiFiServer on RINALINK_TCP_PORT, up to 2 clients.
// See src/transport.h for the shared ITransport contract and threading rules.

void tcpTransportBegin();
void tcpTransportService();
