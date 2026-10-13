#pragma once
#include <WiFi.h>
#include <esp_wifi.h>
#include <dhcpserver/dhcpserver.h>
constexpr esp_err_t ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED = 3;
constexpr esp_err_t ESP_FAIL = -1;
constexpr int ESP_NETIF_OP_SET = 1, ESP_NETIF_REQUESTED_IP_ADDRESS = 50;
struct esp_netif_t {};
struct esp_netif_ip_info_t { FakeIp4 ip, gw, netmask; };
inline esp_netif_t g_fakeApNetif;
inline bool g_fakeDhcpRunning = false;
inline bool g_fakeDhcpOptionResult = true;
inline bool g_fakeDhcpStartResult = true;
inline unsigned g_fakeDhcpOptionFailures = 0;
inline unsigned g_fakeDhcpStartFailures = 0;
inline dhcps_lease_t g_fakeDhcpLease;
inline bool g_fakeApClientsKeptOldSubnet = false;
inline esp_netif_t* esp_netif_get_handle_from_ifkey(const char*) { return &g_fakeApNetif; }
inline esp_err_t esp_netif_dhcps_stop(esp_netif_t*) { g_fakeDhcpRunning = false; return ESP_OK; }
inline esp_err_t esp_netif_set_ip_info(esp_netif_t*, const esp_netif_ip_info_t* info) {
    if (!WiFi.configResult) return ESP_FAIL;
    if (WiFi.AP.clients && WiFi.configuredApIp != IPAddress(info->ip.addr))
        g_fakeApClientsKeptOldSubnet = true;
    WiFi.configuredApIp = IPAddress(info->ip.addr); return ESP_OK;
}
inline esp_err_t esp_netif_dhcps_option(esp_netif_t*, int, int, void* value, uint32_t) {
    if (g_fakeDhcpOptionFailures) { --g_fakeDhcpOptionFailures; return ESP_FAIL; }
    if (!g_fakeDhcpOptionResult) return ESP_FAIL;
    g_fakeDhcpLease = *static_cast<dhcps_lease_t*>(value); return ESP_OK;
}
inline esp_err_t esp_netif_dhcps_start(esp_netif_t*) {
    if (g_fakeDhcpStartFailures) { --g_fakeDhcpStartFailures; return ESP_FAIL; }
    if (!g_fakeDhcpStartResult) return ESP_FAIL;
    g_fakeDhcpRunning = true; return ESP_OK;
}
