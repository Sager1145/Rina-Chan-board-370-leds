#include "board_identity.h"

#include <esp_mac.h>
#include <esp_random.h>
#include <stdio.h>

#include "config.h"
#include "serial_log.h"

const char* boardId() {
    static char id[13] = {0};
    static bool resolved = false;
    if (!resolved) {
        uint8_t mac[6] = {0};
        const esp_err_t result = esp_read_mac(mac, ESP_MAC_BT);
        if (result != ESP_OK)
            RLOG_ERROR("BOARD", "event=mac_read_failed code=%d", static_cast<int>(result));
        snprintf(id, sizeof(id), "%02X%02X%02X%02X%02X%02X",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        resolved = true;
    }
    return id;
}

String boardDefaultApSsid() {
    return String(AP_SSID_PREFIX) + boardId();
}

String boardHostname() {
    String lower = String(boardId());
    lower.toLowerCase();
    return String("rinaboard-") + lower;
}

String boardServiceInstanceName() {
    return String(BOARD_NAME_PREFIX) + boardId();
}

const char* boardBootId() {
    static char id[9] = {0};
    static bool resolved = false;
    if (!resolved) {
        snprintf(id, sizeof(id), "%08x", static_cast<unsigned int>(esp_random()));
        resolved = true;
    }
    return id;
}
