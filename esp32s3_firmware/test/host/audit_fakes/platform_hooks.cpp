#include <freertos/FreeRTOS.h>
#include <cassert>
#include <Preferences.h>
#include <WiFi.h>
#include <ESPmDNS.h>
#include <esp_wifi.h>
std::map<std::string, String> Preferences::values;
unsigned Preferences::writes = 0;
FakeWifi WiFi;
esp_err_t esp_wifi_get_config(int, wifi_config_t* config) {
    if (WiFi.getMode() == WIFI_OFF) return ESP_ERR_WIFI_NOT_INIT;
    *config = wifi_config_t{};
    memcpy(config->sta.ssid, WiFi.storedStaSsid.c_str(), std::min<size_t>(WiFi.storedStaSsid.length(), sizeof(config->sta.ssid)));
    memcpy(config->sta.password, WiFi.storedStaPass.c_str(), std::min<size_t>(WiFi.storedStaPass.length(), sizeof(config->sta.password)));
    return ESP_OK;
}
FakeMdns MDNS;
const char* boardBootId() { return "audit-boot"; }
const char* boardId() { return "000000000001"; }
String boardDefaultApSsid() { return "RinaChanBoard-000000000001"; }
String boardHostname() { return "rinaboard-000000000001"; }
String boardServiceInstanceName() { return "RinaBoard-000000000001"; }
bool isBrightnessButtonCode(const String&) { return false; }
BaseType_t g_fakeTaskCreateResult = pdPASS;
uint8_t g_fakePixels[LED_COUNT][3] = {};
unsigned g_fakeRefreshFailures = 0;
void (*g_fakeRefreshHook)() = nullptr;
namespace leddrv {
void setPixel(uint16_t index, uint8_t r, uint8_t g, uint8_t b) {
    assert(index < LED_COUNT);
    g_fakePixels[index][0] = r; g_fakePixels[index][1] = g; g_fakePixels[index][2] = b;
}
void clear() { memset(g_fakePixels, 0, sizeof(g_fakePixels)); }
bool refresh() {
    g_fakeMicros += g_fakeRefreshUs; ++g_fakeRefreshCount;
    if (g_fakeRefreshHook) {
        // The hook simulates the cooperative task publishing while the render
        // task waits on hardware. Mutex ownership is per task, so the existing
        // single-thread lock tracker needs a fresh task's lock set for the hook.
        unsigned renderTaskLocks[4];
        memcpy(renderTaskLocks, g_lockHeld, sizeof(renderTaskLocks));
        memset(g_lockHeld, 0, sizeof(renderTaskLocks));
        g_fakeRefreshHook();
        memcpy(g_lockHeld, renderTaskLocks, sizeof(renderTaskLocks));
    }
    if (g_fakeRefreshFailures) { --g_fakeRefreshFailures; return false; }
    return true;
}
}
void tcpTransportBegin() {}
void tcpTransportService() {}
void initSerialConsole() {}
void serviceSerialConsole() {}
