#include "config.h"

// Network constants live in a .cpp file because IPAddress is not a literal
// type on all Arduino cores.  config.h exposes inline references so the web
// and AP modules share one definition without global constructor ambiguity.
const IPAddress AP_IP_ADDR(192, 168, 1, 14);
const IPAddress AP_GATEWAY_ADDR(192, 168, 1, 14);
const IPAddress AP_SUBNET_MASK(255, 255, 255, 0);
