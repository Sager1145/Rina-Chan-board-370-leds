# Archive 说明

本目录存放从项目根目录整理出来的**一次性字体处理脚本与中间产物**。它们：

- 不被 `platformio.ini`、构建 `extra_scripts`、`run_rinachan_unifont.ps1/.sh`、`src/`、`data/` 或 `README.md` / `plan.md` 引用；
- 不参与固件构建、LittleFS 上传或运行时；
- 仅在历史上用于字体补丁/调试，保留以备参考。

未直接删除，是为了可回滚与保留参考价值（符合“可能有用 → archive”原则）。

## font_ttx_patching/
- `ark12.ttx`（≈58MB）：Ark 字体的 TTX(XML) 转储，`patch_ttx*.py` 的输入。
- `ark12_patched.ttx`、`ark12_patched_all.ttx`（各≈55MB）：由 `patch_ttx.py` / `patch_ttx_all.py` 生成的补丁中间产物，可由脚本重新生成。
- `patch_ttx.py`、`patch_ttx_all.py`：读取 `ark12.ttx`、写出 patched TTX。脚本使用**当前工作目录相对路径**（如 `ET.parse("ark12.ttx")`），已与对应 `.ttx` 同目录存放；如需重跑请在本目录内执行。

> 提示：这三个 `.ttx` 合计约 168MB 且为可再生中间产物；若确认不再需要，可安全删除（见 plan.md 待确认事项）。

## font_dev_scripts/
- `inspect_font.py`、`inspect_font2.py`、`test_cff.py`：只读字体检查/实验脚本，硬编码读取 `./data/resources/fonts/ark12.woff2`。
- `patch_font.py`：一次性把 `./tools/font_fusion/ark12_fusion.json` 与 `./data/resources/fonts/ark12.json` 的数字字形 `dstY` 调整脚本。

> 这两组脚本里的 `./data/...`、`./tools/...` 路径是**相对项目根**的；如需重跑须从项目根目录执行，而非本归档目录。
