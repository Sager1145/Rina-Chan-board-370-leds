# Import: Loads gc so this module can use that dependency.
import gc
# Expression: Calls gc.collect() for its side effects.
gc.collect()

# Wi-Fi/AP early reservation is isolated in esp32s3_wifi_boot.py.
# Do not add direct Wi-Fi driver calls to boot.py.
# Error handling: Attempts the protected operation so failures can be handled safely.
try:
    # Import: Loads reserve_wifi_memory from esp32s3_wifi_boot so this module can use that dependency.
    from esp32s3_wifi_boot import reserve_wifi_memory
    # Expression: Calls reserve_wifi_memory() for its side effects.
    reserve_wifi_memory()
# Error handling: Runs this recovery branch when the protected operation fails.
except Exception:
    # Control: Leaves this branch intentionally empty.
    pass

# Expression: Calls gc.collect() for its side effects.
gc.collect()
