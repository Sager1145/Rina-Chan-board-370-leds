# RinaChanBoard-main 逐行功能对比与修复记录

目标版本：`1.2.6-pico-esp8258-noat-370-full-115200-wifiparity`

对比对象：

- 原版固件：`RinaChanBoardHardware/RinaChanBoardHardware/src/main.cpp`
- 原版 LED 逻辑：`src/led.cpp`, `include/led.h`
- 原版 UDP 逻辑：`src/udpsocket.cpp`, `include/udpsocket.h`
- 原版 Wi-Fi 逻辑：`src/configwifi.cpp`, `include/configwifi.h`
- 原版小程序发送协议：`RinaChanBoardOperationCenter.wechatapp/pages/*`, `utils/face_func.js`
- 目标硬件：Raspberry Pi Pico + ESP8258 no-AT bridge + Rina-Chan-board-370-leds

---

## 1. setup()/启动流程逐行映射

| 原版位置 | 原版行为 | Pico/ESP8258 位置 | 状态 |
|---|---|---|---|
| `main.cpp:16` | Debug UART 115200 | `main.py:28`, `esp8258_bridge/include/user_config.h:15` | 等效，Pico ↔ ESP 也固定 115200 |
| `main.cpp:17` | LED_BUILTIN idle/high | ESP bridge 日志输出替代 | ESP 模块上没有统一板载 LED 定义；不影响功能 |
| `main.cpp:18-19` | 初始化 WS2812 输出 | `board_370.py:19-20`, `board_370.py:57` | 等效到 Pico GP15 / 370 LEDs |
| `main.cpp:20` | `initLED()` 三段启动动画 + ready face | `rina_protocol.py:104-109` | 等效 |
| `main.cpp:25-26` | 显示 Wi-Fi 状态脸 | `main.py:47` | 等效 |
| `main.cpp:27` | WiFiManager 配网/连接 | ESP：`setup() -> loadConfig/tryConnect/startPortal` | 等效；改为自定义 portal，不使用 ESP-AT |
| `main.cpp:28-29` | 显示 UDP 状态脸 | `main.py:59` | 等效 |
| `main.cpp:30` | `udpHandler.begin()` | ESP：`startUdp()` + Pico `ESPBridge` | 等效 |
| `main.cpp:31-32` | UDP ready 后再显示 ready face | **v1.2.5 修复：`main.py:60`** | 修复前缺少最终 ready face，现在等效 |
| `main.cpp:38` | loop 空转 | `main.py:60-74`, ESP `loop()` | Pico 负责协议处理，ESP 负责 Wi-Fi/UDP |

修复项：`v1.2.4` 在 `BOOT_UDP` 后没有再显示 `BOOT_READY`，现在补上，启动显示顺序与原版一致。

---

## 2. LED 显示逻辑逐行映射

| 原版位置 | 原版行为 | Pico 位置 | 状态 |
|---|---|---|---|
| `led.h:6-11` | 256 LEDs, 16x18 logical face, WS2812 GRB | `board_370.py:19-43` | 逻辑协议保持 16x18，物理输出改为 370 LEDs |
| `led.cpp:10-27` | `led_map[16][18]`，col 0/17 是 `-1` padding | `board_370.py:87-93` | 保留 `SRC_INVALID_COLS=(0,17)` |
| `led.cpp:29-51` | `initLED()` 启动动画 | `rina_protocol.py:104-109` | 等效 |
| `led.cpp:53-60` | `updateColor()` 只重染非黑 LED | `rina_protocol.py:197-199`, `redraw()` | 等效；由 face state 决定非黑像素 |
| `led.cpp:62-86` | `decodeFaceHex()` MSB-first row-major | `rina_protocol.py:116-128` | 等效 |
| `led.cpp:94-123` | 72-char hex string decode | `rina_protocol.py:112-114`, text handler | 等效 |
| `led.cpp:125-136` | `faceUpdate_FullPack()` | `board_370.py:135-149` | 等效到 370-board 中央区域 |
| `led.cpp:138-176` | 表情部件写入 + 左脸颊 XFlip | `rina_protocol.py:157-192` | 等效 |
| `led.cpp:178-226` | 4-byte Face_Lite 部件组合 | `rina_protocol.py:172-195` | 等效；目标版允许数据库最高编号，避免原版 off-by-one 丢失最后一个部件 |
| `led.cpp:228-249` | `getFaceHex()` 读 LED 状态并跳过 padding | **v1.2.5 修复：`rina_protocol.py:130-145`** | 修复前会把 padding bits 原样返回；现在 padding bits 强制为 0 |

修复项：`requestFace` 的返回现在与原版 `getFaceHex()` 一致：16x18 中的 col 0 / col 17 只占位，不返回亮灯 bit。

---

## 3. UDP 二进制协议逐行映射

