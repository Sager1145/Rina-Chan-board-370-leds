"""
This script patches Arduino WebServer.h during the PlatformIO pre-build stage.

The patch converts HTTP_MAX_DATA_WAIT, HTTP_MAX_POST_WAIT, and HTTP_MAX_SEND_WAIT
into 200ms default values guarded by #ifndef. This allows override values in build_flags
to take effect and prevents disconnected clients from blocking the main loop and text scroll
refresh for an extended period.
"""

import os
import re

Import("env")  # noqa: F821, keep tool directives, related names are injected by the external environment.

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
