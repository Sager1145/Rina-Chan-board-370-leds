import gc
gc.collect()

# Wi-Fi/AP early reservation is isolated in esp32s3_wifi_boot.py.
# Do not add direct Wi-Fi driver calls to boot.py.
try:
    from esp32s3_wifi_boot import reserve_wifi_memory
    reserve_wifi_memory()
except Exception:
    pass

gc.collect()
