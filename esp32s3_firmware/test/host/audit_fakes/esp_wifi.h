#pragma once
#include <cstdint>
using esp_err_t = int;
constexpr esp_err_t ESP_OK = 0, ESP_ERR_WIFI_NOT_INIT = 1;
constexpr int WIFI_IF_STA = 0;
struct wifi_config_t {
    struct { uint8_t ssid[32] = {}, password[64] = {}; } sta;
};
esp_err_t esp_wifi_get_config(int interface, wifi_config_t* config);
