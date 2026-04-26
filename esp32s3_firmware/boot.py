import gc
gc.collect()

# Pre-activate WiFi interfaces before any other large allocations.
# On ESP32-S3, the WiFi stack needs a contiguous block of internal DRAM.
# If NeoPixel RMT buffers or module bytecode are allocated first the heap
# becomes too fragmented and network.WLAN() raises OSError: WiFi Out of Memory.
# Calling .active(True) here reserves that RAM at the earliest possible moment.
try:
    import network
    network.WLAN(network.AP_IF).active(True)
    network.WLAN(network.STA_IF).active(False)  # STA off until main() configures it
except Exception:
    pass
gc.collect()
