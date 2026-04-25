# RinaChanBoard-main 功能对齐清单

本包目标：在 **Raspberry Pi Pico + ESP8258 no-AT + 370 LED 板** 上实现 RinaChanBoard-main 下位机的完整功能。上游功能来自：

- `RinaChanBoardHardware/RinaChanBoardHardwareV2/src/main.cpp`
- `src/led.cpp`
- `src/udpsocket.cpp`
- `src/configwifi.cpp`
- `Documents/4.通讯报文设计.md`
- `RinaChanBoardOperationCenter.wechatapp` 的 UDP 文本发送逻辑

## 已实现功能

| RinaChanBoard-main 功能 | 上游行为 | Pico + ESP8258 No-AT 实现 |
|---|---|---|
| 开机动画 | `initLED()` 连续显示 3 个启动脸，每个 1 s | `RinaProtocol.boot_animation()` 完整复刻 |
| Wi-Fi 前状态脸 | `setup()` 中显示 Wi-Fi 状态脸 | `main.py` 显示 `BOOT_WIFI` |
| UDP ready 状态脸 | `udpHandler.begin()` 后显示 ready/UDP 状态脸 | `main.py` 显示 `BOOT_UDP` |
| Wi-Fi STA 自动连接 | WiFiManager 尝试保存的 Wi-Fi | ESP8258 EEPROM 保存 SSID/密码并自动连接 |
| Wi-Fi AP 配网 | AP SSID `RinaChanBoard`，HTTP 配网，文档 IP `192.168.11.13` | ESP8258 captive portal，SSID `RinaChanBoard`，IP `192.168.11.13` |
| UDP 监听端口 | 本机 `1234` | ESP8258 监听 UDP `1234`，转发到 Pico |
| UDP 回复端口 | 目标端口 `4321` | Pico 回包经 ESP8258 发送到远端 IP 的 `4321` |
| Face_Full | 36-byte，16×18，MSB-first | 支持二进制 36-byte；渲染到 370 LED 中央区域 |
| Face_Text_Lite | 16-byte，居中偏移 4 行 | 支持二进制 16-byte；也支持 32 hex 文本测试输入 |
| Face_Lite | 4-byte：左眼/右眼/嘴/脸颊索引 | 支持；表情数据库从上游 `emoji_set.cpp` 转换 |
| Color | 3-byte RGB | 支持二进制 `[R,G,B]` |
| Bright | 1-byte brightness | 支持二进制亮度，并按 FastLED 风格缩放输出 |
| Request Face | `0x1001` 返回 36 bytes | 支持 |
| Request Color | `0x1002` 返回 3 bytes | 支持，返回 `[R,G,B]` |
| Request Bright | `0x1003` 返回 1 byte | 支持 |
| Request Version | `0x1004` 返回版本字符串 | 支持，返回 `1.2.6-pico-esp8258-noat-370-full-115200-wifiparity` |
| Request Battery | `0x1005` 上游 TODO | 与原版一致：不回包 |
| WeChat 自定义表情上传 | 72-char hex text | 支持 |
| WeChat 颜色上传 | `#rrggbb` text | 支持 |
| WeChat 亮度上传 | `B000`..`B255` text | 支持 |
| WeChat requestFace | 返回 72-char hex text | 支持 |
| WeChat requestColor | 返回 `#rrggbb` text | 支持 |
| WeChat requestBright | 返回十进制亮度 text | 支持 |
| WeChat 语音/歌曲口型同步 | 小程序连续发送 72-char hex text | 支持，由 Pico 快速重绘 370 LED |
| ESP-AT | 不适用 | 明确不使用；ESP8258 刷自定义桥接固件 |

## 370 LED 映射

原 RinaChanBoard-main 是 16×18 逻辑脸，外侧第 0/17 列为空列；370 LED 板是 22×18 异形矩阵。映射方式：

- 16×18 逻辑脸放到 22×18 中央。
- 行偏移：`+1`。
- 列偏移：`+2`。
- 原协议外侧无效列仍不点亮。
- 物理行长来自 `Rina-Chan-board-370-leds/board.py`：`18,20,20,20,22×9,20,20,20,18,16`。
- 奇数行蛇形反向。

## 与上游不同但必要的地方

1. **ESP8258 不运行 ESP-AT**：它运行本包的 `esp8258_bridge`。这是为了避免 AT 文本流解析、`+IPD` 混流和不同 AT 固件版本的不兼容。
2. **Pico 负责 LED timing**：WS2812 时序由 Pico 直接驱动，避免 ESP Wi-Fi 中断影响 LED 输出。
3. **Battery 请求**：上游代码中 `RequestType::BATTERY` 是 TODO，没有真正实现。v1.2.5 按原版行为不回包。
4. **Face_Lite 最大索引**：上游 guard 写成 `>= MAX_*_COUNT`，会拒绝最后一个生成索引。本版本默认允许 `0..MAX`，从而真正启用全部生成表情。需要 bug-for-bug 行为时可把 `rina_protocol.py` 中 `STRICT_ORIGINAL_LITE_INDEX_GUARD=True`。
