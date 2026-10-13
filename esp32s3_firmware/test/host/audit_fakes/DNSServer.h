#pragma once
#include <IPAddress.h>
class DNSServer {
  public:
    inline static bool running = false;
    void setTTL(uint32_t) {}
    bool start(uint16_t, const char*, IPAddress) { running = true; return true; }
    void stop() { running = false; }
    void processNextRequest() {}
};
