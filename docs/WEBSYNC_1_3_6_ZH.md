# v1.3.6 WEBSYNC 修复说明

## 对 v1.3.5 UIFIX 的检测结果

- 滚动文字 / AsciiDb：已使用 370 LED Matrix shape 和 M370 发送。
- 表情部件位置：已保持原版 16×18 位置后映射到 370 LED。
- 微信小程序预设语音/歌曲页面：运行时已被 Unity 语音/歌曲页面替换，但静态 HTML 中仍有旧标签闪现。
- flyAkari 旧版页面：运行时已移除，但 ESP 端仍注册旧 API 路由。
- Unity VideoTimeLineDb：已集成，但没有 Loop 控制。
- 自动同步：已有 requestState，但只显示原始 JSON，没有明确显示 face/color/bright/version/battery 分区状态。
- 自定义表情页面：已有 370 编辑矩阵，但没有与滚动文字相同的独立预览窗口。
- 表情部件页面：有部件缩略图，但没有与滚动文字相同的 370 预览窗口，也不能在部件预览上 toggle 单个 LED。

## v1.3.6 修复

- Unity 预设影像增加 Loop toggle。
- 自定义表情页面增加 370 Matrix 预览窗口。
- 表情部件页面增加 370 Matrix 预览窗口，并可点击真实 LED toggle on/off。
- 自动同步改为结构化显示 version/color/bright/battery/face preview。
- WebUI 标题与固件版本更新到 1.3.6。
- ESP WebUI 构建去掉 flyAkari 旧 API 路由注册。
