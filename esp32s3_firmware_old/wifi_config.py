# wifi_config.py
# ESP32-S3 native Wi-Fi configuration.
# Leave WIFI_SSID empty to use only the fallback AP.

# Variable: WIFI_SSID stores the configured text value.
WIFI_SSID = ""
# Variable: WIFI_PASSWORD stores the configured text value.
WIFI_PASSWORD = ""

# Variable: AP_SSID stores the configured text value.
AP_SSID = "RinaChanBoard-ESP32S3"
# Variable: AP_PASSWORD stores the configured text value.
AP_PASSWORD = ""  # empty = use built-in default "rinachan" (WPA2); set a value to override
# Variable: AP_CHANNEL stores the configured literal value.
AP_CHANNEL = 6
# Variable: AP_AUTHMODE stores the configured literal value.
AP_AUTHMODE = 0    # 0 = let firmware apply default WPA2; 3 = WPA2-PSK when AP_PASSWORD set

# Variable: HTTP_PORT stores the configured literal value.
HTTP_PORT = 80
# Variable: UDP_PORT stores the configured literal value.
UDP_PORT = 1234
# Variable: REMOTE_UDP_PORT stores the configured literal value.
REMOTE_UDP_PORT = 4321
