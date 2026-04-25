# v1.3.5 UIFIX 修复说明

## WebUI

- 滚动文字页改为真实 370 LED 物理矩阵，不再生成原版 16×18 face hex。
- `AsciiDb.json` 仍使用 Unity 原版 95 个 5×7 ASCII 字符，但渲染输出改为 `M370:<93 hex>`。
- 自定义表情页保持 22×18 物理预览，隐藏点位不可点击。
- 表情部件页保留原版位置：左眼 `(0,0)`、右眼 `(0,10)`、嘴巴 `(8,5)`、脸颊 `(8,0)/(8,13)`，再映射到 370 LED。
- 移除微信小程序预设语音/歌曲页面，只保留 Unity 完整 Voice/Music/Video TimeLineDb。
- 移除 flyAkari 旧版 ESP8266 协议页面。
- 亮度 UI 改为横向滑块，范围 `10..128`。
- 自动同步 `requestState` 会更新 face/color/bright/version/battery。

## Pico

- B2+B6 不再分段显示 IP；改为 22×18 真实矩阵文字滚动显示 `IP + SSID`。
- 增加 `display_num.render_scrolling_text_window()`，滚动文字只点亮真实 LED，隐藏点位保持熄灭。

## 协议

- 保留 `M370:<93 hex>` 真实 370 LED 矩阵扩展。
- 保留原版 72 hex / 36-byte / 16-byte / 4-byte / RGB / brightness / request 协议兼容。
- Bad Apple 未加入。
