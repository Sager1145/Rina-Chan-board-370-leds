# Optional station Wi-Fi credentials.
# Leave STA_SSID empty to run AP-only mode.
STA_SSID = ""
STA_PASSWORD = ""

# Phone-compatible fallback AP settings.
# Default is WPA/WPA2 secured because some phones reject open APs with no internet.
# Connect phone to SSID RINA-S3, password 12345678, then open http://192.168.4.1
# If secured AP fails, set AP_COMPAT_OPEN=True and upload again.
AP_SSID = "RINA-S3"
AP_PASSWORD = "12345678"
AP_COMPAT_OPEN = False
AP_CHANNEL = 1
AP_HIDDEN = False
AP_MAX_CLIENTS = 4
AP_COUNTRY = "CA"
