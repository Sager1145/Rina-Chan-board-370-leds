import gc
gc.collect()
try:
    import network
    network.WLAN(network.AP_IF).active(True)
    network.WLAN(network.STA_IF).active(False)
except Exception:
    pass
gc.collect()
