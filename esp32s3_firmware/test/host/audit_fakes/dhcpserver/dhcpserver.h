#pragma once
#include <cstdint>
struct FakeIp4 { uint32_t addr = 0; };
struct dhcps_lease_t {
    bool enable = false;
    FakeIp4 start_ip;
    FakeIp4 end_ip;
};
