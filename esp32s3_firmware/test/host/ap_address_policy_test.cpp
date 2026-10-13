#include "ap_address_policy.h"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

static void require(bool value, const char* message) {
    if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

int main() {
    using namespace ap_address;
    require(factoryAddressForBoardId("80B54EF48E09").networkOrderValue() == 0x0AF48E09,
            "board A factory vector");
    require(factoryAddressForBoardId("80B54EF74801").networkOrderValue() == 0x0AF74801,
            "board B factory vector");
    require(factoryAddressForBoardId("80b54ef48e09").networkOrderValue() == 0x0AF48E09,
            "lowercase board identity uses same suffix");
    require(factoryAddress(0).networkOrderValue() == 0xAC100001, "zero suffix remaps");
    require(factoryAddress(255).networkOrderValue() == 0xAC100002, "broadcast suffix remaps");
    require(factoryAddress(0xFFFF00).networkOrderValue() == 0xAC120407, "last zero suffix vector");
    require(factoryAddress(0xFFFFFF).networkOrderValue() == 0xAC120408, "last broadcast suffix vector");
    // Exhaust all exceptional identities: unique within 172.16/12, therefore
    // also disjoint from every regular identity in 10/8.
    std::vector<bool> seen(1U << 20);
    for (uint32_t network = 0; network < 65536; ++network) {
        for (uint32_t host : {0U, 255U}) {
            const auto address = factoryAddress((network << 8) | host);
            require(address.octets[0] == 172 && address.octets[1] >= 16 && address.octets[1] <= 31,
                    "exceptional suffix stays private");
            require(address.octets[3] >= 1 && address.octets[3] <= 254, "exceptional suffix host usable");
            const uint32_t key = address.networkOrderValue() - 0xAC100000;
            require(!seen[key], "exceptional suffix mapping injective"); seen[key] = true;
        }
        for (uint32_t host : {1U, 9U, 31U, 32U, 254U}) {
            const uint32_t suffix = (network << 8) | host;
            require(factoryAddress(suffix).networkOrderValue() == (0x0A000000 | suffix),
                    "regular suffix preserves all identity bits");
        }
    }
    for (const char* valid : {"10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254",
                              "192.168.0.1", "192.168.255.254"}) {
        IPv4 address{}; require(parsePrivateHost(valid, address), "private canonical address accepted");
    }
    for (const char* invalid : {"", "10.0.0.0", "10.0.0.255", "172.15.0.1", "172.32.0.1",
        "192.169.1.1", "8.8.8.8", "127.0.0.1", "169.254.1.1", "224.0.0.1", "100.64.0.1",
        "10.256.0.1", "10.0.0", "10.0.0.1.2", "010.0.0.1", "10.00.0.1", "10.0.0.01",
        " 10.0.0.1", "10.0.0.1 ", "+10.0.0.1", "10.0.0.-1", "10.0.0.1/24", "10.0.0.１"}) {
        IPv4 address{{1, 2, 3, 4}};
        require(!parsePrivateHost(invalid, address), "invalid address rejected");
        require(address.networkOrderValue() == 0x01020304, "rejection leaves output unchanged");
    }
    IPv4 address{}; require(!parsePrivateHost(nullptr, address), "null rejected");
    for (unsigned host = 1; host < 255; ++host) {
        const auto pool = leaseRange(uint8_t(host));
        require(pool.last - pool.first == 15, "DHCP supplies sixteen leases");
        require(host < pool.first || host > pool.last, "DHCP excludes gateway for every host");
    }
    std::cout << "PASS: AP address policy\n";
}
