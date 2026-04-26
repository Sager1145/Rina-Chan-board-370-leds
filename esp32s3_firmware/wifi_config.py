# wifi_config.py
# ESP32-S3 native Wi-Fi configuration.
# Leave WIFI_SSID empty to use only the fallback AP.

WIFI_SSID = ""
WIFI_PASSWORD = ""

AP_SSID = "RinaChanBoard-ESP32S3"
AP_PASSWORD = "12345678"  # empty = use built-in default "rinachan" (WPA2); set a value to override
AP_CHANNEL = 6
AP_AUTHMODE = 0    # 0 = let firmware apply default WPA2; 3 = WPA2-PSK when AP_PASSWORD set

HTTP_PORT = 80
UDP_PORT = 1234
REMOTE_UDP_PORT = 4321
