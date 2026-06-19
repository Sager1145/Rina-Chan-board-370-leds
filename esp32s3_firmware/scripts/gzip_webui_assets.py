"""
本脚本在 LittleFS 打包前压缩 WebUI 静态资源。

它会在构建 LittleFS 镜像前临时生成 index.html、app.js、styles.css 和
ark12.json 的 .gz 旁路文件，让固件可以优先返回 gzip 版本，从而减少
ESP32 SoftAP 传输字节数。镜像生成后会删除这些临时 .gz 文件。

只压缩文本类资源；woff2、png、jpg 等已压缩资源不会处理。

缓存失效（cache-busting）：index.html 和 styles.css 中形如 `asset?v=...`
的版本号会在打包前自动改写成被引用文件内容的短哈希，并把改写后的字节直接
压成 .gz（源文件不被修改）。这样只要 app.js / styles.css / 字体内容变化，
浏览器看到的 `?v=` 就会变化，从而拉取最新资源——再也不会因为忘记手动改
版本号而看到旧的缓存。任何改写失败都会安全回退为压缩原始文件。
"""

import gzip
import hashlib
import os
import re
import shutil

Import("env")  # noqa: F821，保留工具指令，相关名称由外部环境注入。

# 说明 LittleFS 文件系统、静态资源或 gzip 打包流程。
GZIP_TARGETS = [
    "index.html",
    "app.js",
    "test_harness.js",
    "styles.css",
    "resources/fonts/ark12.json",
]

# 这些文本文件里的 `asset?v=...` 引用会被改写成内容哈希。
# 顺序很重要：styles.css 先改写，这样 index.html 引用 styles.css 时
# 用到的是改写后的哈希（包含最新的字体版本）。
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
            return m.group(0)  # 找不到文件就原样保留，绝不破坏引用
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


# 中文块：_gzip_one 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
def _gzip_one(src_path, override_bytes=None):
    dst_path = src_path + ".gz"
    # 改写过的目标（override_bytes 非空）总是重新生成，因为它的内容依赖其它文件。
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


# 中文块：gzip_assets 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
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


# 中文块：cleanup_gzip_assets 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
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


# 处理 LED 矩阵、灯带刷新或硬件时序约束。
env.AddPreAction("$BUILD_DIR/littlefs.bin", gzip_assets)  # noqa: F821，保留工具指令，相关名称由外部环境注入。

# 说明 WebUI 静态资源 gzip 打包 中当前代码块的职责和维护约束。
env.AddPostAction("$BUILD_DIR/littlefs.bin", cleanup_gzip_assets)  # noqa: F821，保留工具指令，相关名称由外部环境注入。
