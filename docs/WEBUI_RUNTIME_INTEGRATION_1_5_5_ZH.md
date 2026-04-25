# WebUI 功能集成到 Pico 固件 v1.5.5

本版本把原来主要由浏览器 JavaScript 定时发送的功能下放到 Raspberry Pi Pico 固件主循环中。

## 已集成

- 滚动文字：WebUI 只发送 `scrollText370|speed|text`，Pico 固件负责每一帧滚动。
- Unity 语音 / 歌曲 / 影像时间轴：WebUI 将当前项目的关键帧转换成 370 LED `M370` 序列并分块发送到 Pico，然后由 Pico 按 30 FPS 播放。
- 停止命令：WebUI 切换页面、选择其它项目、停止播放时发送 `runtimeStop|...`，Pico 立即停止当前固件动画。
- 固件服务循环：`main.py` 每轮调用 `web_runtime.service()`，动画不依赖浏览器持续发送帧。
- 普通 `M370:`、颜色、亮度、按钮切脸等外部控制会停止当前固件运行时动画，避免互相抢屏。

## 新增文本协议

```text
runtimeStatus
runtimeStop|reason
scrollText370|speed_ms|text
scrollTextStop370
timeline370Begin|fps|last_frame|loop|count|name
timeline370Chunk|frame,HEX;frame,HEX;...
timeline370Play
timeline370Preview|frame
timeline370Stop
timeline370Clear
```

## 修改文件

- `pico_firmware/webui_runtime.py`
- `pico_firmware/main.py`
- `pico_firmware/rina_protocol.py`
- `webui/index.html`
- `webui/rina_webui_stable_1_5_2.js`
- `esp8258_bridge/data/webui_index.html.gz`
- `esp8258_bridge/include/web_app_gz.h`
