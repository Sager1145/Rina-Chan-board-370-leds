"""
patch_webserver_timeout.py  –  PlatformIO pre-build script
Patches the ESP32 Arduino WebServer.h so that the three per-connection
timeout macros use #ifndef guards instead of unconditional #defines.
This lets build_flags -D overrides actually take effect, and lets us
shorten the default 5000 ms timeouts to 200 ms so that half-open TCP
connections left by a disconnected phone do not stall the main loop
(and firmware text-scroll) for seconds at a time.

The patch is idempotent: running it a second time is a no-op.
"""

import os
import re
Import("env")  # noqa: F821  (PlatformIO injects this)

FRAMEWORK_DIR = env.PioPlatform().get_package_dir("framework-arduinoespressif32")
WEBSERVER_H = os.path.join(
    FRAMEWORK_DIR, "libraries", "WebServer", "src", "WebServer.h"
)

TIMEOUT_MS = 200

MACROS = ["HTTP_MAX_DATA_WAIT", "HTTP_MAX_POST_WAIT", "HTTP_MAX_SEND_WAIT"]

def patch():
    if not os.path.isfile(WEBSERVER_H):
        print(f"[patch_webserver_timeout] WARNING: {WEBSERVER_H} not found – skipping patch")
        return

    with open(WEBSERVER_H, "r", encoding="utf-8") as f:
        original = f.read()

    patched = original
    changed = False
    for macro in MACROS:
        # Match an unconditional #define for this macro (not already inside #ifndef)
        pattern = re.compile(
            r'^([ \t]*#define[ \t]+' + re.escape(macro) + r'[ \t]+\d+[^\n]*)$',
            re.MULTILINE,
        )
        replacement = (
            f"#ifndef {macro}\n"
            f"#define {macro} {TIMEOUT_MS}  // patched by patch_webserver_timeout.py\n"
            f"#endif  // {macro}"
        )
        # Only replace if the line is NOT already inside a #ifndef block we added
        if re.search(r'patched by patch_webserver_timeout', patched) is None or \
                macro not in patched.split("patched by patch_webserver_timeout")[0]:
            new_patched, n = pattern.subn(replacement, patched)
            if n:
                patched = new_patched
                changed = True
                print(f"[patch_webserver_timeout] Patched {macro} → {TIMEOUT_MS} ms in WebServer.h")

    if changed:
        with open(WEBSERVER_H, "w", encoding="utf-8") as f:
            f.write(patched)
        print(f"[patch_webserver_timeout] WebServer.h updated: {WEBSERVER_H}")
    else:
        print("[patch_webserver_timeout] WebServer.h already patched – no changes needed")

patch()
