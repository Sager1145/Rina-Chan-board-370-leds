#include "config.h"
#include "board_identity.h"
#include "ap_address_policy.h"

const IPAddress AP_SUBNET_MASK(255, 255, 255, 0);

IPAddress factoryApIP() {
    const auto address = ap_address::factoryAddressForBoardId(boardId());
    return IPAddress(address.octets[0], address.octets[1], address.octets[2], address.octets[3]);
}

namespace {
IPAddress& configuredApIP() {
    static IPAddress address = factoryApIP();
    return address;
}
}

const IPAddress& apIP() { return configuredApIP(); }
void setApIP(const IPAddress& ip) { configuredApIP() = ip; }
