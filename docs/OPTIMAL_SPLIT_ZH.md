# v1.2.9 OptimalSplit 架构说明

本版重新确定 Pico/RP2040 与 ESP8258 的最佳分工，并把上一版 `picoserver` 的网页资源从 Pico 迁回 ESP8258。

## 最佳分工

| 模块 | 负责内容 | 不负责内容 | 原因 |
|---|---|---|---|
| ESP8258 / ESP8266-family | Wi-Fi STA/AP、原版 WiFiManager 配网页、HTTP WebUI、HTTP API、UDP 1234、日志、状态、UDP↔UART bridge | LED 映射、表情数据库、RinaChanBoard 协议状态机 | ESP 有 Wi-Fi/TCP/IP/HTTP，直接服务 gzip WebUI 最快；不经过 115200 UART 传网页 |
| Raspberry Pi Pico / RP2040 | RinaChanBoard-main 协议、微信小程序文本协议、flyAkari 旧协议、表情状态、颜色/亮度状态、370 LED 映射、WS2812 精确定时输出 | TCP/IP、HTTP server、Wi-Fi 配网页 | RP2040 没有网络接口，但 PIO/NeoPixel 和实时 LED 输出更可靠 |

## 关键变化

- `http://板子IP/` 由 ESP8258 直接返回内置 gzip WebUI：`esp8258_bridge/include/web_app_gz.h`。
- 浏览器按钮通过 ESP 的 `/api/*` 调用 Pico 协议，不再从 Pico 文件系统分块读取网页。
- Pico 只处理控制 payload 和需要实时保持的 LED/表情状态。
- 仍然保留原版 UDP 协议、小程序文本协议、flyAkari 旧 UDP 协议。
- UART baudrate 仍为 115200。

## 为什么不让 Pico 存网页/做 WebServer

当前硬件是 Pico/RP2040 + ESP8258。RP2040 本体没有 TCP/IP 网络接口；即使把 HTML 文件放到 Pico，真正的 HTTP socket 仍然只能在 ESP8258 上。让 ESP 每次通过 115200 UART 向 Pico 分块读取 HTML，会导致首页打开慢、UART 被大块网页占用、控制包延迟增加。因此最佳方式是：网页静态资源放 ESP flash，控制核心放 Pico。

## 打开网页

正常联网后，浏览器打开：

```text
http://板子IP/
```

例如：

```text
http://192.168.0.150/
```

