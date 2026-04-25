# v1.4.1 MEDIAUNIFY

本版本完成以下改动：

- 去掉自定义表情页面与表情部件页面中“与滚动文字页面相同的 370 真实 Matrix shape 大预览”卡片。
- 保留自定义表情主编辑网格；隐藏 LED 点位仍然不可用。
- 将原 `demo_faces.py` 中的全部 Python 默认 faces 作为“保存的自定义表情”默认条目。
- WebUI 自定义表情页与表情部件页共用 `rina_custom_faces_matrix370_v2` 保存列表。
- WebUI 保存表情时会同步发送到 Pico 的 `saved_faces_370.json`。
- Pico 端 B1 / B2 按钮在保存的自定义表情列表中循环。
- A/M 自动/手动模式也在同一个保存的自定义表情列表中自动循环。
- 当前颜色仍由首页颜色控制；按钮模式显示保存表情时也使用首页同步颜色。
- Matrix Demo 和 Bad Apple 仍然排除。

新增 Pico 文本命令：

```text
requestSavedFaces370
saveFace370|name|M370:<93 hex>
deleteFace370|name
```
