"""
This script compresses WebUI static assets before LittleFS packaging.

It temporarily generates .gz sidecar files for index.html, app.js, styles.css, and
ark12.json before building the LittleFS image, allowing the firmware to return gzip versions
by preference, thereby reducing the bytes transmitted over ESP32 SoftAP. These temporary
.gz files are deleted after the image is generated.

Only text-based resources are compressed; already compressed resources such as woff2,
png, and jpg are not processed.

Cache-busting: Versions in index.html and styles.css formatted as `asset?v=...`
are automatically rewritten before packaging into a short hash of the referenced file's
content, and the rewritten bytes are directly compressed into .gz (the source files are
not modified). This way, as long as app.js / styles.css / font content changes,
the `?v=` seen by the browser will change, fetching the latest resources—preventing old
cached versions from being loaded due to forgetting to manually update the version number.
Any rewriting failure will safely fall back to compressing the original file.
"""

import gzip
import hashlib
import os
import re
import shutil

Import("env")  # noqa: F821, keep tool directives, related names are injected by the external environment.

# Describes the LittleFS file system, static assets, or gzip packaging process.
GZIP_TARGETS = [
    "index.html",
    "app.js",
    "test_harness.js",
    "styles.css",
    "resources/fonts/ark12.json",
]

# The `asset?v=...` references in these text files will be rewritten to content hashes.
# The order is important: styles.css is rewritten first, so that when index.html references styles.css,
# it uses the rewritten hash (which contains the latest font version).
REWRITE_TARGETS = ["styles.css", "index.html"]

GZIP_LEVEL = 9

# 匹配 `path.ext?v=token`，path 以已知静态资源扩展名结尾。
ASSET_REF_RE = re.compile(
    r"(?P<path>/?[\w./-]+\.(?:css|js|woff2?|json|png|jpe?g|svg))\?v=(?P<ver>[^\"')\s>]+)"
)

# 进程内缓存：rel(去掉前导/) -> 短哈希。
_hash_cache = {}


def _short_hash(data_bytes):
    return hashlib.sha1(data_bytes).hexdigest()[:12]


def _rel_of(ref_path):
    return ref_path.lstrip("/")


def _hash_for_ref(data_dir, ref_path, rewritten_bytes_by_rel):
    """Return the short content hash for a referenced asset, or None if missing.

    If the referenced asset was itself rewritten (e.g. styles.css), hash the
    rewritten bytes so a nested change still busts the parent reference.
    """
    rel = _rel_of(ref_path)
    if rel in rewritten_bytes_by_rel:
        return _short_hash(rewritten_bytes_by_rel[rel])
    if rel in _hash_cache:
        return _hash_cache[rel]
    full = os.path.join(data_dir, rel)
    if not os.path.isfile(full):
        return None
    with open(full, "rb") as f:
        h = _short_hash(f.read())
    _hash_cache[rel] = h
    return h


def _rewrite_versions(text, data_dir, rewritten_bytes_by_rel):
    """Replace every `asset?v=...` token with the asset's content hash."""

    def repl(m):
        h = _hash_for_ref(data_dir, m.group("path"), rewritten_bytes_by_rel)
        if not h:
            return m.group(0)  # If the file is not found, keep it as is, never break the reference
        return "{}?v={}".format(m.group("path"), h)

    return ASSET_REF_RE.sub(repl, text)


def _build_rewritten_assets(data_dir):
    """Produce {rel: rewritten_bytes} for REWRITE_TARGETS.

    On ANY error, returns {} so the caller falls back to gzipping raw files.
    """
    rewritten = {}
    try:
        for rel in REWRITE_TARGETS:
            src = os.path.join(data_dir, rel)
            if not os.path.isfile(src):
                continue
            with open(src, "r", encoding="utf-8") as f:
                text = f.read()
            new_text = _rewrite_versions(text, data_dir, rewritten)
            rewritten[rel] = new_text.encode("utf-8")
            changed = sum(
                1
                for _ in ASSET_REF_RE.finditer(text)
            )
            print(
                "[gzip_webui_assets] cache-bust: rewrote {} ?v= ref(s) in {}".format(
                    changed, rel
                )
            )
    except Exception as exc:  # noqa: BLE001 - build must never hard-fail here
        print(
            "[gzip_webui_assets] WARNING: cache-bust rewrite failed ({}); "
            "falling back to raw gzip".format(exc)
        )
        return {}
    return rewritten


def _gzip_one(src_path, override_bytes=None):
    dst_path = src_path + ".gz"
    # Rewritten targets (override_bytes is not None) are always regenerated because their content depends on other files.
    if override_bytes is None:
        if os.path.isfile(dst_path) and os.path.getmtime(dst_path) >= os.path.getmtime(src_path):
            return False

    if override_bytes is None:
        with open(src_path, "rb") as f_in, gzip.open(dst_path, "wb", compresslevel=GZIP_LEVEL) as f_out:
            shutil.copyfileobj(f_in, f_out)
        src_size = os.path.getsize(src_path)
    else:
        with gzip.open(dst_path, "wb", compresslevel=GZIP_LEVEL) as f_out:
            f_out.write(override_bytes)
        src_size = len(override_bytes)

    dst_size = os.path.getsize(dst_path)
    pct = (100.0 * dst_size / src_size) if src_size else 0.0
    print(f"[gzip_webui_assets] {os.path.basename(src_path)}: "
          f"{src_size} -> {dst_size} bytes ({pct:.1f}%)")
    return True


def gzip_assets(*args, **kwargs):
    data_dir = os.path.join(env["PROJECT_DIR"], "data")  # noqa: F821，保留工具指令，相关名称由外部环境注入。
    if not os.path.isdir(data_dir):
        print(f"[gzip_webui_assets] WARNING: data dir not found: {data_dir} - skipping")
        return

    _hash_cache.clear()
    rewritten_bytes_by_rel = _build_rewritten_assets(data_dir)

    any_done = False
    for rel in GZIP_TARGETS:
        src = os.path.join(data_dir, rel)
        if not os.path.isfile(src):
            print(f"[gzip_webui_assets] skip (missing): {rel}")
            continue
        override = rewritten_bytes_by_rel.get(rel)
        any_done = _gzip_one(src, override_bytes=override) or any_done
    if not any_done:
        print("[gzip_webui_assets] all .gz assets already up to date")


def cleanup_gzip_assets(*args, **kwargs):
    data_dir = os.path.join(env["PROJECT_DIR"], "data")  # noqa: F821，保留工具指令，相关名称由外部环境注入。
    removed = False
    for rel in GZIP_TARGETS:
        gz_path = os.path.join(data_dir, rel + ".gz")
        if os.path.isfile(gz_path):
            os.remove(gz_path)
            print(f"[gzip_webui_assets] removed temporary: {rel}.gz")
            removed = True
    if not removed:
        print("[gzip_webui_assets] no temporary .gz assets to remove")


env.AddPreAction("$BUILD_DIR/littlefs.bin", gzip_assets)  # noqa: F821，保留工具指令，相关名称由外部环境注入。

# Describes the responsibilities and maintenance constraints of the current code block in WebUI static asset gzip packaging.
env.AddPostAction("$BUILD_DIR/littlefs.bin", cleanup_gzip_assets)  # noqa: F821，保留工具指令，相关名称由外部环境注入。
