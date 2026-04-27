# ---------------------------------------------------------------------------
# esp32s3_wifi_boot.py
#
# Tiny early-boot Wi-Fi memory reservation helper.
# This file exists so boot.py does not directly touch network.WLAN/AP_IF/STA_IF.
# Keep it minimal: import network only, reserve AP RAM, then return.
# ---------------------------------------------------------------------------


# Function: Defines reserve_wifi_memory() to handle reserve wifi memory behavior.
def reserve_wifi_memory():
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Import: Loads network so this module can use that dependency.
        import network
        # Expression: Calls network.WLAN.active() for its side effects.
        network.WLAN(network.AP_IF).active(True)
        # Expression: Calls network.WLAN.active() for its side effects.
        network.WLAN(network.STA_IF).active(False)
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
