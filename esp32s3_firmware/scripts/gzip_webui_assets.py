"""
本脚本在 LittleFS 打包前压缩 WebUI 静态资源。

它会在构建 LittleFS 镜像前临时生成 index.html、app.js、styles.css 和
ark12.json 的 .gz 旁路文件，让固件可以优先返回 gzip 版本，从而减少
ESP32 SoftAP 传输字节数。镜像生成后会删除这些临时 .gz 文件。

只压缩文本类资源；woff2、png、jpg 等已压缩资源不会处理。
"""

import gzip
import os
import shutil

Import("env")  # noqa: F821，保留工具指令，相关名称由外部环境注入。

# 说明 LittleFS 文件系统、静态资源或 gzip 打包流程。
GZIP_TARGETS = [
    "index.html",
    "app.js",
    "styles.css",
    "resources/fonts/ark12.json",
]

GZIP_LEVEL = 9


# 中文块：_gzip_one 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
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


# 中文块：gzip_assets 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
def gzip_assets(*args, **kwargs):
    data_dir = os.path.join(env["PROJECT_DIR"], "data")  # noqa: F821，保留工具指令，相关名称由外部环境注入。
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
