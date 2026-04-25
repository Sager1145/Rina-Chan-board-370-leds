# v1.3.2 SLEEPFIX 修复说明

本版修复用户列出的功能差异：

- WebUI 连接后自动同步 face/color/bright/version/battery。
- 播放语音、歌曲、影像或滚动文字时启用互斥锁，阻止切页、编辑和其它发送动作。
- 新增滚动文字页面，使用 Unity 原版 `AsciiDb.json`，限制 30 字，可调速度，可停止。
- 集成 Unity 原版数据库：`AsciiDb.json`、`FaceModuleDb.json`、`VoiceDb.json`、`VoiceTimeLineDb/*`、`MusicDb.json`、`MusicTimeLineDb/*`、`VideoDb.json`、`VideoTimeLineDb/*`。
- 新增 Unity 完整语音/歌曲/影像时间轴播放；可选择本地媒体文件或 URL，未选择媒体时以静默时间轴同步 LED。
- 二进制 `0x1005 requestBattery` 恢复原版 TODO 行为：不回包。文本 `requestBattery` 仍返回 370 LED 扩展电池 JSON。
- Pico 启动时实际调用原版 initLED 三段启动 face，并显示 WiFi/UDP/READY 状态 face。

注意：ESP8258 flash 容量有限，本版只内置时间轴数据库，不内置 Unity 的 ogg/mp4 媒体文件；网页支持选择本地媒体文件或填写 URL 来播放并同步。
