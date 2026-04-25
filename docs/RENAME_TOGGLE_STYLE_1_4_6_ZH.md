# 1.4.6-rename-toggle-style

## 修复内容

- 保存的自定义表情列表新增“重命名”按钮。
- “自定义表情”和“表情部件”页面共用同一套重命名逻辑。
- 重命名会在浏览器保存，并通过 `renameFace370|旧名称|新名称` 同步到 Pico。
- Pico 端新增 `saved_faces_370_names.json` 名称覆盖表，因此默认 `demo_faces.py` 导入表情也可以重命名。
- 左右眼同步、Loop 等 checkbox 改为统一的 toggle 按钮样式。
- toggle 按钮关闭时显示 OFF，开启时显示 ON 并变色。
- 所有普通按钮统一为 click 按钮样式，避免部分按钮外观不一致。

## 重新生成

- `webui/index.html`
- `esp8258_bridge/data/webui_index.html.gz`
- `esp8258_bridge/include/web_app_gz.h`
- `pico_firmware/saved_faces_370.py`
- `pico_firmware/rina_protocol.py`
