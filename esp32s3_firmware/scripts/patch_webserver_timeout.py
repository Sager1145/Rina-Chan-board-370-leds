"""
本脚本在 PlatformIO pre-build 阶段修补 Arduino WebServer.h。

修补内容是把 HTTP_MAX_DATA_WAIT、HTTP_MAX_POST_WAIT、HTTP_MAX_SEND_WAIT
改成带 #ifndef guard 的 200ms 默认值，使 build_flags 中的覆盖值真正生效，
并避免断开的客户端长时间卡住主循环和文字滚动刷新。
"""

import os
import re

Import("env")  # noqa: F821，保留工具指令，相关名称由外部环境注入。

FRAMEWORK_DIR = env.PioPlatform().get_package_dir("framework-arduinoespressif32")
WEBSERVER_H = os.path.join(
    FRAMEWORK_DIR, "libraries", "WebServer", "src", "WebServer.h"
)

TIMEOUT_MS = 200
MACROS = ["HTTP_MAX_DATA_WAIT", "HTTP_MAX_POST_WAIT", "HTTP_MAX_SEND_WAIT"]


# 中文块：guarded_timeout_block 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
def guarded_timeout_block():
    blocks = []
    for macro in MACROS:
        blocks.append(
            f"#ifndef {macro}\n"
            f"#define {macro} {TIMEOUT_MS}  // patched by patch_webserver_timeout.py\n"
            f"#endif  // {macro}"
        )
    return "\n".join(blocks) + "\n"


# 中文块：patch 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
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