| 原版位置 | 包长/请求 | 原版行为 | 目标版位置 | 状态 |
|---|---:|---|---|---|
| `udpsocket.h:23-24` | 1234/4321 | local port 1234, reply port 4321 | `rina_protocol.py:19-20`, ESP config | 等效 |
| `udpsocket.h:69-76` | 36 | Face_Full | `rina_protocol.py:218-220` | 等效 |
| `udpsocket.h:69-76` | 16 | Face_Text_Lite offset row 4 | `rina_protocol.py:220-221` | 等效 |
| `udpsocket.h:69-76` | 4 | Face_Lite indices | `rina_protocol.py:222-225` | 等效 |
| `udpsocket.h:69-76` | 3 | RGB color update | `rina_protocol.py:226-227` | 等效 |
| `udpsocket.h:69-76` | 2 | Request packet | `rina_protocol.py:228-229` | 等效 |
| `udpsocket.h:69-76` | 1 | Brightness update | `rina_protocol.py:230-231` | 等效 |
| `udpsocket.cpp:115-117` | other | `Command Error!` | `rina_protocol.py:232-233` | 等效 |
| `udpsocket.cpp:126-132` | `0x1001` | send 36-byte face | `rina_protocol.py:238-239` | 等效，且 padding 修复 |
| `udpsocket.cpp:134-139` | `0x1002` | send 3-byte RGB | `rina_protocol.py:240-243` | 等效 |
| `udpsocket.cpp:141-146` | `0x1003` | send 1-byte bright | `rina_protocol.py:244-245` | 等效 |
| `udpsocket.cpp:148-151` | `0x1004` | send version string | `rina_protocol.py:246-247` | 等效，版本号为目标固件版本 |
| `udpsocket.cpp:153-155` | `0x1005` | TODO, no reply | **v1.2.5 修复：`rina_protocol.py:248-252`** | 修复前返回 `Battery unsupported`；现在与原版一致，不回包 |

---

## 4. 小程序文本协议兼容性

原版下位机源码本身只按包长处理二进制 UDP，但原仓库的小程序页面实际发送文本消息。因此目标版增加文本兼容层，使同一个小程序无需改动即可使用。

| 小程序位置 | 发送内容 | 目标版位置 | 状态 |
|---|---|---|---|
| `pages/index/index.js:96-115` | `#rrggbb` | `rina_protocol.py:277-280` | 支持 |
| `pages/index/index.js:128-151` | `B000..B255` | `rina_protocol.py:287-294` | 支持 |
| `pages/index/index.js:116-126` | `requestColor` | `rina_protocol.py:301-304` | 支持，返回 `#rrggbb` |
| `pages/index/index.js:152-172` | `requestBright` | `rina_protocol.py:305-307` | 支持，返回十进制字符串 |
| `pages/custom/custom.js:136-143` | `requestFace` | `rina_protocol.py:298-300` | 支持，返回 72-char hex |
| `utils/face_func.js` | 72-char face hex | `rina_protocol.py:321-324` | 支持 |
| `pages/music/music.js`, `pages/voice/voice.js` | 连续 72-char face hex | `rina_protocol.py:321-324` | 支持 |

---

## 5. ESP8258 no-AT bridge 与原版 Wi-Fi 功能映射

| 原版位置 | 原版功能 | 目标版位置 | 状态 |
|---|---|---|---|
| `configwifi.cpp:26` | connect timeout 30s | `esp8258_bridge/src/main.cpp:37`, `tryConnect()` | 等效 |
| `configwifi.cpp:30-34` | AP IP 192.168.11.13 | `user_config.h:9-13`, `startPortal()` | 等效 |
| `configwifi.cpp:35-40` | AP callback / save callback / autoConnect | `startPortal()`, `/save`, `/clear` | 等效 |
| `configwifi.cpp:47-48` | print local IP | ESP STATUS frame | 增强：Pico USB log 可见 IP/gateway/DNS/RSSI |
| `udpsocket.cpp:11-31` | UDP listen 1234 | `startUdp()` | 等效 |
| 原版单芯片 ESP8266 | Wi-Fi + LED 同芯片 | ESP8258 + Pico | 架构变更：ESP 只做 Wi-Fi/UDP，Pico 只做协议和 LED，UART frame 连接 |

---

## 6. v1.2.5 修复摘要

1. **启动显示顺序修复**：补上 `BOOT_UDP -> BOOT_READY`，与原版 `setup()` 最后两次 `faceUpdate_StringFullPack()` 对齐。
2. **requestFace padding 修复**：col 0 / col 17 的无 LED padding bit 按原版 `led_map == -1` 行为强制返回 0。
3. **Battery request 行为修复**：原版 `0x1005` 是 TODO 且不回包；目标版已改为不回包，不再返回额外字符串。
4. **自测更新**：`tools/protocol_selftest.py` 增加 padding bit 与 battery no-reply 检查。

---

## 7. 已知不可逐行相同但功能等效的点

- 原版是 ESP8266 单芯片直接驱动 256 LEDs；目标版是 Pico 驱动 370 LEDs，ESP8258 只做 Wi-Fi/UDP。
- 原版 `FastLED.setBrightness()` 在 ESP8266/FastLED 内部缩放；目标版在 `board_370.py` 中按亮度 byte 缩放 NeoPixel 输出。
- 370 LEDs 比原版 256 LEDs 电流更高，`board_370.py` 保留了安全亮度上限，避免误全亮过流。
- 目标版保留 `requestEspLog/requestEspStatus` 扩展命令；这是新增调试功能，不影响原版协议。
