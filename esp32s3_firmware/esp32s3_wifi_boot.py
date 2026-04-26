# ---------------------------------------------------------------------------
# esp32s3_wifi_boot.py
#
# Tiny early-boot Wi-Fi memory reservation helper.
# This file exists so boot.py does not directly touch network.WLAN/AP_IF/STA_IF.
# Keep it minimal: import network only, reserve AP RAM, then return.
# ---------------------------------------------------------------------------


def reserve_wifi_memory():
    try:
        import network
        network.WLAN(network.AP_IF).active(True)
        network.WLAN(network.STA_IF).active(False)
        return True
    except Exception:
        return False
