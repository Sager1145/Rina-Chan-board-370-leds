"""
gzip_webui_assets.py  –  PlatformIO filesystem pre-build script

Generates precompressed "<file>.gz" siblings for the large, highly compressible
WebUI assets so the firmware can serve them with `Content-Encoding: gzip`
(see serveStaticFile() in src/web_api.cpp). This dramatically shrinks the bytes
transferred over the ESP32 SoftAP link and the number of streamed chunks.

The .gz files are written next to the originals inside data/ and are picked up
automatically when the LittleFS image is built (`pio run -t buildfs` /
`-t uploadfs`). Both the raw file and the .gz are shipped, so non-gzip clients
still work; serveStaticFile() prefers the .gz only when the client sends
`Accept-Encoding: gzip`.

Only text-like assets are compressed. Already-compressed assets (woff2, png,
jpg) are skipped because gzip would not help (and could even grow them).

The script is idempotent: a .gz is regenerated only when it is missing or older
than its source file.
"""

import gzip
import os
import shutil

Import("env")  # noqa: F821  (PlatformIO injects this)

# Paths are relative to the data/ (LittleFS source) directory.
GZIP_TARGETS = [
    "index.html",
    "styles.css",
    "resources/fonts/ark12.json",
]

GZIP_LEVEL = 9


def _gzip_one(src_path):
    dst_path = src_path + ".gz"
    if os.path.isfile(dst_path) and os.path.getmtime(dst_path) >= os.path.getmtime(src_path):
        return False
    with open(src_path, "rb") as f_in, gzip.open(dst_path, "wb", compresslevel=GZIP_LEVEL) as f_out:
        shutil.copyfileobj(f_in, f_out)
    src_size = os.path.getsize(src_path)
    dst_size = os.path.getsize(dst_path)
    pct = (100.0 * dst_size / src_size) if src_size else 0.0
    print(f"[gzip_webui_assets] {os.path.basename(src_path)}: "
          f"{src_size} -> {dst_size} bytes ({pct:.1f}%)")
    return True


def gzip_assets(*args, **kwargs):
    data_dir = os.path.join(env["PROJECT_DIR"], "data")  # noqa: F821
    if not os.path.isdir(data_dir):
        print(f"[gzip_webui_assets] WARNING: data dir not found: {data_dir} - skipping")
        return
    any_done = False
    for rel in GZIP_TARGETS:
        src = os.path.join(data_dir, rel)
        if not os.path.isfile(src):
            print(f"[gzip_webui_assets] skip (missing): {rel}")
            continue
        any_done = _gzip_one(src) or any_done
    if not any_done:
        print("[gzip_webui_assets] all .gz assets already up to date")


# Regenerate the .gz files right before the LittleFS image is assembled.
env.AddPreAction("$BUILD_DIR/littlefs.bin", gzip_assets)  # noqa: F821

# Also allow manual invocation: `pio run -t gzipassets`.
try:
    env.AddCustomTarget("gzipassets", None, gzip_assets,  # noqa: F821
                        title="Gzip WebUI assets",
                        description="Generate .gz siblings for large WebUI assets")
except Exception:
    pass

# Run once at script load too, so a plain `pio run -t uploadfs` on a clean tree
# still has fresh .gz files even if the image-target hook ordering changes.
gzip_assets()
