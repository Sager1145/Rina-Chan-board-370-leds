"""
patch_webserver_timeout.py - PlatformIO pre-build script
Patches the ESP32 Arduino WebServer.h so that the three per-connection
timeout macros use #ifndef guards instead of unconditional #defines.
This lets build_flags -D overrides actually take effect, and lets us
shorten the default 5000 ms timeouts to 200 ms so that half-open TCP
connections left by a disconnected phone do not stall the main loop
(and firmware text-scroll) for seconds at a time.

The patch is idempotent and also repairs earlier repeated guard blocks.
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


def guarded_timeout_block():
    blocks = []
    for macro in MACROS:
        blocks.append(
            f"#ifndef {macro}\n"
            f"#define {macro} {TIMEOUT_MS}  // patched by patch_webserver_timeout.py\n"
            f"#endif  // {macro}"
        )
    return "\n".join(blocks) + "\n"


def patch():
    if not os.path.isfile(WEBSERVER_H):
        print(f"[patch_webserver_timeout] WARNING: {WEBSERVER_H} not found; skipping patch")
        return

    with open(WEBSERVER_H, "r", encoding="utf-8") as f:
        original = f.read()

    replacement = guarded_timeout_block()
    timeout_region = re.compile(
        r"(?ms)^#(?:ifndef|define)[ \t]+HTTP_MAX_DATA_WAIT\b.*?"
        r"(?=^#define[ \t]+HTTP_MAX_CLOSE_WAIT\b)"
    )

    patched, count = timeout_region.subn(replacement, original, count=1)
    if count == 0:
        print("[patch_webserver_timeout] WARNING: timeout macro section not found; skipping patch")
        return

    if patched == original:
        print("[patch_webserver_timeout] WebServer.h already patched; no changes needed")
        return

    with open(WEBSERVER_H, "w", encoding="utf-8") as f:
        f.write(patched)

    print(f"[patch_webserver_timeout] WebServer.h timeout macros set to {TIMEOUT_MS} ms")


patch()
